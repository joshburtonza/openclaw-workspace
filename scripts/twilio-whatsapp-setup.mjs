#!/usr/bin/env node
/**
 * twilio-whatsapp-setup.mjs
 *
 * Registers a phone number as a Twilio WhatsApp sender via the Senders API
 * and configures the webhook URL to point to our Supabase edge function.
 *
 * Usage:
 *   node scripts/twilio-whatsapp-setup.mjs register   — create sender, get SID
 *   node scripts/twilio-whatsapp-setup.mjs verify      — submit OTP verification code
 *   node scripts/twilio-whatsapp-setup.mjs status      — check sender status
 *   node scripts/twilio-whatsapp-setup.mjs list        — list all WhatsApp senders
 *
 * Required in .env.scheduler:
 *   TWILIO_ACCOUNT_SID
 *   TWILIO_AUTH_TOKEN
 *   TWILIO_WA_FROM     — phone number to register, E.164 (e.g. +27821234567)
 *
 * After first 'register' run, also set:
 *   TWILIO_WA_SENDER_SID — the XE... SID returned by registration
 */

import { readFileSync } from 'fs';
import { createInterface } from 'readline';

// ── Load .env.scheduler ───────────────────────────────────────────────────────
const ENV_FILE = '/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler';
const env = {};
try {
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (m && !m[2].startsWith('REPLACE')) env[m[1]] = m[2];
  }
} catch { /* ignore */ }

const ACCOUNT_SID  = env.TWILIO_ACCOUNT_SID  || process.env.TWILIO_ACCOUNT_SID;
const AUTH_TOKEN   = env.TWILIO_AUTH_TOKEN   || process.env.TWILIO_AUTH_TOKEN;
const WA_FROM      = env.TWILIO_WA_FROM      || process.env.TWILIO_WA_FROM;
const SENDER_SID   = env.TWILIO_WA_SENDER_SID || process.env.TWILIO_WA_SENDER_SID;

const WEBHOOK_URL  = 'https://afmpbtynucpbglwtbfuz.supabase.co/functions/v1/whatsapp-webhook';
const SENDERS_BASE = 'https://messaging.twilio.com/v2/Channels/Senders';

if (!ACCOUNT_SID || !AUTH_TOKEN) {
  console.error('ERROR: TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN must be set in .env.scheduler');
  process.exit(1);
}

const AUTH_HEADER = 'Basic ' + Buffer.from(`${ACCOUNT_SID}:${AUTH_TOKEN}`).toString('base64');

// ── Helpers ───────────────────────────────────────────────────────────────────

async function twilioRequest(method, url, body = null) {
  const opts = {
    method,
    headers: {
      'Authorization': AUTH_HEADER,
      'Content-Type':  'application/json',
      'Accept':        'application/json',
    },
  };
  if (body) opts.body = JSON.stringify(body);
  const resp = await fetch(url, opts);
  const text = await resp.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { raw: text }; }
  if (!resp.ok) {
    console.error(`HTTP ${resp.status}:`, JSON.stringify(json, null, 2));
    process.exit(1);
  }
  return json;
}

function prompt(question) {
  return new Promise(resolve => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.question(question, answer => { rl.close(); resolve(answer.trim()); });
  });
}

function printSender(s) {
  console.log('\n' + '─'.repeat(60));
  console.log(`SID:     ${s.sid}`);
  console.log(`Status:  ${s.status}`);
  console.log(`Number:  ${s.sender_id ?? s.senderId}`);
  if (s.configuration?.waba_id) console.log(`WABA ID: ${s.configuration.waba_id}`);
  if (s.properties?.quality_rating) console.log(`Quality: ${s.properties.quality_rating}`);
  if (s.properties?.messaging_limit) console.log(`Limit:   ${s.properties.messaging_limit}`);
  if (s.webhook?.callback_url) console.log(`Webhook: ${s.webhook.callback_url}`);
  if (s.offline_reasons?.length) console.log(`Offline: ${JSON.stringify(s.offline_reasons)}`);
  console.log('─'.repeat(60));
}

