#!/usr/bin/env node
/**
 * whatsapp-wjs-gateway.cjs
 *
 * WhatsApp Claude gateway using whatsapp-web.js (no Meta API, no Twilio).
 * Bot number: +27645066729
 *
 * First run: scan the QR code printed in terminal with the bot phone.
 * After that: runs headlessly as a LaunchAgent forever — session persisted to disk.
 *
 * Only responds to messages from WA_OWNER_NUMBER (Josh's personal number).
 */

'use strict';

const { Client, LocalAuth } = require('whatsapp-web.js');
const qrcode    = require('qrcode-terminal');
const fs        = require('fs');
const path      = require('path');
const os        = require('os');
const http      = require('http');
const https     = require('https');
const { spawnSync } = require('child_process');

// ── Config ────────────────────────────────────────────────────────────────────
const WS       = '/Users/henryburton/.openclaw/workspace-anthropic';
const ENV_FILE = path.join(WS, '.env.scheduler');

const env = {};
try {
  for (const line of fs.readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)=(.+)$/);
    if (m && !m[2].startsWith('REPLACE')) env[m[1]] = m[2].trim();
  }
} catch { /* ignore */ }

const OWNER_NUMBER            = env.WA_OWNER_NUMBER || process.env.WA_OWNER_NUMBER || '';
const SUPABASE_URL            = env.AOS_SUPABASE_URL || 'https://afmpbtynucpbglwtbfuz.supabase.co';
const SUPABASE_KEY            = env.SUPABASE_SERVICE_ROLE_KEY || '';
const SYSTEM_PROMPT_FILE      = path.join(WS, 'prompts/telegram-claude-system.md');
const GROUP_SYSTEM_PROMPT_FILE = path.join(WS, 'prompts/sophia-whatsapp-group.md');
const PERSONAL_DM_PROMPT_FILE        = path.join(WS, 'prompts/sophia-personal-dm.md');
const PERSONAL_ASSISTANT_PROMPT_FILE = path.join(WS, 'prompts/sophia-personal-assistant.md');
const CONTACTS_FILE           = path.join(WS, 'memory/whatsapp-contacts.json');
const MUTED_GROUPS_FILE       = path.join(WS, 'tmp/whatsapp-muted-groups.txt');
const LID_MAP_FILE            = path.join(WS, 'memory/whatsapp-lid-map.json');

// Debounce timings — groups get 3 min (batch multi-person bursts), DMs get 45s (conversational)
const DEBOUNCE_GROUP_MS = 3 * 60 * 1000;
const DEBOUNCE_DM_MS    = 45 * 1000;
const pendingBatches = new Map(); // chatId → { items: [...], timer }

// Track unknown numbers already flagged to Josh this session (avoids repeat pings)
const unknownNotified = new Set();

// Rate limit — track last Sophia reply time per chat (chatId → timestamp ms)
const sophiaLastReply = new Map();

// LID → real phone number map (persisted to disk, built automatically)
let lidMap = {};
try { lidMap = JSON.parse(fs.readFileSync(LID_MAP_FILE, 'utf8')); } catch { /* first run */ }

function saveLidMap() {
  try { fs.writeFileSync(LID_MAP_FILE, JSON.stringify(lidMap, null, 2)); } catch { /* */ }
}

// Module-level contacts cache — reloaded on each buildLidMap run
let cachedContacts = {};
try { cachedContacts = JSON.parse(fs.readFileSync(CONTACTS_FILE, 'utf8')); } catch { /* */ }
const LOG_FILE                = path.join(WS, 'out/whatsapp-wjs-gateway.log');
const ERR_FILE                = path.join(WS, 'out/whatsapp-wjs-errors.log');
const SESSION_DIR             = path.join(WS, 'tmp/wjs-session');

// Per-user DM history
function historyFileFor(num) {
  const safe = num.replace(/[^0-9]/g, '');
  return path.join(WS, `tmp/whatsapp-history-${safe}.jsonl`);
}

// Per-group rolling conversation window (ALL messages, not just Sophia's responses)
function groupHistoryFileFor(chatId) {
  const safe = chatId.replace(/[^0-9a-zA-Z]/g, '-');
  return path.join(WS, `tmp/whatsapp-group-${safe}.jsonl`);
}

function loadGroupHistory(file, n = 12) {
  try {
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8')
      .split('\n').filter(Boolean)
      .slice(-n)
      .map(l => JSON.parse(l));
  } catch { return []; }
}

function appendGroupHistory(name, text, file) {
  try {
    fs.appendFileSync(file, JSON.stringify({ name, text }) + '\n');
  } catch { /* */ }
}

fs.mkdirSync(path.join(WS, 'tmp'), { recursive: true });
fs.mkdirSync(path.join(WS, 'out'), { recursive: true });
fs.mkdirSync(SESSION_DIR, { recursive: true });

// Clear stale Chrome lock files left by crashed instances
for (const f of ['SingletonLock', 'SingletonSocket', 'SingletonCookie']) {
  try { fs.unlinkSync(path.join(SESSION_DIR, 'session', f)); } catch { /* */ }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function log(msg) {
  const ts = new Date().toLocaleTimeString('en-ZA', { timeZone: 'Africa/Johannesburg' });
  process.stdout.write(`[${ts}] ${msg}\n`);
}

function loadHistory(file, n = 20) {
  try {
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file, 'utf8')
      .split('\n').filter(Boolean)
      .slice(-n)
      .map(l => JSON.parse(l));
  } catch { return []; }
}

function appendHistory(role, message, file) {
  try {
    fs.appendFileSync(file, JSON.stringify({ role, message }) + '\n');
  } catch { /* */ }
}

function normaliseNumber(raw) {
  // WhatsApp IDs look like "27821234567@c.us" — strip suffix, ensure +
  const num = raw.replace(/@.+$/, '');
  return num.startsWith('+') ? num : `+${num}`;
}

function runClaude(promptText, model = 'claude-sonnet-4-6') {
  const tmpFile = path.join(os.tmpdir(), `wjs-prompt-${Date.now()}.txt`);
  fs.writeFileSync(tmpFile, promptText);
  try {
    const childEnv = { ...process.env };
    delete childEnv.CLAUDECODE;
    const result = spawnSync(
      'claude',
      ['--print', '--model', model, '--dangerously-skip-permissions'],
      {
        input:     fs.readFileSync(tmpFile),
        env:       childEnv,
        timeout:   120_000,
        maxBuffer: 10 * 1024 * 1024,
      }
    );
    if (result.status !== 0) {
      const err = (result.stderr || Buffer.alloc(0)).toString().slice(0, 300);
      log(`ERROR claude exited ${result.status}: ${err}`);
      try { fs.appendFileSync(ERR_FILE, `[${new Date().toISOString()}] ${err}\n`); } catch { /* */ }
      return null;
    }
    return (result.stdout || Buffer.alloc(0)).toString().trim();
  } catch (e) {
    log(`ERROR running claude: ${e.message}`);
    return null;
  } finally {
    try { fs.unlinkSync(tmpFile); } catch { /* */ }
  }
}

