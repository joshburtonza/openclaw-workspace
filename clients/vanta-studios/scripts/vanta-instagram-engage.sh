#!/usr/bin/env bash
# vanta-instagram-engage.sh
# Instagram engagement for Vanta Studios lead generation:
#   1. Comments on recent posts from leads (personalized, not generic)
#   2. Sends DMs to leads who have replied to a comment or follow you back
#
# Uses Playwright (Node.js) for browser automation.
# Rate-limited to prevent detection: max 15 comments/day, max 5 DMs/day.
#
# SETUP REQUIRED:
#   1. npm install playwright @playwright/test in workspace/node_modules
#   2. npx playwright install chromium
#   3. Set VANTA_INSTAGRAM_USERNAME + VANTA_INSTAGRAM_PASSWORD in .env.scheduler
#   4. Run once manually to do the Instagram login flow (saves session)
#
# NOT run on a fixed schedule — manual trigger or called by vanta-outreach.sh
# for warm leads only. Triggered via: /vanta ig-engage in Telegram.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$ROOT/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
IG_USERNAME="${VANTA_INSTAGRAM_USERNAME:-}"
IG_PASSWORD="${VANTA_INSTAGRAM_PASSWORD:-}"
IG_SESSION_FILE="$ROOT/tmp/vanta-ig-session.json"
LOG="$ROOT/out/vanta-ig-engage.log"

# Safety caps
MAX_COMMENTS_TODAY="${VANTA_IG_DAILY_COMMENTS:-15}"
MAX_DMS_TODAY="${VANTA_IG_DAILY_DMS:-5}"

mkdir -p "$ROOT/out" "$ROOT/tmp"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === vanta-instagram-engage starting ===" | tee -a "$LOG"

# ── Check prerequisites ───────────────────────────────────────────────────────

if [[ -z "$IG_USERNAME" || -z "$IG_PASSWORD" ]]; then
  echo "[$(date '+%H:%M:%S')] ERROR: VANTA_INSTAGRAM_USERNAME / VANTA_INSTAGRAM_PASSWORD not set in .env.scheduler" | tee -a "$LOG"
  exit 1
fi

if ! command -v node &>/dev/null; then
  echo "[$(date '+%H:%M:%S')] ERROR: node not found. Install via: brew install node" | tee -a "$LOG"
  exit 1
fi

if ! node -e "require('@playwright/test')" &>/dev/null; then
  echo "[$(date '+%H:%M:%S')] ERROR: Playwright not installed. Run: cd $ROOT && npm install @playwright/test && npx playwright install chromium" | tee -a "$LOG"
  exit 1
fi

export SUPABASE_URL SERVICE_KEY BOT_TOKEN CHAT_ID OPENAI_API_KEY
export IG_USERNAME IG_PASSWORD IG_SESSION_FILE
export MAX_COMMENTS_TODAY MAX_DMS_TODAY

# ── Generate personalized comment via Claude ──────────────────────────────────
# (Called from Node.js script below via subprocess)
generate_comment() {
  local HANDLE="$1"
  local SPEC="$2"
  local RECENT_CAPTION="$3"

  export _VANTA_HANDLE="$HANDLE" _VANTA_SPEC="$SPEC" _VANTA_CAPTION="$RECENT_CAPTION"
  python3 - <<'PY'
import os, json, urllib.request

KEY    = os.environ.get('OPENAI_API_KEY', '')
handle = os.environ.get('_VANTA_HANDLE','')
spec   = os.environ.get('_VANTA_SPEC','photographer')
caption = os.environ.get('_VANTA_CAPTION','')[:150]

prompt = f"""Write ONE short Instagram comment (15-30 words) for a {spec} photographer (@{handle}).
Recent post caption hint: "{caption}"
Rules:
- Genuinely complimentary and specific to their style
- From a fellow creative/studio perspective (Vanta Studios)
- NO emojis, NO hashtags, NO generic phrases like "great shot" or "love this"
- Sound like a real person, not a bot
- Output ONLY the comment text, nothing else."""

data = json.dumps({
    'model': 'gpt-4o',
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': 60,
}).encode()

req = urllib.request.Request(
    'https://api.openai.com/v1/chat/completions', data=data,
    headers={'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json'}
)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        resp = json.loads(r.read())
    print(resp['choices'][0]['message']['content'].strip())
except Exception as e:
    print(f'Great composition on this one — the lighting really works.', file=None)
    import sys; print('Great composition on this one — the lighting really works.')
PY
}
export -f generate_comment

