#!/usr/bin/env node
/**
 * finance-poller.mjs
 * Pulls FNB transactions for business + personal accounts, categorises them,
 * upserts into Supabase, and fires Telegram alerts for client payments,
 * unknown charges, and low balance warnings.
 *
 * Runs twice daily at 07:00 + 18:00 SAST via LaunchAgent.
 * Uses: fnb-api (Puppeteer-based FNB scraper), @supabase/supabase-js
 */

import { createRequire } from 'module';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { execSync } from 'child_process';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { createClient } from '@supabase/supabase-js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKSPACE = join(__dirname, '..');
const ENV_FILE  = join(WORKSPACE, '.env.scheduler');
const LAST_SYNC = join(WORKSPACE, 'tmp', 'finance-last-sync.txt');
const LOG_TAG   = '[finance-poller]';

// ── Load .env.scheduler ───────────────────────────────────────────────────────
function loadEnv(path) {
  if (!existsSync(path)) { console.error(`${LOG_TAG} env file not found: ${path}`); process.exit(1); }
  const lines = readFileSync(path, 'utf8').split('\n');
  for (const line of lines) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}
loadEnv(ENV_FILE);

const SUPABASE_URL  = process.env.AOS_SUPABASE_URL  || 'https://afmpbtynucpbglwtbfuz.supabase.co';
const SUPABASE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const BOT_TOKEN     = process.env.TELEGRAM_BOT_TOKEN;
const JOSH_CHAT_ID  = process.env.TELEGRAM_JOSH_CHAT_ID  || '1140320036';
const SALAH_CHAT_ID = process.env.TELEGRAM_SALAH_CHAT_ID || '8597169435';
const BIZ_USERNAME  = process.env.FNB_BUSINESS_USERNAME;
const BIZ_PASSWORD  = process.env.FNB_BUSINESS_PASSWORD;
const PERS_USERNAME = process.env.FNB_PERSONAL_USERNAME;
const PERS_PASSWORD = process.env.FNB_PERSONAL_PASSWORD;
const BIZ_ACCOUNT   = process.env.FNB_BUSINESS_ACCOUNT  || '63185026672';
const LOW_BAL_THRESHOLD = parseInt(process.env.FNB_LOW_BALANCE_THRESHOLD || '5000', 10);