// ── GPT-4o response generation ────────────────────────────────────────────────
function runGPT(systemContent, userContent, model = 'gpt-4o') {
  const key = env.OPENAI_API_KEY || '';
  if (!key) {
    log('WARNING: no OPENAI_API_KEY — falling back to Claude');
    return Promise.resolve(runClaude(`${systemContent}\n\n${userContent}`));
  }
  const payload = Buffer.from(JSON.stringify({
    model,
    messages: [
      { role: 'system', content: systemContent },
      { role: 'user',   content: userContent   },
    ],
    max_tokens:  800,
    temperature: 0.85,
  }));
  return new Promise((resolve) => {
    const req = https.request({
      hostname: 'api.openai.com',
      path:     '/v1/chat/completions',
      method:   'POST',
      headers: {
        'Authorization': `Bearer ${key}`,
        'Content-Type':  'application/json',
        'Content-Length': payload.length,
      },
    }, (res) => {
      let data = '';
      res.on('data', d => { data += d; });
      res.on('end', () => {
        try {
          const r = JSON.parse(data);
          resolve(r?.choices?.[0]?.message?.content?.trim() || null);
        } catch { resolve(null); }
      });
    });
    req.on('error', (e) => { log(`GPT API error: ${e.message}`); resolve(null); });
    req.write(payload);
    req.end();
  });
}

// ── Self-correction validator ──────────────────────────────────────────────────
function findViolations(text) {
  const v = [];
  if (/[-–—]/.test(text))                                          v.push('contains a dash or hyphen — replace with a comma or full stop');
  if (/\bnoted[.!,\s]/i.test(text))                               v.push('"noted" is CRM-speak — engage naturally or say nothing');
  if (/got .{0,25}saved/i.test(text))                             v.push('"got X saved" sounds like a database update — engage with the content instead');
  if (/great to hear from you/i.test(text))                       v.push('"great to hear from you" is hollow filler — remove it');
  if (/hope you.{0,15}(having|doing)/i.test(text))               v.push('generic day-greeting filler — remove it');
  if (/context for .{0,30}(tone|positioning|outreach)/i.test(text)) v.push('report/brief language — this is a WhatsApp chat, write like a human');
  if (/excited.{0,20}technolog/i.test(text))                      v.push('referencing own excitement about technology — remove it');
  if (/opgewonde oor die tegnologie/i.test(text))                 v.push('referencing own excitement about technology (Afrikaans) — remove it');
  return v;
}

// ── Stage-1 classifier: SKIP or RESPOND (cheap, fast, no generation) ──────────
// Only called for group messages — DMs go straight to generation.
// Uses gpt-4o-mini at temperature 0, max 5 tokens — purely a gate decision.
function classifyMessage({ groupName, senderName, senderRole, recentHistory, messageText }) {
  const CLASSIFIER_SYSTEM =
`You are a response gatekeeper for Sophia, an AI WhatsApp CSM at Amalfi AI.
Decide if Sophia should respond to this group message.
Output only one word: RESPOND or SKIP.

SKIP when:
- An Amalfi AI team member (Josh, Salah, Masara) posts any update or statement
- The message is an acknowledgement: thank you, no problem, ok, sounds good, waiting, got it, sure, perfect, noted, done
- Two people are mid-conversation and Sophia is not involved
- The message is a reaction, emoji, or casual closer
- No question is being asked and Sophia would just be adding noise
- Recent messages already cover what Sophia might say

RESPOND when:
- A client directly asks a question about the project, timeline, or features
- A client expresses frustration or concern that needs a CSM voice
- Sophia is explicitly named or addressed
- No one else in the thread can or will answer what the client needs`;

  const classifyUser =
`Group: ${groupName}
Sender: ${senderName}${senderRole ? ` (${senderRole})` : ''}
Recent messages:
${recentHistory || '(no history)'}

New message: ${messageText}`;

  const key = env.OPENAI_API_KEY || '';
  if (!key) return Promise.resolve('RESPOND'); // fail open if no key

  const payload = Buffer.from(JSON.stringify({
    model:       'gpt-4o-mini',
    messages:    [
      { role: 'system', content: CLASSIFIER_SYSTEM },
      { role: 'user',   content: classifyUser },
    ],
    max_tokens:  5,
    temperature: 0,
  }));

  return new Promise((resolve) => {
    const req = https.request({
      hostname: 'api.openai.com',
      path:     '/v1/chat/completions',
      method:   'POST',
      headers: {
        'Authorization':  `Bearer ${key}`,
        'Content-Type':   'application/json',
        'Content-Length': payload.length,
      },
    }, (res) => {
      let data = '';
      res.on('data', d => { data += d; });
      res.on('end', () => {
        try {
          const r = JSON.parse(data);
          const raw = r?.choices?.[0]?.message?.content?.trim().toUpperCase() || 'RESPOND';
          resolve(raw.startsWith('SKIP') ? 'SKIP' : 'RESPOND');
        } catch { resolve('RESPOND'); }
      });
    });
    req.on('error', () => resolve('RESPOND')); // fail open on network error
    req.write(payload);
    req.end();
  });
}

// ── Adaptive per-person memory (runs async after each exchange) ────────────────
function updatePersonMemory(name, userMessage, sophiaReply) {
  if (!name || name === 'User') return;
  const safeN    = name.toLowerCase().replace(/[^a-z0-9]/g, '-');
  const notesFile = path.join(WS, `memory/${safeN}-notes.md`);
  let existing = '';
  try { existing = fs.readFileSync(notesFile, 'utf8'); } catch { /* new person */ }

  const prompt = `You are a memory assistant. Read this WhatsApp exchange and extract any NEW facts, preferences, interests, or context about ${name} that are not already in the notes below. Be brief and specific. Output ONLY new bullet points (e.g. "- Loves F1, McLaren fan"), or output nothing if nothing new was learned.

EXISTING NOTES:
${existing || '(none yet)'}

EXCHANGE:
${name}: ${userMessage}
Sophia: ${sophiaReply}`;

  setImmediate(() => {
    const newFacts = runClaude(prompt, 'claude-haiku-4-5-20251001');
    if (newFacts && newFacts.trim().length > 4 && !newFacts.toLowerCase().includes('nothing new')) {
      const date = new Date().toLocaleDateString('en-ZA', { timeZone: 'Africa/Johannesburg' });
      try {
        fs.appendFileSync(notesFile, `\n<!-- ${date} -->\n${newFacts.trim()}\n`);
        log(`Memory updated for ${name}: ${newFacts.slice(0, 60)}`);
      } catch { /* */ }
    }
  });
}

// ── Message processing (serialised queue) ─────────────────────────────────────
let processing = false;
const queue = [];

async function processNext() {
  if (processing || queue.length === 0) return;
  processing = true;
  const { msg, fromNum, isGroup, isOwner, batchItems } = queue.shift();
  try {
    await handleMessage(msg, fromNum, isGroup, isOwner, batchItems || []);
  } catch (e) {
    log(`ERROR handling message: ${e.message}`);
  }
  processing = false;
  processNext();
}


// ── Reminder extraction ───────────────────────────────────────────────────────
const REMINDERS_FILE = path.join(WS, 'tmp/reminders.json');

function loadReminders() {
  try { return JSON.parse(fs.readFileSync(REMINDERS_FILE, 'utf8')); } catch { return []; }
}

function saveReminders(list) {
  try { fs.writeFileSync(REMINDERS_FILE, JSON.stringify(list, null, 2)); } catch { /* */ }
}

