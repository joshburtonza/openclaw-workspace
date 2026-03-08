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

const { Client, LocalAuth, MessageMedia } = require('whatsapp-web.js');
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
      '/Users/henryburton/.openclaw/bin/claude-gated',
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

// ── Telegram alert (fire-and-forget) ───────────────────────────────────────────
function notifyTelegram(text) {
  const token = env.TELEGRAM_BOT_TOKEN;
  const chatId = env.TELEGRAM_JOSH_CHAT_ID;
  if (!token || !chatId) return;
  const payload = JSON.stringify({ chat_id: chatId, text, parse_mode: 'Markdown' });
  const req = https.request({
    hostname: 'api.telegram.org',
    path: `/bot${token}/sendMessage`,
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
  });
  req.on('error', (e) => log(`Telegram notify error: ${e.message}`));
  req.write(payload);
  req.end();
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
const REMINDERS_FILE      = path.join(WS, 'tmp/reminders.json');
const PROACTIVE_QUEUE_FILE = path.join(WS, 'tmp/proactive-queue.json');

function loadReminders() {
  try { return JSON.parse(fs.readFileSync(REMINDERS_FILE, 'utf8')); } catch { return []; }
}

function saveReminders(list) {
  try { fs.writeFileSync(REMINDERS_FILE, JSON.stringify(list, null, 2)); } catch { /* */ }
}

function loadProactiveQueue() {
  try { return JSON.parse(fs.readFileSync(PROACTIVE_QUEUE_FILE, 'utf8')); } catch { return []; }
}

function saveProactiveQueue(list) {
  try { fs.writeFileSync(PROACTIVE_QUEUE_FILE, JSON.stringify(list, null, 2)); } catch { /* */ }
}

// Resolve a phone number or partial group name to a WA chat ID
function resolveChatId(to) {
  if (!to) return null;
  // Already a WA ID
  if (to.endsWith('@c.us') || to.endsWith('@g.us')) return to;
  // Phone number
  const digits = to.replace(/\D/g, '');
  if (digits.length >= 8) return digits + '@c.us';
  return null;
}

// Check reminders.json and proactive-queue.json; fire any that are due
async function checkAndFireProactive() {
  if (!clientReady) return;
  const now = new Date();

  // ── Reminders ──────────────────────────────────────────────────────────────
  const reminders = loadReminders();
  let rChanged = false;
  for (const r of reminders) {
    if (r.fired) continue;
    if (new Date(r.fireAt) > now) continue;
    const chatId = resolveChatId(r.to);
    if (!chatId) { r.fired = true; rChanged = true; continue; }
    try {
      await client.sendMessage(chatId, r.message);
      log(`Reminder fired → ${r.name || r.to}: "${r.message.slice(0, 60)}"`);
    } catch (e) {
      log(`Reminder fire error: ${e.message}`);
    }
    r.fired = true;
    rChanged = true;
  }
  if (rChanged) saveReminders(reminders);

  // ── Proactive queue ────────────────────────────────────────────────────────
  const queue = loadProactiveQueue();
  const remaining = [];
  for (const item of queue) {
    if (item.sendAt && new Date(item.sendAt) > now) { remaining.push(item); continue; }
    const chatId = resolveChatId(item.to);
    if (!chatId) continue;
    try {
      await client.sendMessage(chatId, item.message);
      log(`Proactive sent → ${item.to}: "${item.message.slice(0, 60)}"`);
    } catch (e) {
      log(`Proactive send error: ${e.message}`);
      remaining.push(item); // retry next cycle
    }
  }
  if (remaining.length !== queue.length) saveProactiveQueue(remaining);
}

// ── Client brief — live per-message context for known client contacts ──────────
// Maps company name (extracted from role) to Supabase client_id and local repo path
const CLIENT_MAP = {
  'Race Technik':         { id: 'ed045bcb-100f-4fc4-8623-2befcf2c8c14', repo: path.join(WS, 'clients/race-technik'), devKey: 'race-technik' },
  'Vanta Studios':        { id: 'd2a6eb7c-014c-43e6-9a5e-e0d5876c21cc', repo: path.join(WS, 'clients/vanta-studios'), devKey: 'vanta-studios' },
  'Ambassadex':           { id: null,                                     repo: path.join(WS, 'ambassadex'),           devKey: 'ambassadex' },
  'Favorite Logistics':   { id: 'fb9724b4-1d11-43c4-a76c-e82f7b820c11', repo: path.join(WS, 'favorite-flow-9637aff2'), devKey: 'favorite-logistics' },
  'Favlog':               { id: 'fb9724b4-1d11-43c4-a76c-e82f7b820c11', repo: path.join(WS, 'favorite-flow-9637aff2'), devKey: 'favorite-logistics' },
  'Ascend LC':            { id: 'c465aa44-519b-4b35-b4de-2b5c3b89359e', repo: path.join(WS, 'clients/qms-guard'),   devKey: 'ascend-lc' },
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

  // 2. Active Supabase tasks for this client (tagged by devKey slug)
  if (clientInfo.devKey && SUPABASE_KEY) {
    try {
      const tasksUrl = `${SUPABASE_URL}/rest/v1/tasks?tags=cs.{${clientInfo.devKey}}&status=in.(todo,in_progress)&order=priority.desc&limit=8`;
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

  // 3. DEV_STATUS — read from the client's own repo (written nightly by update-dev-status.sh)
  try {
    const devStatusPath = clientInfo.repo
      ? path.join(clientInfo.repo, 'DEV_STATUS.md')
      : path.join(WS, 'DEV_STATUS.md');
    const devStatus = fs.readFileSync(devStatusPath, 'utf8');
    // Strip markdown code fences and grab the first ~20 meaningful lines
    const cleaned = devStatus.replace(/```[a-z]*\n?/g, '').trim();
    const snippet = cleaned.split('\n').slice(0, 20).join('\n').trim();
    if (snippet) sections.push(`Dev status:\n${snippet}`);
  } catch { /* */ }

  // 4. Client context.md (relationship notes, key people, what matters to them)
  if (clientInfo.repo) {
    try {
      const ctxPath = path.join(clientInfo.repo, 'context.md');
      const ctx = fs.readFileSync(ctxPath, 'utf8');
      // First 40 lines covers all the important context without overloading the prompt
      const snippet = ctx.split('\n').slice(0, 40).join('\n').trim();
      if (snippet) sections.push(`Client context:\n${snippet}`);
    } catch { /* */ }
  }

  if (!sections.length) return '';
  return `\n=== ${company.toUpperCase()} — CLIENT BRIEF (live as of ${today}) ===\n${sections.join('\n\n')}\n`;
}

// extractAndSaveReminder — runs on every owner message, detects explicit + implicit
// reminders AND action tasks from free text. Saves to reminders.json or Supabase tasks.
function extractAndSaveReminder(fromNum, senderName, userText, sophiaReply) {
  // Async — don't block the main flow
  (async () => {
    try {
      const now = new Date().toLocaleString('en-ZA', { timeZone: 'Africa/Johannesburg' });
      const prompt = `You are a proactive assistant analysing a WhatsApp message for implicit actions.

User message: "${userText}"
Sophia's reply: "${sophiaReply}"
Current SAST time: ${now}

Extract any of the following (output JSON only, no markdown):

{
  "reminder": {                  // if user wants a timed reminder (explicit or implicit)
    "found": true/false,
    "message": "...",            // short natural reminder text as Sophia would say it
    "fireAt": "ISO8601 UTC"      // when to send it
  },
  "task": {                      // if there's an action item for Josh/Amalfi to do
    "found": true/false,
    "title": "...",
    "priority": "normal|high|urgent",
    "dueDate": "YYYY-MM-DD or null"
  }
}

Rules:
- A reminder is something time-based Josh wants to be alerted about ("remind me", "don't let me forget", "ping me at 3", "I have a thing Thursday", "follow up with X tomorrow")
- A task is a clear to-do Josh or Amalfi should action ("I need to send X", "we must fix Y", "follow up with Z")
- If nothing applies, return {"reminder":{"found":false},"task":{"found":false}}
- Only extract if genuinely present — don't hallucinate
- "message" for reminders should sound like Sophia talking: warm, direct, no filler`;

      const result = await runGPT(
        'You extract structured actions from messages. Output only valid JSON.',
        prompt, 'gpt-4o-mini'
      );
      if (!result) return;

      const clean = result.trim().replace(/^```json\n?|```$/g, '').trim();
      const parsed = JSON.parse(clean);

      // Save reminder
      if (parsed.reminder?.found && parsed.reminder.fireAt && parsed.reminder.message) {
        const reminders = loadReminders();
        reminders.push({
          id: Date.now().toString(),
          to: fromNum,
          name: senderName,
          message: parsed.reminder.message,
          fireAt: parsed.reminder.fireAt,
          fired: false,
          createdAt: new Date().toISOString(),
        });
        saveReminders(reminders);
        log(`Reminder saved for ${senderName}: "${parsed.reminder.message}" at ${parsed.reminder.fireAt}`);
      }

      // Save task to Supabase
      if (parsed.task?.found && parsed.task.title && SUPABASE_KEY) {
        const taskBody = JSON.stringify({
          title: parsed.task.title,
          status: 'todo',
          priority: parsed.task.priority || 'normal',
          ...(parsed.task.dueDate ? { due_date: parsed.task.dueDate } : {}),
          source: 'sophia-whatsapp',
        });
        const url = new URL(`${SUPABASE_URL}/rest/v1/tasks`);
        const req = https.request({
          hostname: url.hostname, path: url.pathname, method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'apikey': SUPABASE_KEY,
            'Authorization': `Bearer ${SUPABASE_KEY}`,
            'Prefer': 'return=minimal',
          },
        }, (res) => { res.resume(); });
        req.on('error', () => {});
        req.write(taskBody);
        req.end();
        log(`Task created from free text: "${parsed.task.title}" [${parsed.task.priority}]`);
      }
    } catch (e) {
      log(`Reminder/task extraction error: ${e.message}`);
    }
  })();
}
// ── End reminder/task extraction ───────────────────────────────────────────────

// ── Google Meet scheduling (WhatsApp) ────────────────────────────────────────
const MEET_KEYWORDS = /\b(schedule|set up|create|book|organise|organize).{0,20}(meet(ing)?|call|google meet|video call|zoom|hangout)|google meet|schedule.{0,10}(a |the )?(call|catch.?up|sync|standup|check.?in)\b/i;

async function handleMeetingSchedule(chatId, userText) {
  if (!clientReady) return false;

  await client.sendMessage(chatId, '📅 On it — let me parse the details...');

  // GPT-4o-mini to extract meeting params from free text
  const today = new Date().toLocaleDateString('en-ZA', { timeZone: 'Africa/Johannesburg', weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
  const todayISO = new Date().toLocaleDateString('en-CA', { timeZone: 'Africa/Johannesburg' }); // YYYY-MM-DD

  const extracted = await runGPT(
    `You are a calendar assistant. Extract meeting details from the user's message. Today is ${today} (${todayISO}, SAST UTC+2).
Return ONLY valid JSON with these fields:
- title: string (meeting title/summary)
- date: string (YYYY-MM-DD, interpret relative dates like "tomorrow", "Tuesday", etc.)
- time: string (HH:MM in 24h SAST, default "10:00" if not specified)
- duration: number (minutes, default 60)
- attendees: array of strings (email addresses — include any emails mentioned)
- description: string or null
If you cannot determine a date, use null for date.`,
    userText,
    'gpt-4o-mini'
  );

  let params;
  try {
    const clean = (extracted || '').replace(/```json\n?|\n?```/g, '').trim();
    params = JSON.parse(clean);
  } catch {
    await client.sendMessage(chatId, "❌ Couldn't parse meeting details. Try: \"Schedule a meet with john@example.com on Tuesday at 2pm, 1 hour, about Q1 review\"");
    return true;
  }

  if (!params.date) {
    await client.sendMessage(chatId, '❓ What date should I schedule this for? (e.g. "Tuesday" or "2026-03-10")');
    return true;
  }
  if (!params.attendees || params.attendees.length === 0) {
    await client.sendMessage(chatId, '❓ Who should I invite? Please include their email address(es).');
    return true;
  }

  // Build RFC3339 times in SAST (UTC+2)
  const [h, m] = (params.time || '10:00').split(':').map(Number);
  const startMs = new Date(`${params.date}T${String(h).padStart(2,'0')}:${String(m).padStart(2,'0')}:00+02:00`);
  const endMs   = new Date(startMs.getTime() + (params.duration || 60) * 60000);
  const fromStr = startMs.toISOString().slice(0, 19) + '+02:00';
  const toStr   = endMs.toISOString().slice(0, 19) + '+02:00';

  const attendeeStr = params.attendees.join(',');

  // Build gog command
  const gogArgs = [
    'calendar', 'create', 'primary',
    '--account', 'josh@amalfiai.com',
    '--summary', params.title || 'Meeting',
    '--from', fromStr,
    '--to', toStr,
    '--attendees', attendeeStr,
    '--with-meet',
    '--send-updates', 'all',
    '--json', '--results-only', '--no-input',
    '-y',
  ];
  if (params.description) gogArgs.push('--description', params.description);

  const result = spawnSync('gog', gogArgs, {
    encoding: 'utf8', timeout: 20000,
    env: { ...process.env, HOME: '/Users/henryburton', PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
  });

  if (result.status !== 0) {
    log(`[meet] gog error: ${result.stderr}`);
    await client.sendMessage(chatId, `❌ Calendar error: ${(result.stderr || 'unknown error').slice(0, 200)}`);
    return true;
  }

  let event;
  try { event = JSON.parse(result.stdout); } catch { event = {}; }

  const meetLink = event.hangoutLink || event.conferenceData?.entryPoints?.[0]?.uri || null;
  const eventDate = startMs.toLocaleDateString('en-ZA', { timeZone: 'Africa/Johannesburg', weekday: 'long', day: 'numeric', month: 'long' });
  const eventTime = startMs.toLocaleTimeString('en-ZA', { timeZone: 'Africa/Johannesburg', hour: '2-digit', minute: '2-digit', hour12: false });

  let reply = `✅ *${params.title || 'Meeting'} scheduled*\n\n`;
  reply += `📅 ${eventDate} at ${eventTime} SAST\n`;
  reply += `⏱ ${params.duration || 60} minutes\n`;
  reply += `👥 ${params.attendees.join(', ')}\n`;
  if (meetLink) reply += `\n🔗 *Meet link:* ${meetLink}`;
  reply += `\n\nInvites sent to all attendees.`;

  await client.sendMessage(chatId, reply);
  return true;
}

// ── Flight search + booking (WhatsApp) ───────────────────────────────────────
const PENDING_FLIGHT_FILE = path.join(WS, `tmp/pending-flight-wa.json`);
const FLIGHT_KEYWORDS = /\b(flight|fly|flying|flights?|book.?a.?flight|find.?(me.?a?|a).?flight|search.?flight|cheapest.*(flight|fly)|ticket|tickets?|airport|airfare|one.?way|return.?flight|round.?trip)\b/i;

function loadPendingFlight() {
  try { return JSON.parse(fs.readFileSync(PENDING_FLIGHT_FILE, 'utf8')); } catch { return null; }
}

function savePendingFlight(data) {
  try { fs.writeFileSync(PENDING_FLIGHT_FILE, JSON.stringify(data, null, 2)); } catch { /* */ }
}

function clearPendingFlight() {
  try { fs.unlinkSync(PENDING_FLIGHT_FILE); } catch { /* */ }
}

const IATA = {
  'cape town': 'CPT', 'cpt': 'CPT', 'johannesburg': 'JNB', 'joburg': 'JNB', 'jnb': 'JNB',
  'or tambo': 'JNB', 'durban': 'DUR', 'dur': 'DUR', 'king shaka': 'DUR',
  'port elizabeth': 'PLZ', 'gqeberha': 'PLZ', 'plz': 'PLZ',
  'east london': 'ELS', 'els': 'ELS', 'george': 'GRJ', 'grj': 'GRJ',
  'bloemfontein': 'BFN', 'bfn': 'BFN', 'lanseria': 'HLA', 'hla': 'HLA',
};

async function parseFlightQuery(userText) {
  const now = new Date().toLocaleString('en-ZA', { timeZone: 'Africa/Johannesburg' });
  const result = await runGPT(
    'You extract flight search parameters from natural language. Output only JSON.',
    `Parse this flight request. Today is ${now} (SAST).
Message: "${userText}"

Output JSON:
{
  "from": "IATA code (CPT/JNB/DUR/PLZ/ELS/GRJ/BFN/HLA) — default CPT if not specified",
  "to": "IATA code",
  "date": "YYYY-MM-DD",
  "return_date": "YYYY-MM-DD or null",
  "adults": 1,
  "airline": "flysafair|lift|both — default both",
  "time_pref": "morning|midday|afternoon|evening|null",
  "price_pref": "cheapest|specific — default cheapest"
}

Rules:
- "next Thursday" = resolve to actual date
- "Friday" without qualifier = this coming Friday
- "morning" = 06:00-11:00, "midday" = 11:00-14:00, "afternoon" = 14:00-18:00, "evening" = 18:00+
- If destination unclear, return {"error": "need more info"}`, 'gpt-4o-mini');

  if (!result) return null;
  const clean = result.trim().replace(/^```json\n?|```$/g, '').trim();
  return JSON.parse(clean);
}

function formatFlightResults(safairFlights, liftFlights, params) {
  const { from, to, date, return_date, adults, time_pref } = params;
  const dateLabel = new Date(date + 'T12:00:00').toLocaleDateString('en-ZA', { weekday: 'short', day: 'numeric', month: 'short' });
  const paxLabel = adults > 1 ? ` | ${adults} pax` : '';

  const lines = [`✈️ *${from} → ${to} | ${dateLabel}${paxLabel}*`];
  if (return_date) {
    const retLabel = new Date(return_date + 'T12:00:00').toLocaleDateString('en-ZA', { weekday: 'short', day: 'numeric', month: 'short' });
    lines[0] += ` (return ${retLabel})`;
  }
  lines.push('');

  let idx = 1;
  const all = [];

  if (safairFlights?.length) {
    lines.push('*FlySafair:*');
    let shown = safairFlights;
    if (time_pref) {
      const [h1, h2] = { morning: [6,11], midday: [11,14], afternoon: [14,18], evening: [18,24] }[time_pref] || [0,24];
      const filtered = shown.filter(f => { const h = parseInt((f.departure||'00').split(':')[0]); return h >= h1 && h < h2; });
      if (filtered.length) shown = filtered;
    }
    shown.slice(0, 5).forEach(f => {
      const price = f.price || '?';
      const priceNum = f.priceNum || parseInt(price.replace(/\D/g,'')) || 9999;
      lines.push(`${idx}. ${f.flight} ${f.departure}→${f.arrival} — *${price}*`);
      all.push({ idx: idx++, ...f, airline: 'flysafair', priceNum });
    });
    lines.push('');
  }

  if (liftFlights?.length) {
    lines.push('*Lift:*');
    let shown = liftFlights;
    if (time_pref) {
      const [h1, h2] = { morning: [6,11], midday: [11,14], afternoon: [14,18], evening: [18,24] }[time_pref] || [0,24];
      const filtered = shown.filter(f => { const h = parseInt((f.departure||'00').split(':')[0]); return h >= h1 && h < h2; });
      if (filtered.length) shown = filtered;
    }
    shown.slice(0, 5).forEach(f => {
      const price = f.price || '?';
      const priceNum = f.priceNum || parseInt(price.replace(/\D/g,'')) || 9999;
      lines.push(`${idx}. ${f.flight} ${f.departure}→${f.arrival} — *${price}*`);
      all.push({ idx: idx++, ...f, airline: 'lift', priceNum });
    });
    lines.push('');
  }

  if (!all.length) return { text: `No flights found for ${from} → ${to} on ${dateLabel}.`, options: [] };

  const cheapest = all.sort((a, b) => a.priceNum - b.priceNum)[0];
  lines.push(`💰 Cheapest: *${cheapest.price}* (option ${cheapest.idx})`);
  lines.push(`\nReply with a number or flight code to book (e.g. "book 2" or "book ${cheapest.flight}"), or "cancel".`);

  return { text: lines.join('\n'), options: all };
}

async function handleFlightSearch(chatId, ownerNum, userText) {
  if (!clientReady) return;

  // Immediate acknowledgement
  await client.sendMessage(chatId, '✈️ Searching flights, give me a sec...');

  try {
    const params = await parseFlightQuery(userText);
    if (!params || params.error) {
      await client.sendMessage(chatId, `I need a bit more info — where are you flying to and when?`);
      return;
    }

    // Calendar conflict check
    let calendarNote = '';
    try {
      const calResult = spawnSync('/bin/bash', [path.join(WS, 'scripts/sophia-calendar.sh'), 'list', params.date], {
        encoding: 'utf8', timeout: 15000, env: { ...process.env, HOME: '/Users/henryburton', PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
      });
      const calOut = JSON.parse(calResult.stdout || '{}');
      if (calOut.ok && calOut.result && calOut.result.toLowerCase() !== 'no events') {
        calendarNote = `\n📅 *Calendar note:* You have events on ${params.date} — check for conflicts.`;
      }
    } catch { /* calendar check is best-effort */ }

    // Run FlySafair + Lift searches in parallel
    const FLIGHT_SCRIPT = path.join(WS, 'scripts/flights/search-flights.mjs');
    const childEnv = { ...process.env, HOME: '/Users/henryburton', PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' };

    const runSearch = (airline) => {
      const args = ['--from', params.from, '--to', params.to, '--date', params.date, '--airline', airline, '--adults', String(params.adults || 1)];
      if (params.return_date) args.push('--return', params.return_date);
      const r = spawnSync('node', [FLIGHT_SCRIPT, ...args], { env: childEnv, timeout: 60000, encoding: 'utf8' });
      try { return JSON.parse(r.stdout || '{}'); } catch { return { ok: false, flights: [] }; }
    };

    const doLift = ['CPT','JNB','DUR'].includes(params.from) && ['CPT','JNB','DUR'].includes(params.to);
    const [safairRes, liftRes] = await Promise.all([
      new Promise(res => res(runSearch('flysafair'))),
      doLift ? new Promise(res => res(runSearch('lift'))) : Promise.resolve({ ok: false, flights: [] }),
    ]);

    const safairFlights = safairRes.flights || [];
    const liftFlights   = liftRes.flights   || [];

    if (!safairFlights.length && !liftFlights.length) {
      await client.sendMessage(chatId, `No flights found for ${params.from} → ${params.to} on ${params.date}. Try a different date?`);
      return;
    }

    const { text, options } = formatFlightResults(safairFlights, liftFlights, params);
    await client.sendMessage(chatId, text + calendarNote);

    // Save pending flight state
    savePendingFlight({ params, options, searchedAt: new Date().toISOString() });

  } catch (e) {
    log(`Flight search error: ${e.message}`);
    await client.sendMessage(chatId, `Flight search hit an error: ${e.message.slice(0, 100)}. Try again?`);
  }
}

async function handleFlightBooking(chatId, ownerNum, userText, pending) {
  const lower = userText.toLowerCase().trim();

  // Cancel
  if (/^cancel|^no thanks|^forget it|^never mind/i.test(lower)) {
    clearPendingFlight();
    await client.sendMessage(chatId, 'Booking cancelled. Let me know if you want to search again.');
    return true;
  }

  // Match by number "book 2", "1", "option 3"
  let chosen = null;
  const numMatch = lower.match(/\b(\d+)\b/);
  if (numMatch) {
    const idx = parseInt(numMatch[1]);
    chosen = pending.options.find(o => o.idx === idx);
  }

  // Match by flight code "book FA603", "the GE124"
  if (!chosen) {
    const codeMatch = lower.match(/\b([A-Z]{2}\d{2,4}|GE\d{3,4}|FA\d{3,4})\b/i);
    if (codeMatch) {
      const code = codeMatch[1].toUpperCase();
      chosen = pending.options.find(o => (o.flight || '').toUpperCase() === code);
    }
  }

  // "cheapest" or "yes" = pick cheapest
  if (!chosen && /\b(cheapest|yes|book it|go ahead|confirm|do it)\b/i.test(lower)) {
    chosen = [...pending.options].sort((a, b) => a.priceNum - b.priceNum)[0];
  }

  if (!chosen) return false; // not a booking reply — let normal response handle it

  clearPendingFlight();
  await client.sendMessage(chatId, `📋 Booking *${chosen.flight}* (${chosen.departure}→${chosen.arrival}, ${chosen.price}) on ${chosen.airline === 'flysafair' ? 'FlySafair' : 'Lift'}. Give me a minute...`);

  // Run book-flight.mjs
  const BOOK_SCRIPT = path.join(WS, 'scripts/flights/book-flight.mjs');
  const { params } = pending;
  const bookArgs = [
    '--airline', chosen.airline,
    '--from', params.from, '--to', params.to,
    '--date', params.date,
    '--flight', chosen.flight,
    '--price', chosen.price,
    '--adults', String(params.adults || 1),
  ];
  if (params.return_date) bookArgs.push('--return', params.return_date);

  const childEnv = { ...process.env, HOME: '/Users/henryburton', PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' };
  const result = spawnSync('node', [BOOK_SCRIPT, ...bookArgs], { env: childEnv, timeout: 120000, encoding: 'utf8' });

  try {
    const out = JSON.parse(result.stdout || '{}');
    if (out.ok) {
      await client.sendMessage(chatId, `✅ *Booked!* ${out.confirmation || ''}\n${chosen.flight} ${chosen.departure}→${chosen.arrival} | ${chosen.price}`);
    } else {
      await client.sendMessage(chatId, `❌ Booking failed: ${out.error || 'unknown error'}. Try booking manually on the airline site.`);
    }
  } catch {
    await client.sendMessage(chatId, `❌ Booking script error. Try booking manually.`);
  }

  return true;
}
// ── End flight system ─────────────────────────────────────────────────────────

// ── Group/DM action extraction ────────────────────────────────────────────────
// Runs on every message (group + DM) to pull out tasks, reminders, and assignments.
// Fully async — never blocks the main response pipeline.
// Smart keyword pre-filter keeps GPT-4o-mini costs negligible.

const ACTION_EXTRACT_RE = /\b(please|can you|could you|need to|must|should|have to|going to|will you|by (monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|next week|end of (day|week|month)|eod)|deadline|asap|urgent|remind|don.t forget|follow.?up|check.?in|ping|fix|build|send|update|review|approve|sort out|look into|schedule|book|call|meet|invoice|pay|submit|upload|deploy|launch|finish|complete|deliver|prepare|write|create|add|remove|change|check)\b/i;

const GROUP_CLIENT_MAP = {
  'race technik':        { id: 'ed045bcb-100f-4fc4-8623-2befcf2c8c14', slug: 'race-technik' },
  'vanta':               { id: 'd2a6eb7c-014c-43e6-9a5e-e0d5876c21cc', slug: 'vanta-studios' },
  'ambassadex':          { id: null,                                     slug: 'ambassadex' },
  'project ozayr':       { id: null,                                     slug: 'ambassadex' },
  'favorite':            { id: 'fb9724b4-1d11-43c4-a76c-e82f7b820c11', slug: 'favorite-logistics' },
  'favlog':              { id: 'fb9724b4-1d11-43c4-a76c-e82f7b820c11', slug: 'favorite-logistics' },
  'ascend':              { id: 'c465aa44-519b-4b35-b4de-2b5c3b89359e', slug: 'ascend-lc' },
};

function resolveGroupClient(groupName) {
  const lower = (groupName || '').toLowerCase();
  for (const [key, val] of Object.entries(GROUP_CLIENT_MAP)) {
    if (lower.includes(key)) return val;
  }
  return null;
}

const TEAM_MEMBERS = ['josh', 'salah', 'masara'];

function inferAssignee(text, senderName) {
  const lower = text.toLowerCase();
  // Explicit mentions
  if (/\bjosh\b/i.test(lower)) return 'josh';
  if (/\bsalah\b/i.test(lower)) return 'salah';
  if (/\bsophia\b|\bamalfi\b|\bcan you\b|\bplease\b|\bwill you\b/i.test(lower)) return 'sophia';
  // Team member saying "I need to..." → assigned to them
  const senderLower = (senderName || '').toLowerCase();
  if (/\bi (need|must|will|am going|have to)\b/i.test(lower)) {
    if (TEAM_MEMBERS.includes(senderLower)) return senderLower;
  }
  return 'team';
}

function extractGroupActions(fromNum, senderName, groupName, userText, isTeamSender) {
  // Cheap pre-filter — skip if no actionable language
  if (!ACTION_EXTRACT_RE.test(userText)) return;
  // Skip very short messages
  if (userText.trim().length < 15) return;

  (async () => {
    try {
      const now = new Date().toLocaleString('en-ZA', { timeZone: 'Africa/Johannesburg' });
      const clientInfo = resolveGroupClient(groupName);

      const prompt = `You are extracting tasks and reminders from a WhatsApp message in ${groupName ? `the "${groupName}" group` : 'a DM'}.

Sender: ${senderName}${isTeamSender ? ' (Amalfi AI team)' : ' (client/contact)'}
Message: "${userText}"
Current SAST time: ${now}

Extract any tasks or reminders. Output JSON only:

{
  "task": {
    "found": true/false,
    "title": "concise action item title",
    "assignee": "josh|salah|sophia|team|<name>",
    "priority": "normal|high|urgent",
    "dueDate": "YYYY-MM-DD or null",
    "notes": "brief context or null"
  },
  "reminder": {
    "found": true/false,
    "message": "reminder text as Sophia would send it",
    "to": "${fromNum}",
    "fireAt": "ISO8601 UTC or null"
  }
}

Rules:
- Task: a clear action item someone needs to do ("fix the login bug", "send invoice to client", "deploy by Friday")
- Reminder: time-based ("remind me at 3pm", "ping me before the meeting", "don't let me forget Thursday")
- assignee: who should do the task — infer from message ("can you build X" → sophia/team, "I need to call X" → sender, "Josh can you..." → josh)
- priority: urgent if ASAP/urgent/today, high if deadline this week, normal otherwise
- If nothing actionable, return {"task":{"found":false},"reminder":{"found":false}}`;

      const result = await runGPT(
        'Extract structured tasks and reminders from messages. Output only valid JSON.',
        prompt, 'gpt-4o-mini'
      );
      if (!result) return;

      const clean = result.trim().replace(/^```json\n?|```$/g, '').trim();
      const parsed = JSON.parse(clean);

      // ── Save task to Supabase ──────────────────────────────────────────────
      if (parsed.task?.found && parsed.task.title) {
        const assignee = parsed.task.assignee || inferAssignee(userText, senderName);
        const taskBody = JSON.stringify({
          title: parsed.task.title,
          status: 'todo',
          priority: parsed.task.priority || 'normal',
          ...(parsed.task.dueDate ? { due_date: parsed.task.dueDate } : {}),
          ...(clientInfo?.id ? { client_id: clientInfo.id } : {}),
          source: `sophia-wa-${isTeamSender ? 'team' : 'client'}`,
          notes: [
            parsed.task.notes,
            `From: ${senderName} in ${groupName || 'DM'}`,
          ].filter(Boolean).join(' | '),
          assigned_to: assignee,
        });

        if (SUPABASE_KEY) {
          const url = new URL(`${SUPABASE_URL}/rest/v1/tasks`);
          const req = https.request({
            hostname: url.hostname, path: url.pathname, method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'apikey': SUPABASE_KEY,
              'Authorization': `Bearer ${SUPABASE_KEY}`,
              'Prefer': 'return=minimal',
            },
          }, (res) => { res.resume(); });
          req.on('error', () => {});
          req.write(taskBody);
          req.end();
        }

        // Proactive WA alert to Josh
        const waMsg = `📋 *Task captured*\n*${parsed.task.title}*\nAssignee: ${assignee} | Priority: ${parsed.task.priority || 'normal'}${parsed.task.dueDate ? ` | Due: ${parsed.task.dueDate}` : ''}\nFrom: ${senderName}${groupName ? ` in ${groupName}` : ''}`;
        const pq = loadProactiveQueue();
        pq.push({ to: OWNER_NUMBER, message: waMsg, sendAt: null });
        saveProactiveQueue(pq);

        log(`Group task extracted: "${parsed.task.title}" → ${assignee} [${parsed.task.priority || 'normal'}]`);
      }

      // ── Save reminder ──────────────────────────────────────────────────────
      if (parsed.reminder?.found && parsed.reminder.fireAt && parsed.reminder.message) {
        const reminderTo = parsed.reminder.to || fromNum;
        const reminders = loadReminders();
        reminders.push({
          id: Date.now().toString(),
          to: reminderTo,
          name: senderName,
          message: parsed.reminder.message,
          fireAt: parsed.reminder.fireAt,
          fired: false,
          createdAt: new Date().toISOString(),
        });
        saveReminders(reminders);
        log(`Group reminder saved: "${parsed.reminder.message}" → ${reminderTo} at ${parsed.reminder.fireAt}`);
      }
    } catch (e) {
      log(`Group action extraction error: ${e.message}`);
    }
  })();
}

// ── End group/DM action extraction ───────────────────────────────────────────

// ── Owner action execution ────────────────────────────────────────────────────
// Called only for Josh (isOwner). Detects executable instructions in his message
// and actually runs them BEFORE generating Sophia's response so she confirms in past tense.
async function runCalendarScript(...args) {
  const CALENDAR_SCRIPT = path.join(WS, 'scripts/sophia-calendar.sh');
  const childEnv = { ...process.env, HOME: '/Users/henryburton', PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' };
  const result = spawnSync('/bin/bash', [CALENDAR_SCRIPT, ...args], {
    env: childEnv, timeout: 30_000, encoding: 'utf8',
  });
  const out = (result.stdout || '').trim();
  if (!out) return { ok: false, error: 'No output from calendar script' };
  try { return JSON.parse(out); } catch { return { ok: false, error: out }; }
}

async function extractAndExecuteOwnerActions(userText, contacts) {
  const actionKeywords = /\b(send|email|message|text|whatsapp|dm|reach\s+out|create\s+task|add\s+task|make\s+a\s+task|introduce|nudge|follow.?up|schedule|calendar|meeting|call|book|event|meet|cancel|reschedule|move|postpone|what.?s on|my calendar|today.?s agenda|check my)\b/i;
  if (!actionKeywords.test(userText)) return null;

  const today = new Date().toLocaleDateString('en-ZA', { timeZone: 'Africa/Johannesburg' });
  const contactsList = Object.entries(contacts)
    .map(([num, v]) => `${v.name} (${num})`)
    .join(', ');

  const extractPrompt = `Josh sent this instruction to Sophia (his AI WhatsApp agent): "${userText}"

Today's date: ${today} (SAST)
Known contacts: ${contactsList}

Extract any executable actions. Output a JSON array only, or [] if none.

Supported action types:
- { "type": "send_whatsapp", "to": "+27XXXXXXXXX", "name": "PersonName", "briefing": "detailed description of what the message should say, the tone, and all context needed to write it" }
- { "type": "send_email", "to": "email@address.com", "name": "PersonName", "subject": "email subject", "briefing": "detailed description of what the email should say and all context needed", "is_client": true/false }
- { "type": "create_task", "title": "...", "description": "...", "priority": "normal|high|urgent", "due_date": "YYYY-MM-DD or null" }
- { "type": "list_calendar", "date": "today|tomorrow|monday|YYYY-MM-DD" }
- { "type": "create_event", "title": "...", "date": "today|tomorrow|monday|YYYY-MM-DD", "start_time": "HH:MM", "end_time": "HH:MM or null", "with_meet": true/false, "attendees": "email1,email2 or null", "description": "optional" }
- { "type": "delete_event", "search": "keyword to find event", "date": "YYYY-MM-DD or null" }
- { "type": "update_event", "search": "keyword", "date": "YYYY-MM-DD or null", "new_start": "HH:MM or null", "new_end": "HH:MM or null", "new_date": "tomorrow|monday|YYYY-MM-DD or null", "new_title": "null or string" }

Rules:
- Only extract actions with a clear, concrete recipient or outcome
- For send_whatsapp: use the exact phone number from the contacts list
- For send_email: is_client = true if the recipient is a client or external person (not Amalfi AI team)
- "schedule a meeting", "create a calendar event", "block time" = create_event
- "what is on my calendar", "what do I have today" = list_calendar
- "cancel my X meeting", "delete the X event" = delete_event
- "move my X to Y", "reschedule X" = update_event
- "Google Meet", "video call", "Meet link" = create_event with with_meet: true
- If no clear executable actions, return []
- Output JSON only, no markdown`;

  const result = await runGPT(
    'You are an action extraction assistant. Output JSON only.',
    extractPrompt,
    'gpt-4o-mini'
  );
  if (!result) return null;

  let actions;
  try {
    const clean = result.trim().replace(/^```json\n?|```$/g, '').trim();
    actions = JSON.parse(clean);
    if (!Array.isArray(actions) || actions.length === 0) return null;
  } catch (e) {
    log(`Action extraction parse error: ${e.message}`);
    return null;
  }

  const results = [];

  for (const action of actions) {
    if (action.type === 'send_whatsapp' && action.to && action.briefing) {
      try {
        const safeN = (action.name || 'user').toLowerCase().replace(/[^a-z0-9]/g, '-');
        let recipientNotes = '';
        try { recipientNotes = fs.readFileSync(path.join(WS, `memory/${safeN}-notes.md`), 'utf8'); } catch { /* */ }

        const paPrompt = fs.readFileSync(PERSONAL_ASSISTANT_PROMPT_FILE, 'utf8');
        const msgPrompt = `${paPrompt}

You are sending a WhatsApp message to ${action.name || 'this person'} (${action.to}) on behalf of Amalfi AI.
${recipientNotes ? `What you know about them:\n${recipientNotes}\n` : ''}
Instruction: ${action.briefing}

Write the WhatsApp message. Natural, warm. No hyphens. No bullet-point walls.`;

        const msgContent = runClaude(msgPrompt, 'claude-sonnet-4-6');
        if (!msgContent) {
          results.push(`FAILED to generate message for ${action.name || action.to}`);
          continue;
        }

        const sendPayload = JSON.stringify({ to: action.to, message: msgContent });
        await new Promise((resolve) => {
          const req = http.request({
            hostname: '127.0.0.1', port: 3001, path: '/send', method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(sendPayload) },
          }, (res) => { res.resume(); resolve(); });
          req.on('error', (e) => { log(`WA send action error: ${e.message}`); resolve(); });
          req.write(sendPayload);
          req.end();
        });

        results.push(`Sent WhatsApp to ${action.name || action.to}: "${msgContent.slice(0, 100)}${msgContent.length > 100 ? '...' : ''}"`);
        log(`Owner action: sent WA to ${action.to}`);
      } catch (e) {
        results.push(`Error sending to ${action.to}: ${e.message}`);
        log(`Owner action error (send_whatsapp): ${e.message}`);
      }

    } else if (action.type === 'send_email' && action.to && action.briefing) {
      try {
        // Client emails go from josh@amalfiai.com — they should come from the founder, not Sophia.
        // Internal/non-client emails go from sophia@amalfiai.com.
        const fromAccount = action.is_client ? 'josh@amalfiai.com' : 'sophia@amalfiai.com';

        const emailPrompt = `You are drafting a professional email on behalf of ${action.is_client ? 'Josh Burton (josh@amalfiai.com), founder of Amalfi AI' : 'Sophia, Amalfi AI client success manager'}.
Recipient: ${action.name || action.to} <${action.to}>
Subject: ${action.subject || '(no subject given)'}
Instruction: ${action.briefing}

Write the email body only (no Subject line). Professional, warm, no hyphens. No markdown. Sign off appropriately.`;

        const emailBody = await runGPT(
          `You are an email writing assistant for ${action.is_client ? 'Josh Burton, founder of Amalfi AI' : 'Sophia at Amalfi AI'}. Write professional emails. No hyphens.`,
          emailPrompt,
          'gpt-4o'
        );
        if (!emailBody) {
          results.push(`FAILED to generate email for ${action.name || action.to}`);
        } else {
          const gogArgs = [
            'gmail', 'send',
            '--account', fromAccount,
            '--to', action.to,
            '--subject', action.subject || '(no subject)',
            '--body-html', emailBody.replace(/\n/g, '<br>'),
            '--no-input', '-y',
          ];
          const r = spawnSync('gog', gogArgs, {
            encoding: 'utf8', timeout: 20000,
            env: { ...process.env, HOME: '/Users/henryburton', PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' },
          });
          if (r.status !== 0) {
            results.push(`Email send failed: ${(r.stderr || '').slice(0, 150)}`);
            log(`Owner action email error: ${r.stderr}`);
          } else {
            results.push(`Email sent to ${action.name || action.to} from ${fromAccount}: "${action.subject || '(no subject)'}"`);
            log(`Owner action: sent email to ${action.to} from ${fromAccount}`);
          }
        }
      } catch (e) {
        results.push(`Error sending email to ${action.to}: ${e.message}`);
        log(`Owner action error (send_email): ${e.message}`);
      }

    } else if (action.type === 'create_task' && action.title) {
      try {
        const taskBody = JSON.stringify({
          title: action.title,
          description: action.description || '',
          priority: action.priority || 'normal',
          status: 'todo',
          ...(action.due_date ? { due_date: action.due_date } : {}),
        });
        await new Promise((resolve) => {
          const url = new URL(`${SUPABASE_URL}/rest/v1/tasks`);
          const req = https.request({
            hostname: url.hostname, path: url.pathname, method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'apikey': SUPABASE_KEY,
              'Authorization': `Bearer ${SUPABASE_KEY}`,
              'Prefer': 'return=minimal',
            },
          }, (res) => { res.resume(); resolve(); });
          req.on('error', (e) => { log(`Task create action error: ${e.message}`); resolve(); });
          req.write(taskBody);
          req.end();
        });
        results.push(`Task created: "${action.title}"`);
        log(`Owner action: created task "${action.title}"`);
      } catch (e) {
        results.push(`Error creating task: ${e.message}`);
        log(`Owner action error (create_task): ${e.message}`);
      }

    } else if (action.type === 'list_calendar') {
      const date = action.date || 'today';
      const r = await runCalendarScript('list', date);
      results.push(r.result || r.error || 'Calendar lookup failed');
      log(`Owner action: list_calendar ${date}`);

    } else if (action.type === 'create_event' && action.title) {
      const args = ['create',
        '--title', action.title,
        '--date',  action.date || 'today',
        '--start', action.start_time || '09:00',
      ];
      if (action.end_time)   args.push('--end', action.end_time);
      if (action.with_meet)  args.push('--meet');
      if (action.attendees)  args.push('--attendees', action.attendees);
      if (action.description) args.push('--desc', action.description);
      const r = await runCalendarScript(...args);
      results.push(r.result || r.error || 'Event creation failed');
      log(`Owner action: create_event "${action.title}"`);

    } else if (action.type === 'delete_event' && action.search) {
      const args = ['delete', '--search', action.search];
      if (action.date) args.push('--date', action.date);
      const r = await runCalendarScript(...args);
      results.push(r.result || r.error || 'Delete failed');
      log(`Owner action: delete_event "${action.search}"`);

    } else if (action.type === 'update_event' && action.search) {
      const args = ['update', '--search', action.search];
      if (action.date)      args.push('--date', action.date);
      if (action.new_start) args.push('--new-start', action.new_start);
      if (action.new_end)   args.push('--new-end', action.new_end);
      if (action.new_date)  args.push('--new-date', action.new_date);
      if (action.new_title) args.push('--new-title', action.new_title);
      const r = await runCalendarScript(...args);
      results.push(r.result || r.error || 'Update failed');
      log(`Owner action: update_event "${action.search}"`);
    }
  }

  return results.length > 0 ? results.join('\n') : null;
}
// ── End owner action execution ─────────────────────────────────────────────────

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

  // ── Owner DM: check pending flight state first ────────────────────────────────
  if (isOwner && !isGroup) {
    const pendingFlight = loadPendingFlight();
    if (pendingFlight) {
      const handled = await handleFlightBooking(msg.from, fromNum, userText, pendingFlight);
      if (handled) return;
    }
    // Meeting scheduling request
    if (MEET_KEYWORDS.test(userText)) {
      await handleMeetingSchedule(msg.from, userText);
      return;
    }
    // New flight search request
    if (FLIGHT_KEYWORDS.test(userText)) {
      await handleFlightSearch(msg.from, fromNum, userText);
      return;
    }
  }

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

  // ── Proactive action extraction — runs on ALL messages before pre-filter ──────
  // Extracts tasks/reminders from every message (group or DM), never blocks response.
  {
    const _exEntry  = contacts[fromNum] || contacts[`+${fromNum.replace(/^\+/, '')}`] || null;
    const _exRole   = _exEntry?.role || '';
    const _isTeamSender = isOwner || _exRole.includes('Amalfi AI');
    const _exName   = _exEntry?.name || resolveName(fromNum);
    extractGroupActions(fromNum, _exName, detectedGroupName, userText, _isTeamSender);
  }

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

  // For Josh (isOwner) — detect and execute action instructions before generating response
  // so Sophia can confirm what was ACTUALLY done (past tense), not promise what she "will" do
  let executionSummary = '';
  if (isOwner) {
    const execResult = await extractAndExecuteOwnerActions(userText, contacts);
    if (execResult) {
      executionSummary = `\n\n=== ACTIONS I JUST EXECUTED ===\n${execResult}\nIMPORTANT: Confirm to Josh what you ALREADY DID (past tense). Do NOT say you "will" do anything that is already done.`;
    }
  }

  // GPT-4o: system = Sophia's identity rules, user = all context + message
  const userContent = historyText
    ? `Today: ${today}${channelLine}${memBlock}\n=== RECENT CONVERSATION ===\n${historyText}\n\n${speaker}: ${messageWithContext}${executionSummary}`
    : `Today: ${today}${channelLine}${memBlock}\n${speaker}: ${messageWithContext}${executionSummary}`;

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
    log('GPT-4o failed — trying Claude fallback...');
    try {
      response = runClaude(lockedSystemPrompt + '\n\n' + userContent);
    } catch (e) {
      log(`Claude fallback threw: ${e.message}`);
      response = null;
    }
    if (!response) {
      log('Both GPT-4o and Claude failed — sending holding message');
      notifyTelegram('⚠️ Sophia WhatsApp: GPT-4o failed, Claude fallback also failed for message from ' + senderName);
      try { await msg.reply('Hey, I\'m having a moment. Let me get back to you shortly.'); } catch (_) {}
      return;
    }
    log('Claude fallback succeeded');
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

  // Free-text analysis — extract reminders + tasks from all owner messages
  if (isOwner) extractAndSaveReminder(fromNum, senderName, userText, response);

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

// Generate voice note via OpenAI TTS (gpt-4o-mini-tts, nova) — returns opus Buffer or null
function generateTTS(text) {
  const key = env.OPENAI_API_KEY || '';
  if (!key) return Promise.resolve(null);
  const payload = Buffer.from(JSON.stringify({
    model: 'gpt-4o-mini-tts',
    input: text,
    voice: 'nova',
    response_format: 'opus',
  }));
  return new Promise((resolve) => {
    const req = https.request({
      hostname: 'api.openai.com',
      path: '/v1/audio/speech',
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${key}`,
        'Content-Type': 'application/json',
        'Content-Length': payload.length,
      },
    }, (res) => {
      if (res.statusCode !== 200) {
        log(`TTS API error: HTTP ${res.statusCode}`);
        res.resume();
        return resolve(null);
      }
      const chunks = [];
      res.on('data', d => chunks.push(d));
      res.on('end', () => resolve(Buffer.concat(chunks)));
    });
    req.on('error', (e) => { log(`TTS request error: ${e.message}`); resolve(null); });
    req.write(payload);
    req.end();
  });
}

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
    executablePath: process.env.PUPPETEER_EXECUTABLE_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
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
  // Proactive: check reminders + queued outbound messages every 60s
  setInterval(() => checkAndFireProactive(), 60 * 1000);
  setTimeout(() => checkAndFireProactive(), 15 * 1000); // first check after 15s settle
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

  // POST /send-voice — generate TTS from text and send as WhatsApp voice note (PTT)
  if (req.method === 'POST' && req.url === '/send-voice') {
    let body = '';
    req.on('data', d => { body += d; });
    req.on('end', async () => {
      try {
        const { to, text } = JSON.parse(body);
        if (!to || !text) { res.writeHead(400); return res.end(JSON.stringify({ error: 'to and text required' })); }
        if (!clientReady) { res.writeHead(503); return res.end(JSON.stringify({ error: 'WhatsApp client not ready' })); }

        const audioBuffer = await generateTTS(text);
        if (!audioBuffer) { res.writeHead(500); return res.end(JSON.stringify({ error: 'TTS generation failed' })); }

        const cleanTo = to.replace(/\s/g, '').replace(/^\+/, '');
        const chatId = /^\d+$/.test(cleanTo) ? `${cleanTo}@c.us` : null;
        if (!chatId) { res.writeHead(400); return res.end(JSON.stringify({ error: 'invalid number' })); }

        const media = new MessageMedia('audio/ogg; codecs=opus', audioBuffer.toString('base64'), 'voice.ogg');
        await client.sendMessage(chatId, media, { sendAudioAsVoice: true });
        log(`Voice note sent → ${to}: "${text.slice(0, 60)}"`);
        res.writeHead(200);
        res.end(JSON.stringify({ ok: true, to, chatId, chars: text.length }));
      } catch (e) {
        log(`/send-voice error: ${e.message}`);
        res.writeHead(500);
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
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
}).on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    log(`Port ${API_PORT} already in use — another instance may be running. Exiting.`);
    notifyTelegram(`⚠️ Sophia WhatsApp gateway failed to start: port ${API_PORT} in use`);
    process.exit(1);
  }
  throw err;
});

// ── Graceful shutdown ─────────────────────────────────────────────────────────
async function shutdown(signal) {
  log(`${signal} received — shutting down gracefully...`);
  try { await client.destroy(); } catch (_) {}
  try { apiServer.close(); } catch (_) {}
  process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

// ── WhatsApp client ───────────────────────────────────────────────────────────
log('Starting WhatsApp client...');
client.initialize();