if (!SUPABASE_KEY || !BOT_TOKEN) {
  console.error(`${LOG_TAG} Missing SUPABASE_SERVICE_ROLE_KEY or TELEGRAM_BOT_TOKEN`);
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// ── Ensure fnb-api is installed ───────────────────────────────────────────────
const FNB_API_PATH = join(WORKSPACE, 'node_modules', 'fnb-api');
if (!existsSync(FNB_API_PATH)) {
  console.log(`${LOG_TAG} Installing fnb-api...`);
  execSync('npm install fnb-api --save', { cwd: WORKSPACE, stdio: 'inherit' });
}
const require = createRequire(import.meta.url);
const { Api: FnbApi } = require('fnb-api');

// ── Categorisation rules ──────────────────────────────────────────────────────
const CLIENT_RULES = [
  { pattern: /ascend|ascend.?lc|riaan|andr[eé]/i, client: 'Ascend LC',     category: 'income' },
  { pattern: /race.?teknik|race.?technik|farhaan|rt.auto/i, client: 'Race Technik', category: 'income' },
  { pattern: /favlog|mo\b|irshad|supply.?chain/i, client: 'Favlog',         category: 'income' },
  { pattern: /vanta/i,                             client: 'Vanta Studios', category: 'income' },
  { pattern: /invoice|retainer|amalfi/i,           client: null,            category: 'income' },
];

const SUB_RULES = [
  { pattern: /anthropic|claude/i,   sub: 'Claude Pro' },
  { pattern: /google|gws|workspace/i, sub: 'Google Workspace' },
  { pattern: /chatgpt|openai/i,      sub: 'ChatGPT Plus' },
  { pattern: /perplexity/i,          sub: 'Perplexity Pro' },
  { pattern: /supabase/i,            sub: 'Supabase' },
  { pattern: /lovable/i,             sub: 'Lovable' },
  { pattern: /hugging.?face/i,       sub: 'HuggingFace' },
  { pattern: /github/i,              sub: 'GitHub' },
  { pattern: /minimax/i,             sub: 'MiniMax' },
  { pattern: /adobe/i,               sub: 'Adobe' },
  { pattern: /notion/i,              sub: 'Notion' },
  { pattern: /slack/i,               sub: 'Slack' },
  { pattern: /zapier/i,              sub: 'Zapier' },
  { pattern: /vercel/i,              sub: 'Vercel' },
  { pattern: /netlify/i,             sub: 'Netlify' },
  { pattern: /digitalocean|do\.com/i, sub: 'DigitalOcean' },
  { pattern: /apple\.com|itunes|app.?store/i, sub: 'Apple' },
  { pattern: /amazon|aws/i,          sub: 'AWS' },
];

const BANK_PAT    = /fnb|service fee|monthly fee|bank charge|ledger fee|atm fee|card fee|sms fee/i;
const DRAWING_PAT = /henry.?burton|henryburton|sajonix|josh|h\.burton|atm withdrawal|cash withdrawal/i;
const HARDWARE_PAT = /takealot|incredible|matrix|apple store|istore|best.?buy|tech.?hub/i;

function categoriseTx(description, amountRand, type) {
  const desc = (description || '').toUpperCase();

  if (type === 'income') {
    for (const rule of CLIENT_RULES) {
      if (rule.pattern.test(description)) {
        return { category: 'Income', matched_client: rule.client };
      }
    }
    return { category: 'Income', matched_client: null };
  }

  // expense path
  if (DRAWING_PAT.test(description)) return { category: 'Drawings', matched_client: null, matched_sub: null };
  if (BANK_PAT.test(description))    return { category: 'Bank Fees', matched_client: null, matched_sub: null };
  if (HARDWARE_PAT.test(description)) return { category: 'Hardware', matched_client: null, matched_sub: null };

  for (const rule of SUB_RULES) {
    if (rule.pattern.test(description)) {
      return { category: 'Subscription', matched_client: null, matched_sub: rule.sub };
    }
  }

  return { category: 'Other', matched_client: null, matched_sub: null };
}

// ── Telegram helper ───────────────────────────────────────────────────────────
async function tg(text, chatIds = [JOSH_CHAT_ID]) {
  for (const chatId of chatIds) {
    try {
      const res = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'HTML' }),
      });
      if (!res.ok) console.error(`${LOG_TAG} TG error: ${await res.text()}`);
    } catch (e) {
      console.error(`${LOG_TAG} TG send failed: ${e.message}`);
    }
  }
}

function fmtZar(n) { return `R${Math.abs(n).toLocaleString('en-ZA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`; }

// ── Last-sync helpers ─────────────────────────────────────────────────────────
function getLastSync() {
  if (!existsSync(LAST_SYNC)) return null;
  const raw = readFileSync(LAST_SYNC, 'utf8').trim();
  return raw ? new Date(raw) : null;
}

function saveLastSync(date) {
  const tmpDir = join(WORKSPACE, 'tmp');
  if (!existsSync(tmpDir)) mkdirSync(tmpDir, { recursive: true });
  writeFileSync(LAST_SYNC, date.toISOString(), 'utf8');
}

// ── Random delay to avoid FNB bot detection ───────────────────────────────────
function delay(minMs = 1000, maxMs = 3000) {
  const ms = Math.floor(Math.random() * (maxMs - minMs + 1)) + minMs;
  return new Promise(r => setTimeout(r, ms));
}

