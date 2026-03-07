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
const SYSTEM_PROMPT_FILE      = path.join(WS, 'prompts/telegram-claude-system.md');
const GROUP_SYSTEM_PROMPT_FILE = path.join(WS, 'prompts/sophia-whatsapp-group.md');
const PERSONAL_DM_PROMPT_FILE        = path.join(WS, 'prompts/sophia-personal-dm.md');
const PERSONAL_ASSISTANT_PROMPT_FILE = path.join(WS, 'prompts/sophia-personal-assistant.md');
const CONTACTS_FILE           = path.join(WS, 'memory/whatsapp-contacts.json');
const MUTED_GROUPS_FILE       = path.join(WS, 'tmp/whatsapp-muted-groups.txt');
const LID_MAP_FILE            = path.join(WS, 'memory/whatsapp-lid-map.json');

// 3-minute debounce — accumulate messages per chat, fire once after silence
const DEBOUNCE_MS    = 3 * 60 * 1000;
const pendingBatches = new Map(); // chatId → { items: [...], timer }

// Track unknown numbers already flagged to Josh this session (avoids repeat pings)
const unknownNotified = new Set();

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
  let promptFile;
  if (isGroup)           promptFile = GROUP_SYSTEM_PROMPT_FILE;
  else if (isOwner)      promptFile = SYSTEM_PROMPT_FILE;
  else if (isTeamMember) promptFile = PERSONAL_DM_PROMPT_FILE;
  else if (isPersonal)   promptFile = PERSONAL_ASSISTANT_PROMPT_FILE;
  else                   promptFile = GROUP_SYSTEM_PROMPT_FILE;

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
    { pattern: /ambassadex/i,               context: path.join(WS, 'clients/ambassadex/CONTEXT.md') },
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
    channelLine = `\nChannel: WhatsApp DM\nSender: ${senderName} (${fromNum})${senderRole ? ` — ${senderRole}` : ''}\n`;
  }

  // Memory, business context, and per-user profile
  let longTermMemory = '';
  try { longTermMemory = fs.readFileSync(path.join(WS, 'memory/MEMORY.md'), 'utf8'); } catch { /* */ }
  let currentState = '';
  try { currentState = fs.readFileSync(path.join(WS, 'CURRENT_STATE.md'), 'utf8'); } catch { /* */ }

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

  const memBlock = (userProfile || longTermMemory || currentState)
    ? `\n=== ${senderName.toUpperCase()} PROFILE ===\n${userProfile}\n\n=== AMALFI AI MEMORY ===\n${longTermMemory}\n\n=== CURRENT SYSTEM STATE ===\n${currentState}\n`
    : '';

  const speaker   = senderName !== fromNum ? senderName : (isOwner ? 'Josh' : 'User');
  const respLabel = isOwner ? 'Claude' : 'Sophia';

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

  // Show typing indicator
  try { await msg.getChat().then(c => c.sendStateTyping()); } catch { /* */ }

  log('Running GPT-4o...');
  let response = await runGPT(systemPrompt, userContent);

  if (!response) {
    log('No response from GPT-4o');
    return;
  }

  // Sophia signals she has nothing to add by replying SKIP
  if (response.trim() === 'SKIP') {
    log('Sophia chose not to respond (SKIP)');
    return;
  }

  // Self-correction — catch violations before sending
  const violations = findViolations(response);
  if (violations.length > 0) {
    log(`Self-correcting (${violations.length} violation${violations.length > 1 ? 's' : ''}): ${violations.join('; ')}`);
    const fixPrompt = `You wrote this WhatsApp message:\n\n"${response}"\n\nFix these specific problems:\n${violations.map(v => `- ${v}`).join('\n')}\n\nOutput only the corrected message, nothing else.`;
    const corrected = await runGPT('You are a WhatsApp message editor. Fix issues in messages exactly as instructed. Output only the corrected message.', fixPrompt, 'gpt-4o-mini');
    if (corrected && corrected.trim() !== 'SKIP') {
      response = corrected.trim();
      log(`Corrected: ${response.slice(0, 80)}`);
    }
  }

  // Send reply — chunk if over 4000 chars
  const chunks = chunkText(response, 4000);
  for (const chunk of chunks) {
    try { await msg.reply(chunk); } catch (e) { log(`Send error: ${e.message}`); }
  }

  if (histFile) appendHistory(respLabel, response, histFile);
  if (groupHistFile) appendGroupHistory('Sophia', response, groupHistFile);

  // Adaptive memory — async background update after each exchange
  updatePersonMemory(senderName, userText, response);

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
    type: 'remote',
    remotePath: 'https://raw.githubusercontent.com/wppconnect-team/wa-version/main/html/2.3000.1023554069-alpha.html',
  },
  puppeteer: {
    headless: true,
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
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
  }, DEBOUNCE_MS);
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