// ── Client brief — live per-message context for known client contacts ──────────
// Maps company name (extracted from role) to Supabase client_id and local repo path
const CLIENT_MAP = {
  'Race Technik':         { id: 'ed045bcb-100f-4fc4-8623-2befcf2c8c14', repo: path.join(WS, 'clients/race-technik'), devKey: 'race-technik' },
  'Vanta Studios':        { id: 'd2a6eb7c-014c-43e6-9a5e-e0d5876c21cc', repo: path.join(WS, 'clients/vanta-studios'), devKey: 'vanta-studios' },
  'Ambassadex':           { id: null,                                     repo: path.join(WS, 'ambassadex'),           devKey: 'ambassadex' },
  'Favorite Logistics':   { id: 'fb9724b4-1d11-43c4-a76c-e82f7b820c11', repo: path.join(WS, 'favorite-flow-9637aff2'), devKey: 'favorite-logistics' },
  'Favlog':               { id: 'fb9724b4-1d11-43c4-a76c-e82f7b820c11', repo: path.join(WS, 'favorite-flow-9637aff2'), devKey: 'favorite-logistics' },
  'Ascend LC':            { id: 'c465aa44-519b-4b35-b4de-2b5c3b89359e', repo: null,                                   devKey: 'ascend-lc' },
};

async function fetchClientBrief(senderRole) {
  // Extract company name from role like "Owner, Vanta Studios"
  const parts = senderRole.split(',');
  const company = (parts[1] || '').trim();
  const clientInfo = CLIENT_MAP[company];
  if (!clientInfo) return '';

  const sections = [];
  const today = new Date().toLocaleString('en-ZA', { timeZone: 'Africa/Johannesburg' }).split(',')[0];

  // 1. Recent git commits for their repo
  if (clientInfo.repo) {
    try {
      const { execSync } = require('child_process');
      const commits = execSync(
        `git -C "${clientInfo.repo}" log --oneline --since="7 days ago" --format="%h %s (%cr)" 2>/dev/null | head -5`,
        { encoding: 'utf8', timeout: 5000 }
      ).trim();
      if (commits) sections.push(`Recent commits:\n${commits}`);
    } catch { /* repo may not have git or no commits */ }
  }

  // 2. Active Supabase tasks for this client
  if (clientInfo.id && SUPABASE_KEY) {
    try {
      const tasksUrl = `${SUPABASE_URL}/rest/v1/tasks?client_id=eq.${clientInfo.id}&status=in.(todo,in_progress)&order=priority.desc&limit=8`;
      const resp = await fetch(tasksUrl, {
        headers: { apikey: SUPABASE_KEY, Authorization: `Bearer ${SUPABASE_KEY}` }
      });
      const tasks = await resp.json();
      if (Array.isArray(tasks) && tasks.length > 0) {
        const taskLines = tasks.map(t => {
          const p = t.priority === 'urgent' ? '[URGENT]' : t.priority === 'high' ? '[HIGH]' : '';
          return `  ${p} [${t.status}] ${t.title}`.trim();
        }).join('\n');
        sections.push(`Active tasks:\n${taskLines}`);
      }
    } catch { /* */ }
  }

  // 3. DEV_STATUS snippet for this client
  try {
    const devStatus = fs.readFileSync(path.join(WS, 'DEV_STATUS.md'), 'utf8');
    const marker = clientInfo.devKey.toLowerCase();
    const lines = devStatus.split('\n');
    const idx = lines.findIndex(l => l.toLowerCase().includes(marker));
    if (idx !== -1) {
      const snippet = lines.slice(idx, idx + 10).join('\n').trim();
      if (snippet) sections.push(`Dev status:\n${snippet}`);
    }
  } catch { /* */ }

  if (!sections.length) return '';
  return `\n=== ${company.toUpperCase()} — CLIENT BRIEF (live as of ${today}) ===\n${sections.join('\n\n')}\n`;
}

function extractAndSaveReminder(fromNum, senderName, userText, sophiaReply) {
  // Quick pre-check — only bother if message smells like a reminder request
  const reminderKeywords = /remind|reminder|don.t forget|follow.?up|check.?in|ping me|alert me/i;
  if (!reminderKeywords.test(userText)) return;

  // Async — don't block the main flow
  (async () => {
    try {
      const now = new Date().toLocaleString('en-ZA', { timeZone: 'Africa/Johannesburg' });
      const prompt = `The user sent this message: "${userText}"
Sophia replied: "${sophiaReply}"
Current date/time (SAST): ${now}

If the user is asking to be reminded of something, extract:
- "message": what to remind them of (short, natural — as Sophia would say it)
- "fireAt": ISO 8601 datetime in UTC when to send the reminder
- "found": true

If no reminder was set, return {"found": false}

Output only JSON.`;

      const result = await runGPT(
        'You are a reminder extraction assistant. Parse reminder requests and output JSON only.',
        prompt, 'gpt-4o-mini'
      );
      if (!result) return;

      const clean = result.trim().replace(/^```json|```$/g, '').trim();
      const parsed = JSON.parse(clean);
      if (!parsed.found || !parsed.fireAt || !parsed.message) return;

      const reminders = loadReminders();
      reminders.push({
        id: Date.now().toString(),
        to: fromNum,
        name: senderName,
        message: parsed.message,
        fireAt: parsed.fireAt,
        fired: false,
        createdAt: new Date().toISOString(),
      });
      saveReminders(reminders);
      log(`Reminder saved for ${senderName}: "${parsed.message}" at ${parsed.fireAt}`);
    } catch (e) {
      log(`Reminder extraction error: ${e.message}`);
    }
  })();
}
// ── End reminder extraction ───────────────────────────────────────────────────