// ── Process one FNB account ───────────────────────────────────────────────────
async function processAccount(api, accountType, targetAccountNumber, lastSync) {
  const newTxns = [];
  const unknownCharges = [];
  const clientPayments = [];
  let   lowBalanceAlert = null;

  const accounts = await api.accounts.get();
  console.log(`${LOG_TAG} [${accountType}] Found ${accounts.length} account(s)`);

  for (const acct of accounts) {
    // For business: only process the target account number
    if (accountType === 'business' && targetAccountNumber) {
      const acctNum = (acct.accountNumber || '').replace(/\s/g, '');
      if (acctNum !== targetAccountNumber) {
        console.log(`${LOG_TAG} [${accountType}] Skipping account ${acctNum}`);
        continue;
      }
    }

    // Check balance for alerts (values are in cents)
    try {
      await delay();
      const detail = await acct.detailedBalance();
      const availBal = (detail.availableBalance || 0) / 100;
      console.log(`${LOG_TAG} [${accountType}] Account ${acct.accountNumber}: available R${availBal.toFixed(2)}`);
      if (accountType === 'business' && availBal < LOW_BAL_THRESHOLD) {
        lowBalanceAlert = { account: acct.accountNumber, balance: availBal };
      }
    } catch (e) {
      console.error(`${LOG_TAG} [${accountType}] detailedBalance error: ${e.message}`);
    }

    // Pull transactions
    await delay();
    let transactions;
    try {
      transactions = await acct.transactions();
    } catch (e) {
      console.error(`${LOG_TAG} [${accountType}] transactions() error: ${e.message}`);
      continue;
    }

    console.log(`${LOG_TAG} [${accountType}] Pulled ${transactions.length} raw transactions`);

    for (const tx of transactions) {
      // fnb-api returns Moment.js date objects; amount is in cents; balance is in cents
      const txDate   = tx.date ? new Date(tx.date.valueOf()) : new Date();
      const amountRand = (tx.amount || 0) / 100;  // negative = debit, positive = credit
      const balRand    = (tx.balance || 0) / 100;
      const desc       = tx.description || '';
      const ref        = tx.reference || '';

      // Skip if before last sync
      if (lastSync && txDate < lastSync) continue;

      const type = amountRand >= 0 ? 'income' : 'expense';
      const { category, matched_client, matched_sub } = categoriseTx(desc, amountRand, type);

      // Build a stable unique ID: ref if present, else hash of date+desc+amount
      const fnbTxId = ref
        ? `${accountType}:${ref}`
        : `${accountType}:${txDate.toISOString().slice(0, 10)}:${desc}:${Math.round(amountRand * 100)}`;

      const row = {
        account_type:  accountType,
        type,
        amount:        Math.abs(amountRand),
        description:   desc,
        category,
        date:          txDate.toISOString().slice(0, 10),
        reference:     ref || null,
        balance_after: balRand,
        fnb_tx_id:     fnbTxId,
        matched_client: matched_client || null,
        matched_sub:    matched_sub    || null,
        notes:         null,
      };

      newTxns.push(row);

      // Alert accumulators
      if (type === 'income' && matched_client) {
        clientPayments.push({ client: matched_client, amount: amountRand, date: row.date });
      }
      if (type === 'expense' && category === 'Other') {
        unknownCharges.push({ desc, amount: amountRand, date: row.date });
      }
    }
  }

  return { newTxns, clientPayments, unknownCharges, lowBalanceAlert };
}