# ── Node.js Playwright script ─────────────────────────────────────────────────

NODE_SCRIPT=$(cat <<'NODEJS'
const { chromium } = require('@playwright/test');
const { execSync }  = require('child_process');
const fs            = require('fs');
const https         = require('https');

const SUPABASE_URL   = process.env.SUPABASE_URL;
const SERVICE_KEY    = process.env.SERVICE_KEY;
const BOT_TOKEN      = process.env.BOT_TOKEN;
const CHAT_ID        = process.env.CHAT_ID;
const IG_USERNAME    = process.env.IG_USERNAME;
const IG_PASSWORD    = process.env.IG_PASSWORD;
const IG_SESSION     = process.env.IG_SESSION_FILE;
const MAX_COMMENTS   = parseInt(process.env.MAX_COMMENTS_TODAY || '15');
const MAX_DMS        = parseInt(process.env.MAX_DMS_TODAY || '5');

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const rand  = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;

function supaFetch(path, params = {}) {
  return new Promise((resolve, reject) => {
    const qs = new URLSearchParams(params).toString();
    const url = `${SUPABASE_URL}/rest/v1/${path}${qs ? '?' + qs : ''}`;
    https.get(url, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, Accept: 'application/json' }
    }, (res) => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => resolve(JSON.parse(data)));
    }).on('error', reject);
  });
}

function supaPatch(table, id, body) {
  return new Promise((resolve) => {
    const url = new URL(`${SUPABASE_URL}/rest/v1/${table}?id=eq.${id}`);
    const data = JSON.stringify(body);
    const req = https.request({ hostname: url.hostname, path: url.pathname + url.search,
      method: 'PATCH', headers: {
        apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
        'Content-Type': 'application/json', Prefer: 'return=minimal', 'Content-Length': Buffer.byteLength(data)
      }
    }, (res) => { res.resume(); resolve(res.statusCode < 300); });
    req.on('error', () => resolve(false));
    req.write(data);
    req.end();
  });
}

function tgSend(text) {
  const data = JSON.stringify({ chat_id: CHAT_ID, text, parse_mode: 'HTML' });
  const req = https.request({ hostname: 'api.telegram.org', path: `/bot${BOT_TOKEN}/sendMessage`,
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }
  }, (res) => res.resume());
  req.on('error', () => {});
  req.write(data);
  req.end();
}