async function handleMessage(msg, fromNum, isGroup, isOwner, batchItems = []) {
  let userText = msg.body || '';
  let mediaNote = '';  // injected into prompt to tell Sophia what kind of media was received

  // ── Voice notes — transcribe via Deepgram ────────────────────────────────────
  if (msg.hasMedia && (msg.type === 'ptt' || msg.type === 'audio')) {
    try {
      const media = await msg.downloadMedia();
      if (media?.data) {
        const transcript = await transcribeAudio(Buffer.from(media.data, 'base64'), media.mimetype);
        if (transcript) {
          userText = transcript;
          mediaNote = '[Voice note transcribed]';
          log(`Voice transcribed: ${transcript.slice(0, 80)}`);
        } else {
          await msg.reply("Sorry, I couldn't make that out. Could you type it out?");
          return;
        }
      }
    } catch (e) { log(`Voice transcription error: ${e.message}`); }
  }

  // ── Images — describe via GPT-4o vision ──────────────────────────────────────
  if (msg.hasMedia && msg.type === 'image') {
    try {
      const media = await msg.downloadMedia();
      if (media?.data) {
        const description = await describeImage(media.data, media.mimetype);
        if (description) {
          mediaNote = `[Image received — description: ${description}]`;
          // Combine caption (if any) with image description
          userText = userText
            ? `${userText}\n\n${mediaNote}`
            : mediaNote;
          log(`Image described: ${description.slice(0, 80)}`);
        }
      }
    } catch (e) { log(`Image vision error: ${e.message}`); }
  }

  if (!userText) return;

  // Load contacts early — needed for quoted message resolution
  let contacts = {};
  try { contacts = JSON.parse(fs.readFileSync(CONTACTS_FILE, 'utf8')); } catch { /* */ }

  function resolveName(num) {
    const normalised = num.replace(/\s/g, '');
    return contacts[normalised]?.name || contacts[`+${normalised.replace(/^\+/, '')}`]?.name || num;
  }

  // Detect reply-to context — inject so Sophia knows who is talking to whom
  let quotedNote = '';
  if (msg.hasQuotedMsg) {
    try {
      const quoted = await msg.getQuotedMessage();
      const qRaw = isGroup ? (quoted.author || quoted.from || '') : (quoted.from || '');
      const qNum = normaliseNumber(qRaw);
      const qName = resolveName(qNum);
      const qText = (quoted.body || '[media]').slice(0, 150);
      quotedNote = `\n[This message is a reply to ${qName}: "${qText}"]`;
    } catch { /* */ }
  }

  let detectedGroupName = '';
  let groupHistFile = null;
  if (isGroup) {
    try { detectedGroupName = (await msg.getChat()).name || msg.from; } catch { detectedGroupName = msg.from; }
    // Check muted groups list — if this group is muted, Sophia stays silent
    try {
      const muted = fs.readFileSync(MUTED_GROUPS_FILE, 'utf8').split('\n').map(l => l.trim()).filter(Boolean);
      if (muted.some(m => detectedGroupName.toLowerCase().includes(m.toLowerCase()))) {
        log(`Group "${detectedGroupName}" is muted — skipping`);
        return;
      }
    } catch { /* file may not exist, that's fine */ }
    groupHistFile = groupHistoryFileFor(msg.from);
    // Log all batch messages to group history BEFORE running Claude
    if (batchItems.length > 1) {
      for (const item of batchItems.slice(0, -1)) {
        appendGroupHistory(resolveName(item.fromNum), item.msg.body || '[media]', groupHistFile);
      }
    }
    appendGroupHistory(resolveName(fromNum), userText + (quotedNote || ''), groupHistFile);
  }
  log(`Message from ${fromNum}${isGroup ? ` (group: "${detectedGroupName}")` : ''}: ${userText.slice(0, 80)}`);

  // ── CODE-LEVEL PRE-FILTER — deterministic, no AI ─────────────────────────────
  // These rules are hard truths. If they fire, Sophia is silent. No API call made.
  if (isGroup) {
    const _pfEntry = contacts[fromNum] || contacts[`+${fromNum.replace(/^\+/, '')}`] || null;
    const _pfRole  = _pfEntry?.role || '';
    const _pfName  = _pfEntry?.name || fromNum;
    const _pfIsTeam = isOwner || _pfRole.includes('Amalfi AI');

    // Rule 1: Any Amalfi AI team member (Josh, Salah, Masara) posting in a client group.
    // Their messages are for the client — Sophia is not part of that exchange.
    if (_pfIsTeam) {
      log(`Pre-filter SKIP: team member "${_pfName}" in group "${detectedGroupName}"`);
      return;
    }

    // Rule 2: Closure / acknowledgement phrases — thread is wrapping up, not opening.
    const CLOSURE_RE = /^(no[\s-]?problem|np|ok(ay)?|sounds good|perfect|great|sure|noted|thanks?(\s+a\s+(lot|million))?|thank\s+you|thx|will\s+do|on\s+it|done|waiting(\s+for\s+(the|that)\s+\w+)?|got\s+it|understood|roger|copy\s+that|lekker|sharp|cool|nice)[.!\s]*[\p{Emoji}\s]*$/iu;
    if (CLOSURE_RE.test(userText.trim())) {
      log(`Pre-filter SKIP: closure phrase "${userText.slice(0, 40)}" from "${_pfName}"`);
      return;
    }

    // Rule 3: Very short non-question (under 12 chars, no "?") — emoji, "👍", "lol", etc.
    if (userText.trim().length < 12 && !userText.includes('?')) {
      log(`Pre-filter SKIP: short non-question "${userText.slice(0, 40)}" from "${_pfName}"`);
      return;
    }

    // Rule 4: Quoted reply to a team member — that is their private thread in the group.
    if (quotedNote && /\[This message is a reply to (Josh|Salah|Masara)/i.test(quotedNote)) {
      log(`Pre-filter SKIP: reply to team member thread from "${_pfName}"`);
      return;
    }

    // Rule 5: Rate limit — if Sophia replied in this chat within the last 90 seconds,
    // stay quiet unless this message contains a direct question.
    const lastReplyTs = sophiaLastReply.get(msg.from);
    if (lastReplyTs && (Date.now() - lastReplyTs) < 90_000 && !userText.includes('?')) {
      const ago = Math.round((Date.now() - lastReplyTs) / 1000);
      log(`Pre-filter SKIP: rate limit (${ago}s since last reply) in "${detectedGroupName}"`);
      return;
    }
  }
  // ── End pre-filter ────────────────────────────────────────────────────────────

  // Build time string
  const today = new Date().toLocaleString('en-ZA', {
    timeZone: 'Africa/Johannesburg',
    weekday: 'long', day: '2-digit', month: 'long', year: 'numeric',
    hour: '2-digit', minute: '2-digit',
  }) + ' SAST';

  const senderName  = resolveName(fromNum);
  const contactEntry = contacts[fromNum] || contacts[`+${fromNum.replace(/^\+/, '')}`] || null;
  const senderRole   = contactEntry?.role || '';

  // Unknown contact handling — name fell back to raw number
  const isUnknown = !contactEntry && senderName === fromNum;
  if (isUnknown && !isGroup && !unknownNotified.has(fromNum)) {
    unknownNotified.add(fromNum);
    const preview = userText.slice(0, 120);
    const ownerJid = (OWNER_NUMBER || '').replace(/^\+/, '') + '@c.us';
    if (ownerJid !== '@c.us') {
      try {
        await client.sendMessage(ownerJid,
          `Unknown number messaged Sophia: ${fromNum}\n\nPreview: "${preview}"\n\nReply with their name so I can save them.`
        );
        log(`Notified Josh of unknown contact: ${fromNum}`);
      } catch (e) { log(`Failed to notify Josh of unknown: ${e.message}`); }
    }
  }

  // Determine which prompt to use:
  // Josh (owner) → Claude assistant
  // Amalfi AI team (Salah, Masara — role contains "Amalfi AI") → Sophia personal DM
  // Clients and unknowns → Sophia CSM (same as groups)
  // Groups → Sophia CSM
  const isTeamMember   = !isOwner && senderRole.includes('Amalfi AI') && !senderRole.includes('this is you');
  const isPersonal     = !isOwner && senderRole === 'Personal';
  const isTrialUser    = !isOwner && senderRole === 'Trial';

  // Trial expiry check — hard cut-off per contact's trialEnd field
  if (isTrialUser && !isGroup) {
    const trialEnd = contactEntry?.trialEnd ? new Date(contactEntry.trialEnd + 'T23:59:59+02:00') : null;
    if (trialEnd && new Date() > trialEnd) {
      log(`Trial expired for ${senderName} (${fromNum}) — sending expiry message`);
      const expiredMsg = `Hey ${senderName}! Just letting you know your free trial with me has come to an end. It was great getting to know you! If you want to keep going, just reach out to Josh at Amalfi AI and he will sort you out. Hope I was useful!`;
      try { await client.sendMessage(msg.from, expiredMsg); } catch (e) { log(`Trial expiry send failed: ${e.message}`); }
      return;
    }
  }

  let promptFile;
  // Telegram is the system-control channel for Josh — on WhatsApp he gets Sophia personal DM
  if (isGroup)                            promptFile = GROUP_SYSTEM_PROMPT_FILE;
  else if (isOwner || isTeamMember)       promptFile = PERSONAL_DM_PROMPT_FILE;
  else if (isPersonal || isTrialUser)     promptFile = PERSONAL_ASSISTANT_PROMPT_FILE;
  else                                    promptFile = GROUP_SYSTEM_PROMPT_FILE;

  let systemPrompt = '';
  try { systemPrompt = fs.readFileSync(promptFile, 'utf8'); } catch {
    systemPrompt = isOwner ? 'You are Claude, Josh\'s AI assistant.' : 'You are Sophia, Amalfi AI\'s assistant.';
  }

  // Per-user isolated history for DMs — groups are stateless
  const histFile    = !isGroup ? historyFileFor(fromNum) : null;
  const history     = histFile ? loadHistory(histFile, 20) : [];
  const historyText = history.map(e => `${e.role}: ${e.message}`).join('\n');

  // Group name → client context mapping
  const GROUP_CLIENT_MAP = [
    { pattern: /race.technik/i,              context: path.join(WS, 'clients/chrome-auto-care/CONTEXT.md') },
    { pattern: /vant[ae]/i,                  context: path.join(WS, 'clients/vanta-studios/CONTEXT.md') },
    { pattern: /favlog|flair|favorite|logistics/i, context: path.join(WS, 'clients/favorite-flow-9637aff2/CONTEXT.md') },
    { pattern: /ascend|qms.guard|edith/i,    context: path.join(WS, 'clients/qms-guard/CONTEXT.md') },
    { pattern: /ambassadex|project.ozayr/i,  context: path.join(WS, 'clients/ambassadex/CONTEXT.md') },
  ];

  // Build channel context block
  let channelLine = '';
  if (isGroup) {
    const groupName = detectedGroupName || msg.from;
    const contactsBlock = Object.entries(contacts)
      .filter(([, v]) => v.role && !v.role.includes('this is you'))
      .map(([num, v]) => `  ${v.name} (${num}) — ${v.role}`)
      .join('\n');
    let clientContext = '';
    const match = GROUP_CLIENT_MAP.find(m => m.pattern.test(groupName));
    if (match?.context) {
      try { clientContext = '\n=== CLIENT CONTEXT ===\n' + fs.readFileSync(match.context, 'utf8'); } catch { /* */ }
      const devStatusFile = match.context.replace('CONTEXT.md', 'DEV_STATUS.md');
      try { clientContext += '\n=== CURRENT DEV STATUS ===\n' + fs.readFileSync(devStatusFile, 'utf8'); } catch { /* */ }
    }
    // Recent group conversation window — gives Sophia threading context
    let recentConvo = '';
    if (groupHistFile) {
      const recent = loadGroupHistory(groupHistFile, 12);
      if (recent.length > 1) {
        recentConvo = '\n=== RECENT GROUP CONVERSATION ===\n' +
          recent.map(e => `${e.name}: ${e.text}`).join('\n') + '\n';
      }
    }
    channelLine = `\nChannel: WhatsApp Group — "${groupName}"\nSender: ${senderName} (${fromNum})\n\nKnown people in this ecosystem:\n${contactsBlock}\n${clientContext}${recentConvo}\n`;
  } else if (isUnknown) {
    channelLine = `\nChannel: WhatsApp DM\nSender: (unrecognised contact — you do not know who this is yet)\n\nIMPORTANT: Do NOT ask who they are. Do NOT say you don't have their number saved. Respond warmly and naturally to the content of their message without using any name. Keep it short. Josh has been alerted separately.\n`;
  } else {
    // Trial users: don't expose their role label to the AI
    const roleDisplay = (isTrialUser || senderRole === 'Personal') ? '' : (senderRole ? ` — ${senderRole}` : '');
    channelLine = `\nChannel: WhatsApp DM\nSender: ${senderName} (${fromNum})${roleDisplay}\n`;
  }

  // Memory, business context, and per-user profile
  // Trial users get isolated context — no client data or internal business state
  let longTermMemory = '';
  if (!isTrialUser) {
    try { longTermMemory = fs.readFileSync(path.join(WS, 'memory/MEMORY.md'), 'utf8'); } catch { /* */ }
  }
  let currentState = '';
  if (!isTrialUser) {
    try { currentState = fs.readFileSync(path.join(WS, 'CURRENT_STATE.md'), 'utf8'); } catch { /* */ }
  }

  let userProfile = '';
  const safeNameKey = senderName.toLowerCase().replace(/[^a-z0-9]/g, '-');
  if (!isGroup) {
    try { userProfile = fs.readFileSync(path.join(WS, `memory/${safeNameKey}-profile.md`), 'utf8'); } catch { /* */ }
    // Also load adaptive notes (built over time from real conversations)
    try { userProfile += '\n' + fs.readFileSync(path.join(WS, `memory/${safeNameKey}-notes.md`), 'utf8'); } catch { /* */ }
  } else {
    // For groups, load per-person notes for the sender if available
    try { userProfile = fs.readFileSync(path.join(WS, `memory/${safeNameKey}-notes.md`), 'utf8'); } catch { /* */ }
  }

  // Sophia awareness feed — full ops feed for Josh; client brief for known clients
  let sophiaAwareness = '';
  if (isOwner) {
    try { sophiaAwareness = fs.readFileSync(path.join(WS, 'memory/sophia-awareness.md'), 'utf8'); } catch { /* */ }
  }
  const awarenessBlock = sophiaAwareness ? `\n=== LIVE ACTIVITY FEED ===\n${sophiaAwareness}\n` : '';

  // Live client brief — injected for known client contacts (not trial, not owner, not team)
  let clientBrief = '';
  if (!isOwner && !isTeamMember && !isTrialUser && !isPersonal && senderRole && senderRole.includes(',')) {
    clientBrief = await fetchClientBrief(senderRole);
  }

  const memBlock = (userProfile || longTermMemory || currentState || sophiaAwareness || clientBrief)
    ? `\n=== ${senderName.toUpperCase()} PROFILE ===\n${userProfile}\n\n=== AMALFI AI MEMORY ===\n${longTermMemory}\n\n=== CURRENT SYSTEM STATE ===\n${currentState}\n${awarenessBlock}${clientBrief}`
    : '';

  const speaker   = senderName !== fromNum ? senderName : (isOwner ? 'Josh' : 'User');
  const respLabel = 'Sophia';

  // If multiple messages arrived in the debounce window, show them all so Sophia has full context
  let batchPrefix = '';
  if (batchItems.length > 1) {
    const earlier = batchItems.slice(0, -1).map(item => {
      const n = resolveName(item.fromNum);
      return `${n}: ${item.msg.body || '[media]'}`;
    }).join('\n');
    batchPrefix = `[${batchItems.length} messages arrived together — review all before deciding whether to respond:]\n${earlier}\n`;
  }

  const messageWithContext = batchPrefix + (quotedNote ? `${userText}${quotedNote}` : userText);

  // GPT-4o: system = Sophia's identity rules, user = all context + message
  const userContent = historyText
    ? `Today: ${today}${channelLine}${memBlock}\n=== RECENT CONVERSATION ===\n${historyText}\n\n${speaker}: ${messageWithContext}`
    : `Today: ${today}${channelLine}${memBlock}\n${speaker}: ${messageWithContext}`;

  if (histFile) appendHistory(speaker, userText, histFile);

  // ── Stage 1: Classify (groups only) — SKIP or RESPOND ────────────────────────
  // Cheap gpt-4o-mini gate. Keeps the expensive generation stage out of conversations
  // that don't need Sophia. DMs skip straight to generation.
  if (isGroup) {
    const recentForClassifier = groupHistFile
      ? loadGroupHistory(groupHistFile, 4).map(e => `${e.name}: ${e.text}`).join('\n')
      : '';
    const classification = await classifyMessage({
      groupName:     detectedGroupName,
      senderName,
      senderRole,
      recentHistory: recentForClassifier,
      messageText:   userText,
    });
    if (classification === 'SKIP') {
      log(`Classifier SKIP: "${userText.slice(0, 60)}" in "${detectedGroupName}"`);
      saveToSupabase({
        chatId: msg.from, fromNum, senderName, isGroup,
        groupName: detectedGroupName,
        clientSlug: resolveSlug(detectedGroupName, fromNum),
        inboundText: userText, outboundText: null, skipped: true,
      });
      return;
    }
    log(`Classifier RESPOND: "${userText.slice(0, 60)}"`);
  }
  // ── End Stage 1 ───────────────────────────────────────────────────────────────

  // Sender lock — hard constraint prepended to system prompt.
  // GPT-4o should address the actual sender, not the client whose name fills the context.
  const senderConstraint = `CRITICAL RULE: The message you are replying to was sent by ${senderName}. Address ${senderName} in your response. Do not open by addressing anyone else by name.\n\n`;
  const lockedSystemPrompt = senderConstraint + systemPrompt;

  // Show typing indicator
  try { await msg.getChat().then(c => c.sendStateTyping()); } catch { /* */ }

  // ── Stage 2: Generate ─────────────────────────────────────────────────────────
  log('Running GPT-4o (Stage 2)...');
  let response = await runGPT(lockedSystemPrompt, userContent);

  if (!response) {
    log('No response from GPT-4o');
    return;
  }

  // Strip surrounding quotation marks GPT-4o sometimes wraps responses in
  response = response.trim().replace(/^["'\u201c\u2018]+|["'\u201d\u2019]+$/g, '').trim();

  // Sophia signals she has nothing to add by replying SKIP
  if (response.trim() === 'SKIP') {
    log('Sophia chose not to respond (SKIP)');
    saveToSupabase({
      chatId:      msg.from,
      fromNum,
      senderName,
      isGroup,
      groupName:   isGroup ? detectedGroupName : null,
      clientSlug:  resolveSlug(isGroup ? detectedGroupName : null, fromNum),
      inboundText: userText,
      outboundText: null,
      skipped:     true,
    });
    return;
  }

  // Self-correction — catch violations before sending
  const violations = findViolations(response);
  if (violations.length > 0) {
    log(`Self-correcting (${violations.length} violation${violations.length > 1 ? 's' : ''}): ${violations.join('; ')}`);
    const fixPrompt = `You wrote this WhatsApp message:\n\n${response}\n\nFix these specific problems:\n${violations.map(v => `- ${v}`).join('\n')}\n\nOutput only the corrected message with no surrounding quotes.`;
    const corrected = await runGPT('You are a WhatsApp message editor. Fix issues in messages exactly as instructed. Output only the corrected message with no surrounding quotes.', fixPrompt, 'gpt-4o-mini');
    if (corrected && corrected.trim() !== 'SKIP') {
      response = corrected.trim().replace(/^["'\u201c\u2018]+|["'\u201d\u2019]+$/g, '').trim();
      log(`Corrected: ${response.slice(0, 80)}`);
    }
  }

  // Send reply — chunk if over 4000 chars
  const chunks = chunkText(response, 4000);
  for (const chunk of chunks) {
    try { await msg.reply(chunk); } catch (e) { log(`Send error: ${e.message}`); }
  }

  // Update rate-limit tracker
  sophiaLastReply.set(msg.from, Date.now());

  if (histFile) appendHistory(respLabel, response, histFile);
  if (groupHistFile) appendGroupHistory('Sophia', response, groupHistFile);

  // Persist exchange to Supabase
  saveToSupabase({
    chatId:      msg.from,
    fromNum,
    senderName,
    isGroup,
    groupName:   isGroup ? detectedGroupName : null,
    clientSlug:  resolveSlug(isGroup ? detectedGroupName : null, fromNum),
    inboundText: userText,
    outboundText: response,
    skipped:     false,
  });

  // Adaptive memory — async background update after each exchange
  updatePersonMemory(senderName, userText, response);

  // Reminder extraction — detect if user set a reminder, persist it
  extractAndSaveReminder(fromNum, senderName, userText, response);

  // Daily log
  try {
    const dateStr = new Date().toLocaleDateString('en-ZA', { timeZone: 'Africa/Johannesburg' })
      .split('/').reverse().join('-');
    const ts = new Date().toLocaleTimeString('en-ZA', { timeZone: 'Africa/Johannesburg', hour: '2-digit', minute: '2-digit' });
    const label = isGroup ? 'WhatsApp Group' : 'WhatsApp DM';
    fs.appendFileSync(
      path.join(WS, `memory/${dateStr}.md`),
      `\n### ${ts} SAST — ${label}\n**${speaker}:** ${userText}\n**${respLabel}:** ${response}\n`
    );
  } catch { /* */ }

  log(`Replied: ${response.slice(0, 80)}`);
}

function chunkText(text, maxLen) {
  if (text.length <= maxLen) return [text];
  const chunks = [];
  let current = '';
  for (const para of text.split('\n\n')) {
    if (current.length + para.length + 2 > maxLen - 200) {
      if (current) chunks.push(current.trim());
      current = para;
    } else {
      current += (current ? '\n\n' : '') + para;
    }
  }
  if (current) chunks.push(current.trim());
  return chunks;
}

// ── Supabase storage ──────────────────────────────────────────────────────────

// Resolve group name to client slug for cross-referencing
const SLUG_MAP = [
  { pattern: /race.technik/i,              slug: 'race_technik' },
  { pattern: /vant[ae]/i,                  slug: 'vanta_studios' },
  { pattern: /favlog|flair|favorite|logistics/i, slug: 'favorite_logistics' },
  { pattern: /ascend|qms.guard|edith/i,    slug: 'ascend_lc' },
  { pattern: /ambassadex|project.ozayr/i,  slug: 'ambassadex' },
];

function resolveSlug(groupName, fromNum) {
  if (groupName) {
    const m = SLUG_MAP.find(x => x.pattern.test(groupName));
    if (m) return m.slug;
  }
  // For DMs, try to find the slug by the sender's role
  try {
    const c = cachedContacts[fromNum] || cachedContacts[`+${fromNum.replace(/^\+/, '')}`];
    if (c?.slug) return c.slug;
  } catch { /* */ }
  return null;
}

// Save a WhatsApp exchange to Supabase (fire-and-forget — never throws)
function saveToSupabase(params) {
  if (!SUPABASE_KEY) return;
  const body = JSON.stringify({
    chat_id:      params.chatId,
    from_number:  params.fromNum,
    sender_name:  params.senderName,
    is_group:     params.isGroup,
    group_name:   params.groupName || null,
    client_slug:  params.clientSlug || null,
    inbound_text: params.inboundText,
    outbound_text: params.outboundText || null,
    skipped:      params.skipped || false,
  });
  const url = new URL(`${SUPABASE_URL}/rest/v1/whatsapp_messages`);
  const opts = {
    hostname: url.hostname,
    path:     url.pathname,
    method:   'POST',
    headers: {
      'Content-Type':  'application/json',
      'apikey':        SUPABASE_KEY,
      'Authorization': `Bearer ${SUPABASE_KEY}`,
      'Prefer':        'return=minimal',
    },
  };
  const req = https.request(opts, () => {});
  req.on('error', e => log(`Supabase save error: ${e.message}`));
  req.write(body);
  req.end();
}

// ── Media helpers ─────────────────────────────────────────────────────────────

// Transcribe voice note via Deepgram nova-2
function transcribeAudio(audioBuffer, mimetype) {
  const key = env.DEEPGRAM_API_KEY || '';
  if (!key) return Promise.resolve(null);
  return new Promise((resolve) => {
    const opts = {
      hostname: 'api.deepgram.com',
      path: '/v1/listen?model=nova-2&detect_language=true',
      method: 'POST',
      headers: {
        'Authorization': `Token ${key}`,
        'Content-Type': mimetype || 'audio/ogg',
        'Content-Length': audioBuffer.length,
      },
    };
    const req = https.request(opts, (res) => {
      let data = '';
      res.on('data', d => { data += d; });
      res.on('end', () => {
        try {
          const r = JSON.parse(data);
          const lang = r?.results?.channels?.[0]?.detected_language || '';
          const text = r?.results?.channels?.[0]?.alternatives?.[0]?.transcript || '';
          const prefix = lang && lang !== 'en' ? `[${lang}] ` : '';
          resolve(text ? prefix + text : null);
        } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.write(audioBuffer);
    req.end();
  });
}

// Describe image via GPT-4o vision
function describeImage(base64Data, mimetype) {
  const key = env.OPENAI_API_KEY || '';
  if (!key) return Promise.resolve(null);
  const payload = Buffer.from(JSON.stringify({
    model: 'gpt-4o',
    messages: [{
      role: 'user',
      content: [
        { type: 'image_url', image_url: { url: `data:${mimetype || 'image/jpeg'};base64,${base64Data}` } },
        { type: 'text', text: 'Describe this image in detail. Be specific — include any text, people, objects, context, and what appears to be happening.' },
      ],
    }],
    max_tokens: 600,
  }));
  return new Promise((resolve) => {
    const opts = {
      hostname: 'api.openai.com',
      path: '/v1/chat/completions',
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${key}`,
        'Content-Type': 'application/json',
        'Content-Length': payload.length,
      },
    };
    const req = https.request(opts, (res) => {
      let data = '';
      res.on('data', d => { data += d; });
      res.on('end', () => {
        try {
          const r = JSON.parse(data);
          resolve(r?.choices?.[0]?.message?.content || null);
        } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.write(payload);
    req.end();
  });
}

// ── WhatsApp client ───────────────────────────────────────────────────────────
const client = new Client({
  authStrategy: new LocalAuth({ dataPath: SESSION_DIR }),
  pairWithPhoneNumber: { phoneNumber: '27645066729' },
  webVersionCache: {
    type: 'local',
    path: '/Users/henryburton/.openclaw/workspace-anthropic/tmp/wwebjs_cache/',
  },
  puppeteer: {
    headless: true,
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
    protocolTimeout: 120000,
  },
});

client.on('code', (code) => {
  log('');
  log('══════════════════════════════════════════');
  log(`  PAIRING CODE: ${code}`);
  log('══════════════════════════════════════════');
  log('On the bot phone (+27645066729):');
  log('WhatsApp → ... → Linked Devices → Link a Device');
  log('Tap "Link with phone number" and enter the code above.');
  log('');
});

client.on('qr', (qr) => {
  log('QR fallback (pairing code unavailable) — scan with bot phone:');
  qrcode.generate(qr, { small: true });
});

client.on('authenticated', () => log('Authenticated — session saved'));
client.on('auth_failure', (msg) => log(`Auth failure: ${msg}`));

// Pre-build LID map from all contacts WhatsApp knows about.
// Called at startup and refreshed every 2h so LID changes (device re-link, DM vs group context)
// are caught automatically without waiting for a message to arrive.
async function buildLidMap() {
  try {
    const allContacts = await client.getContacts();
    // Refresh module-level contacts cache
    try { cachedContacts = JSON.parse(fs.readFileSync(CONTACTS_FILE, 'utf8')); } catch { /* */ }
    const knownContacts = cachedContacts;
    let newMappings = 0;
    for (const contact of allContacts) {
      if (!contact.id || !contact.id.user) continue;
      const jidNum = normaliseNumber(contact.id.user);
      if (knownContacts[jidNum] || lidMap[jidNum]) continue; // already known
      const pushname = (contact.pushname || contact.name || '').toLowerCase().trim();
      if (!pushname) continue;
      for (const [realNum, info] of Object.entries(knownContacts)) {
        const knownName = info.name.toLowerCase();
        const firstWord = pushname.split(' ')[0];
        // Require exact match OR first-name exact match with 5+ chars (avoids common short names)
        const isMatch = knownName === pushname ||
                        (firstWord.length >= 5 && firstWord === knownName) ||
                        (firstWord.length >= 5 && knownName.startsWith(firstWord + ' '));
        if (isMatch) {
          lidMap[jidNum] = realNum;
          newMappings++;
          log(`LID pre-mapped (pushname "${pushname}"): ${jidNum} → ${realNum} (${info.name})`);
          break;
        }
      }
    }
    if (newMappings > 0) saveLidMap();
    log(`LID map: ${newMappings} new mapping(s), ${Object.keys(lidMap).length} total`);
  } catch (e) {
    log(`buildLidMap error: ${e.message}`);
  }
}

client.on('ready', () => {
  clientReady = true;
  log('WhatsApp client ready — listening for all messages (DMs + groups)');
  log(`Josh mode active for: ${OWNER_NUMBER || '(not set)'}`);
  // Build LID map after brief settle time, then refresh every 2h
  setTimeout(() => buildLidMap(), 8000);
  setInterval(() => buildLidMap(), 2 * 60 * 60 * 1000);
});

client.on('disconnected', (reason) => {
  clientReady = false;
  log(`Disconnected: ${reason} — will reconnect`);
  setTimeout(() => client.initialize(), 5000);
});

client.on('message', async (msg) => {
  if (msg.from === 'status@broadcast' || msg.id.remote === 'status@broadcast') return;

  const isGroup = msg.from.endsWith('@g.us');

  // Resolve real phone number — WhatsApp multi-device uses LIDs (long internal IDs)
  // instead of real numbers. Check LID map first, then fall back to getContact().
  const rawSender = isGroup ? (msg.author || '') : msg.from;
  const rawNorm   = normaliseNumber(rawSender);

  let fromNum;
  if (lidMap[rawNorm]) {
    // Already know this LID — fast path, no API call needed
    fromNum = lidMap[rawNorm];
  } else {
    try {
      const contact = await msg.getContact();
      const num = contact.number || contact.id.user;
      const resolvedNum = num.startsWith('+') ? num : '+' + num;

      if (cachedContacts[resolvedNum]) {
        // getContact() gave us a real number we recognise — check if it's a new LID alias
        fromNum = resolvedNum;
        if (rawNorm && rawNorm !== fromNum) {
          lidMap[rawNorm] = fromNum;
          saveLidMap();
          log(`LID mapped (contact match): ${rawNorm} → ${fromNum}`);
        }
      } else {
        // getContact() returned an unknown number (possibly the LID itself).
        // Try pushname-based lookup as fallback — match contact.pushname against known names.
        const pushname = (contact.pushname || contact.name || '').toLowerCase().trim();
        let pushnameMatch = null;
        if (pushname) {
          for (const [knownNum, info] of Object.entries(cachedContacts)) {
            const knownName = info.name.toLowerCase();
            const firstWord = pushname.split(' ')[0];
            const isMatch = knownName === pushname ||
                            (firstWord.length >= 5 && firstWord === knownName) ||
                            (firstWord.length >= 5 && knownName.startsWith(firstWord + ' '));
            if (isMatch) {
              pushnameMatch = knownNum;
              break;
            }
          }
        }
        if (pushnameMatch) {
          fromNum = pushnameMatch;
          lidMap[rawNorm] = fromNum;
          saveLidMap();
          log(`LID mapped (pushname "${contact.pushname}"): ${rawNorm} → ${fromNum}`);
        } else {
          fromNum = resolvedNum;
          // Log prominently so we can add it manually
          log(`UNKNOWN LID: ${rawNorm} → ${resolvedNum} (pushname: "${contact.pushname || '?'}")`);
        }
      }
    } catch {
      fromNum = rawNorm;
    }
  }

  const isOwner = OWNER_NUMBER && fromNum.replace(/\s/g, '') === OWNER_NUMBER.replace(/\s/g, '');

  // All chats debounced — accumulate messages per chat, fire once after 3min of silence
  const chatId = msg.from;
  const item = { msg, fromNum, isGroup, isOwner };

  if (!pendingBatches.has(chatId)) {
    pendingBatches.set(chatId, { items: [] });
  }
  const batch = pendingBatches.get(chatId);
  if (batch.timer) clearTimeout(batch.timer);
  batch.items.push(item);

  batch.timer = setTimeout(() => {
    pendingBatches.delete(chatId);
    if (batch.items.length > 0) {
      const last = batch.items[batch.items.length - 1];
      queue.push({ ...last, batchItems: batch.items });
      processNext();
    }
  }, isGroup ? DEBOUNCE_GROUP_MS : DEBOUNCE_DM_MS);
});

client.on('disconnected', (reason) => {
  log(`Disconnected: ${reason} — will reconnect`);
  setTimeout(() => client.initialize(), 5000);
});

// ── Outbound HTTP API (localhost:3001) ────────────────────────────────────────
// POST /send  { "to": "+27812705358", "message": "Hello" }
// POST /send  { "to": "groupname", "message": "Hello" }  (partial name match)
const API_PORT = 3001;
let clientReady = false;

const apiServer = http.createServer(async (req, res) => {
  // GET /dump-participants — real WA numbers for all group members
  if (req.method === 'GET' && req.url === '/dump-participants') {
    if (!clientReady) { res.writeHead(503); return res.end(JSON.stringify({ error: 'not ready' })); }
    try {
      const chats = await client.getChats();
      const result = {};
      for (const g of chats.filter(c => c.isGroup)) {
        result[g.name] = (g.participants || []).map(p => ({
          number: '+' + p.id.user,
          id: p.id._serialized,
        }));
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(result, null, 2));
    } catch (e) { res.writeHead(500); return res.end(JSON.stringify({ error: e.message })); }
  }

  // GET /join-and-read?invite=CODE — join a group via invite link, return recent messages
  if (req.method === 'GET' && req.url.startsWith('/join-and-read')) {
    if (!clientReady) { res.writeHead(503); return res.end(JSON.stringify({ error: 'not ready' })); }
    try {
      const inviteCode = new URL(req.url, 'http://localhost').searchParams.get('invite');
      if (!inviteCode) { res.writeHead(400); return res.end(JSON.stringify({ error: 'invite param required' })); }
      const chatId = await client.acceptInvite(inviteCode);
      const chat = await client.getChatById(chatId);
      const messages = await chat.fetchMessages({ limit: 50 });
      const out = {
        groupName: chat.name,
        chatId,
        messages: messages.map(m => ({
          from: '+' + (m.author || m.from || '').replace(/@.+$/, ''),
          body: m.body,
          ts: new Date(m.timestamp * 1000).toISOString(),
        })),
      };
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(out, null, 2));
    } catch (e) { res.writeHead(500); return res.end(JSON.stringify({ error: e.message })); }
  }

  if (req.method !== 'POST' || req.url !== '/send') {
    res.writeHead(404);
    return res.end('Not found');
  }
  let body = '';
  req.on('data', d => { body += d; });
  req.on('end', async () => {
    try {
      const { to, message } = JSON.parse(body);
      if (!to || !message) {
        res.writeHead(400);
        return res.end(JSON.stringify({ error: 'to and message required' }));
      }
      if (!clientReady) {
        res.writeHead(503);
        return res.end(JSON.stringify({ error: 'WhatsApp client not ready' }));
      }

      // Resolve: phone number → WA ID, or partial group name match
      let chatId;
      const cleanTo = to.replace(/\s/g, '').replace(/^\+/, '');
      if (/^\d+$/.test(cleanTo)) {
        chatId = `${cleanTo}@c.us`;
      } else {
        // Try to find a group by partial name
        const chats = await client.getChats();
        const group = chats.find(c => c.isGroup && c.name.toLowerCase().includes(to.toLowerCase()));
        if (!group) {
          res.writeHead(404);
          return res.end(JSON.stringify({ error: `No group matching "${to}"` }));
        }
        chatId = group.id._serialized;
      }

      const chunks = chunkText(message, 4000);
      for (const chunk of chunks) {
        await client.sendMessage(chatId, chunk);
      }
      log(`Outbound → ${to}: ${message.slice(0, 80)}`);
      res.writeHead(200);
      res.end(JSON.stringify({ ok: true, to, chatId }));
    } catch (e) {
      log(`API error: ${e.message}`);
      res.writeHead(500);
      res.end(JSON.stringify({ error: e.message }));
    }
  });
});

apiServer.listen(API_PORT, '127.0.0.1', () => {
  log(`Outbound API listening on localhost:${API_PORT}`);
});

// ── WhatsApp client ───────────────────────────────────────────────────────────
log('Starting WhatsApp client...');
client.initialize();