// ── Upsert to Supabase ────────────────────────────────────────────────────────
async function upsertTxns(rows) {
  if (rows.length === 0) return;
  const { error } = await supabase
    .from('finance_transactions')
    .upsert(rows, { onConflict: 'fnb_tx_id', ignoreDuplicates: true });
  if (error) console.error(`${LOG_TAG} Supabase upsert error:`, error.message);
  else console.log(`${LOG_TAG} Upserted ${rows.length} transaction(s)`);
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  console.log(`${LOG_TAG} Starting at ${new Date().toISOString()}`);

  if (!BIZ_USERNAME || !BIZ_PASSWORD) {
    console.error(`${LOG_TAG} FNB_BUSINESS_USERNAME / FNB_BUSINESS_PASSWORD not set — skipping business account`);
  }

  const lastSync  = getLastSync();
  const runStart  = new Date();
  const puppeteerOptions = {
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-blink-features=AutomationControlled',
      '--disable-infobars',
      '--window-size=1366,768',
    ],
    defaultViewport: { width: 1366, height: 768 },
  };

  let allClientPayments = [];
  let allUnknownCharges = [];
  let allLowBalance     = null;
  let totalInserted     = 0;

  // ── Business account ──────────────────────────────────────────────────────
  if (BIZ_USERNAME && BIZ_PASSWORD) {
    console.log(`${LOG_TAG} Logging into FNB business account...`);
    const bizApi = new FnbApi({
      username: BIZ_USERNAME,
      password: BIZ_PASSWORD,
      cache: false,
      puppeteerOptions,
    });

    try {
      await delay(1000, 2000);
      const { newTxns, clientPayments, unknownCharges, lowBalanceAlert } = await processAccount(
        bizApi, 'business', BIZ_ACCOUNT.replace(/\s/g, ''), lastSync
      );
      await upsertTxns(newTxns);
      totalInserted   += newTxns.length;
      allClientPayments = allClientPayments.concat(clientPayments);
      allUnknownCharges = allUnknownCharges.concat(unknownCharges);
      if (lowBalanceAlert) allLowBalance = lowBalanceAlert;
    } catch (e) {
      console.error(`${LOG_TAG} Business account error: ${e.message}`);
      await tg(`<b>Finance Poller Error</b>\nBusiness account failed: ${e.message}`);
    } finally {
      try { await bizApi.close(); } catch (_) {}
    }
  }

  await delay(3000, 6000);

  // ── Personal account ──────────────────────────────────────────────────────
  if (PERS_USERNAME && PERS_PASSWORD) {
    console.log(`${LOG_TAG} Logging into FNB personal account...`);
    const persApi = new FnbApi({
      username: PERS_USERNAME,
      password: PERS_PASSWORD,
      cache: false,
      puppeteerOptions,
    });

    try {
      await delay(1000, 2000);
      const { newTxns, clientPayments, unknownCharges } = await processAccount(
        persApi, 'personal', null, lastSync
      );
      await upsertTxns(newTxns);
      totalInserted   += newTxns.length;
      allClientPayments = allClientPayments.concat(clientPayments);
      allUnknownCharges = allUnknownCharges.concat(unknownCharges);
    } catch (e) {
      console.error(`${LOG_TAG} Personal account error: ${e.message}`);
    } finally {
      try { await persApi.close(); } catch (_) {}
    }
  } else {
    console.log(`${LOG_TAG} Personal account credentials not set — skipping`);
  }

  // ── Alerts ────────────────────────────────────────────────────────────────
  if (allLowBalance) {
    await tg(
      `<b>Low Balance Warning</b>\nFNB Business (${allLowBalance.account}): ${fmtZar(allLowBalance.balance)} available\nThreshold: ${fmtZar(LOW_BAL_THRESHOLD)}`,
      [JOSH_CHAT_ID]
    );
  }

  for (const p of allClientPayments) {
    await tg(
      `<b>Payment Received</b>\n${p.client}: ${fmtZar(p.amount)} on ${p.date}`,
      [JOSH_CHAT_ID, SALAH_CHAT_ID]
    );
    await delay(300, 600);
  }

  if (allUnknownCharges.length > 0) {
    const lines = allUnknownCharges.slice(0, 5).map(c => `  ${c.date}: ${fmtZar(c.amount)} — ${c.desc.slice(0, 60)}`).join('\n');
    const more  = allUnknownCharges.length > 5 ? `\n  ...and ${allUnknownCharges.length - 5} more` : '';
    await tg(
      `<b>Unknown Charges Detected</b>\n${lines}${more}\nReview in Mission Control Finances tab.`,
      [JOSH_CHAT_ID]
    );
  }

  // ── Save last sync timestamp ───────────────────────────────────────────────
  saveLastSync(runStart);

  console.log(`${LOG_TAG} Done. Inserted/updated ${totalInserted} transaction(s). Last sync saved.`);
}

main().catch(e => {
  console.error(`${LOG_TAG} Fatal:`, e);
  process.exit(1);
});