// ── Commands ──────────────────────────────────────────────────────────────────

async function register() {
  if (!WA_FROM) {
    console.error('ERROR: TWILIO_WA_FROM not set in .env.scheduler (e.g. +27821234567)');
    process.exit(1);
  }
  const senderId = WA_FROM.startsWith('whatsapp:') ? WA_FROM : `whatsapp:${WA_FROM}`;
  console.log(`\nRegistering ${senderId} as WhatsApp sender...`);
  console.log(`Webhook URL: ${WEBHOOK_URL}\n`);

  const body = {
    sender_id: senderId,
    webhook: {
      callback_url:    WEBHOOK_URL,
      callback_method: 'POST',
    },
  };

  const result = await twilioRequest('POST', SENDERS_BASE, body);
  printSender(result);

  console.log('\nNext steps:');
  console.log(`1. Add this to .env.scheduler:  TWILIO_WA_SENDER_SID=${result.sid}`);
  console.log('2. Wait for a verification SMS on the registered number');
  console.log('3. Run:  node scripts/twilio-whatsapp-setup.mjs verify');
  console.log('\nStatus will move:  CREATING → PENDING_VERIFICATION → VERIFYING → ONLINE');
}

async function verify() {
  if (!SENDER_SID) {
    console.error('ERROR: TWILIO_WA_SENDER_SID not set — run "register" first and add the SID to .env.scheduler');
    process.exit(1);
  }

  // Check current status first
  const current = await twilioRequest('GET', `${SENDERS_BASE}/${SENDER_SID}`);
  printSender(current);

  if (current.status === 'ONLINE') {
    console.log('\n✅ Sender is already ONLINE — no verification needed.');
    return;
  }

  if (!['PENDING_VERIFICATION', 'VERIFYING'].includes(current.status)) {
    console.log(`\nSender status is "${current.status}" — not ready for verification.`);
    console.log('Wait for status to reach PENDING_VERIFICATION, then try again.');
    return;
  }

  const code = await prompt('\nEnter the verification code received via SMS: ');
  if (!code) { console.error('No code entered.'); process.exit(1); }

  const body = {
    configuration: {
      waba_id:             current.configuration?.waba_id ?? '',
      verification_method: current.configuration?.verification_method ?? 'sms',
      verification_code:   code,
    },
  };

  console.log('\nSubmitting verification code...');
  const result = await twilioRequest('POST', `${SENDERS_BASE}/${SENDER_SID}`, body);
  printSender(result);

  if (result.status === 'ONLINE') {
    console.log('\n✅ WhatsApp sender is ONLINE and ready.');
    console.log(`Set TWILIO_WA_FROM=${WA_FROM} in .env.scheduler and the gateway will start working.`);
  } else {
    console.log(`\nStatus: ${result.status} — Twilio may still be processing. Run 'status' to check.`);
  }
}

async function status() {
  if (!SENDER_SID) {
    console.error('ERROR: TWILIO_WA_SENDER_SID not set in .env.scheduler');
    process.exit(1);
  }
  const result = await twilioRequest('GET', `${SENDERS_BASE}/${SENDER_SID}`);
  printSender(result);
}

async function list() {
  const result = await twilioRequest('GET', `${SENDERS_BASE}?channel=whatsapp&pageSize=20`);
  const senders = result.senders ?? [];
  if (!senders.length) {
    console.log('\nNo WhatsApp senders registered yet.');
    return;
  }
  console.log(`\n${senders.length} sender(s):`);
  for (const s of senders) printSender(s);
}

// ── Main ──────────────────────────────────────────────────────────────────────

const cmd = process.argv[2] ?? 'status';

switch (cmd) {
  case 'register': await register(); break;
  case 'verify':   await verify();   break;
  case 'status':   await status();   break;
  case 'list':     await list();     break;
  default:
    console.log('Usage: node scripts/twilio-whatsapp-setup.mjs [register|verify|status|list]');
    process.exit(1);
}