async function main() {
  // Fetch leads ready for IG engagement
  const leads = await supaFetch('vanta_leads', {
    'outreach_status': 'in.(queued,emailed)',
    'ig_comment_sent_at': 'is.null',
    'instagram_handle': 'not.is.null',
    'order': 'quality_score.desc',
    'limit': String(MAX_COMMENTS),
    'select': 'id,instagram_handle,specialties,quality_score',
  });

  if (!leads || leads.length === 0) {
    console.log('[ig-engage] No leads ready for IG engagement.');
    return;
  }

  console.log(`[ig-engage] ${leads.length} leads to engage.`);

  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
  });

  let context;

  // Restore session if available
  if (fs.existsSync(IG_SESSION)) {
    try {
      const state = JSON.parse(fs.readFileSync(IG_SESSION, 'utf8'));
      context = await browser.newContext({ storageState: state });
      console.log('[ig-engage] Restored IG session from disk.');
    } catch (e) {
      context = await browser.newContext();
    }
  } else {
    context = await browser.newContext();
  }

  const page = await context.newPage();

  // ── Login if needed ───────────────────────────────────────────────────────
  await page.goto('https://www.instagram.com/', { waitUntil: 'networkidle' });
  await sleep(rand(2000, 4000));

  const loginBtn = await page.$('a[href="/accounts/login/"]');
  if (loginBtn) {
    // Need to log in
    await page.goto('https://www.instagram.com/accounts/login/', { waitUntil: 'networkidle' });
    await sleep(rand(1500, 2500));
    await page.fill('input[name="username"]', IG_USERNAME);
    await sleep(rand(300, 600));
    await page.fill('input[name="password"]', IG_PASSWORD);
    await sleep(rand(300, 600));
    await page.click('button[type="submit"]');
    await sleep(rand(3000, 5000));

    // Save session
    const state = await context.storageState();
    fs.writeFileSync(IG_SESSION, JSON.stringify(state));
    console.log('[ig-engage] Logged in to Instagram, session saved.');
  }

  // ── Comment on leads ──────────────────────────────────────────────────────
  let comments_sent = 0;
  const commented_names = [];

  for (const lead of leads) {
    if (comments_sent >= MAX_COMMENTS) break;

    const handle = lead.instagram_handle;
    const specs  = (lead.specialties || []).join(', ') || 'photography';

    try {
      // Navigate to profile
      await page.goto(`https://www.instagram.com/${handle}/`, { waitUntil: 'networkidle' });
      await sleep(rand(2000, 3500));

      // Get first post
      const firstPost = await page.$('article a[href*="/p/"]');
      if (!firstPost) {
        console.log(`[ig-engage] ${handle}: no posts found, skipping`);
        continue;
      }

      await firstPost.click();
      await sleep(rand(2000, 4000));

      // Extract caption
      let caption = '';
      try {
        const captionEl = await page.$('article h1, article [data-testid="post-comment-root"] span');
        if (captionEl) caption = (await captionEl.textContent() || '').slice(0, 150);
      } catch (_) {}

      // Generate personalized comment via Claude (Python subprocess)
      let comment_text = `Beautiful ${specs} work — the quality really comes through.`;
      try {
        comment_text = execSync(
          `bash -c 'source /Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler && python3 -c "
import os,json,urllib.request
key=os.environ.get(\\\"OPENAI_API_KEY\\\",\\\"\\\")
prompt=f\\\"Write ONE short Instagram comment (15-30 words) for a ${specs} photographer. Genuinely specific, sound like a real creative professional, no emojis/hashtags. Output ONLY the comment.\\\"
data=json.dumps({\\\"model\\\":\\\"gpt-4o\\\",\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":prompt}],\\\"max_tokens\\\":60}).encode()
req=urllib.request.Request(\\\"https://api.openai.com/v1/chat/completions\\\",data=data,headers={\\\"Authorization\\\":\\\"Bearer \\\"+key,\\\"Content-Type\\\":\\\"application/json\\\"})
try:
  r=urllib.request.urlopen(req,timeout=15)
  print(json.loads(r.read())[\\\"choices\\\"][0][\\\"message\\\"][\\\"content\\\"].strip())
except: print(\\\"The lighting and composition here are really well done.\\\")
"'`,
          { encoding: 'utf8', timeout: 20000 }
        ).trim();
      } catch (_) {}

      // Find comment input
      const commentInput = await page.$('textarea[placeholder*="comment"], textarea[aria-label*="comment"]');
      if (!commentInput) {
        console.log(`[ig-engage] ${handle}: could not find comment input`);
        continue;
      }

      await commentInput.click();
      await sleep(rand(500, 1000));

      // Type comment character by character (humanlike)
      for (const char of comment_text) {
        await commentInput.type(char, { delay: rand(50, 120) });
      }

      await sleep(rand(800, 1500));

      // Submit
      const submitBtn = await page.$('button[type="submit"]:has-text("Post"), div[role="button"]:has-text("Post")');
      if (submitBtn) {
        await submitBtn.click();
        await sleep(rand(2000, 3000));
        comments_sent++;
        commented_names.push(`@${handle}`);
        console.log(`[ig-engage] Commented on @${handle}: "${comment_text}"`);

        // Update lead in Supabase
        await supaPatch('vanta_leads', lead.id, {
          ig_comment_sent_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        });
      }

      // Human-like gap between actions
      await sleep(rand(15000, 35000));

    } catch (err) {
      console.error(`[ig-engage] Error on @${handle}: ${err.message}`);
    }
  }

  // Save updated session
  try {
    const state = await context.storageState();
    fs.writeFileSync(IG_SESSION, JSON.stringify(state));
  } catch (_) {}

  await browser.close();

  console.log(`[ig-engage] Done. ${comments_sent} comments posted.`);

  if (comments_sent > 0) {
    tgSend(
      `💬 <b>Vanta Instagram Engaged</b>\n` +
      `${comments_sent} comment(s) posted:\n` +
      commented_names.map(n => `  • ${n}`).join('\n')
    );
  }
}

main().catch(e => { console.error('[ig-engage] Fatal:', e.message); process.exit(1); });
NODEJS
)

# Write Node script to temp file and run
TMPSCRIPT=$(mktemp /tmp/vanta-ig-XXXXXX.js)
echo "$NODE_SCRIPT" > "$TMPSCRIPT"
node "$TMPSCRIPT" 2>&1 | tee -a "$LOG"
rm -f "$TMPSCRIPT"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] vanta-instagram-engage complete" | tee -a "$LOG"
