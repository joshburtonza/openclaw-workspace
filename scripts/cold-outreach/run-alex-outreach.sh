#!/usr/bin/env bash
# run-alex-outreach.sh
# Alex cold outreach — Supabase-backed, 3-step sequences, daily limits.
#
# Step 1 (day 0): intro email — hook + value
# Step 2 (day 4): follow-up — new angle, no guilt-trip
# Step 3 (day 9): breakup — closing the file, no hard feelings
#
# Daily limits: Mon–Wed=10, Thu–Fri=15, Sat–Sun=0 (skip)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="$(dirname "$0")/../.env.scheduler"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
FROM_EMAIL="alex@amalfiai.com"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="1140320036"
MODEL="claude-sonnet-4-6"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

tg_msg() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$text"),\"parse_mode\":\"HTML\"}" \
    >/dev/null
}

supa_get() {
  local path="$1"
  curl -s "${SUPABASE_URL}/rest/v1/${path}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}"
}

supa_patch() {
  local path="$1" body="$2"
  curl -s -X PATCH "${SUPABASE_URL}/rest/v1/${path}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H 'Content-Type: application/json' \
    -H 'Prefer: return=minimal' \
    -d "$body"
}

supa_post() {
  local path="$1" body="$2"
  curl -s -X POST "${SUPABASE_URL}/rest/v1/${path}" \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${SUPABASE_KEY}" \
    -H 'Content-Type: application/json' \
    -H 'Prefer: return=minimal' \
    -d "$body"
}

export SUPABASE_URL SUPABASE_KEY

# ── 1. Daily limit by day of week ─────────────────────────────────────────────
DOW=$(date +%u)  # 1=Mon ... 7=Sun
case "$DOW" in
  1|2|3) DAILY_LIMIT=10 ;;
  4|5)   DAILY_LIMIT=15 ;;
  6|7)   log "Weekend — skipping outreach."; exit 0 ;;
esac

# ── 2. Count already-sent today ───────────────────────────────────────────────
TODAY_UTC=$(python3 -c "
import datetime
SAST = datetime.timezone(datetime.timedelta(hours=2))
now = datetime.datetime.now(SAST)
start = now.replace(hour=0,minute=0,second=0,microsecond=0)
# Convert to UTC ISO for Supabase query
import datetime as dt
print(start.astimezone(dt.timezone.utc).isoformat())
")

SENT_TODAY=$(supa_get "outreach_log?select=id&sent_at=gte.${TODAY_UTC}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
REMAINING=$(( DAILY_LIMIT - SENT_TODAY ))

log "Daily limit: ${DAILY_LIMIT} | Sent today: ${SENT_TODAY} | Remaining: ${REMAINING}"

if [[ "$REMAINING" -le 0 ]]; then
  log "Daily limit reached. Exiting."
  exit 0
fi

# ── 3. Fetch candidates for each step ─────────────────────────────────────────
# Returns JSON. Python does the heavy logic to pick who gets contacted next.
python3 - <<'PY'
import json, os, subprocess, sys, datetime, time

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SUPABASE_KEY']
MODEL        = os.environ.get('MODEL','claude-sonnet-4-6')
FROM_EMAIL   = os.environ.get('FROM_EMAIL','alex@amalfiai.com')
BOT_TOKEN    = os.environ.get('BOT_TOKEN','')
CHAT_ID      = os.environ.get('CHAT_ID','')
REMAINING    = int(os.environ.get('REMAINING','0'))

import requests
from urllib.parse import urlencode

def supa(path, method='GET', body=None):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    headers = {
        'apikey': KEY,
        'Authorization': f'Bearer {KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
    }
    if method == 'GET':
        r = requests.get(url, headers=headers, timeout=20)
    elif method == 'POST':
        r = requests.post(url, headers=headers, json=body, timeout=20)
    elif method == 'PATCH':
        r = requests.patch(url, headers=headers, json=body, timeout=20)
    r.raise_for_status()
    if method == 'GET':
        return r.json()
    return None

def tg(text):
    if BOT_TOKEN:
        try:
            requests.post(
                f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
                json={'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'},
                timeout=10
            )
        except Exception:
            pass

def now_utc():
    return datetime.datetime.now(datetime.timezone.utc)

def days_ago(iso_str):
    if not iso_str:
        return 9999
    try:
        dt = datetime.datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        return (now_utc() - dt).days
    except:
        return 9999

def generate_email(lead, step):
    fname = lead.get('first_name','')
    company = lead.get('company','') or 'your company'
    website = lead.get('website','') or ''
    notes   = lead.get('notes','') or ''

    step_prompts = {
        1: f"""You are Alex, a sharp South African AI agency founder (Amalfi AI).
Write a personalised cold email to {fname} at {company}{' (' + website + ')' if website else ''}.

Rules:
- South African English, warm but direct, no corporate speak
- No dashes or hyphens in writing
- Open with a genuine observation about their business (not generic)
- 3 to 4 sentences max
- One clear low-friction CTA (15min call, reply to this email)
- No "I hope this email finds you well" or any opener cliche
- Subject line that does not sound like marketing

Return EXACTLY this format (nothing else):
Subject: [your subject line]
Body: [your email body]""",

        2: f"""You are Alex from Amalfi AI following up with {fname} at {company}.
They did not reply to your intro email 4 days ago. Write a short follow-up.

Rules:
- Do NOT guilt-trip or say "just following up"
- Lead with a new angle or insight relevant to {company}
- 2 to 3 sentences max
- End with the same CTA as before but worded differently
- South African English, no corporate speak
- No dashes or hyphens

Additional context about this lead: {notes if notes else 'none'}

Return EXACTLY:
Subject: [your subject line]
Body: [your email body]""",

        3: f"""You are Alex from Amalfi AI. This is your final email to {fname} at {company}.
They have not replied to 2 emails. Write a respectful breakup email.

Rules:
- Close the loop gracefully, no passive aggression
- Leave the door open for the future
- 2 sentences max
- Slightly self-aware and warm
- South African English, no dashes or hyphens

Return EXACTLY:
Subject: [your subject line]
Body: [your email body]""",
    }

    prompt = step_prompts[step]
    result = subprocess.run(
        ['claude', '-p', '--model', MODEL, prompt],
        capture_output=True, text=True, timeout=90
    )
    raw = result.stdout.strip()

    subject, body = '', ''
    for line in raw.split('\n'):
        if line.startswith('Subject:'):
            subject = line[len('Subject:'):].strip()
        elif line.startswith('Body:'):
            body = raw[raw.index('Body:')+5:].strip()
            break

    if not subject or not body:
        raise ValueError(f"Could not parse email from Claude output:\n{raw[:400]}")

    return subject, body

sent_count = 0
errors = []

# ── Step 1: new leads, never contacted ────────────────────────────────────────
if REMAINING > 0:
    new_leads = supa("leads?status=eq.new&select=*&order=created_at.asc")
    for lead in new_leads:
        if REMAINING <= 0:
            break
        lid = lead['id']
        # double-check no outreach_log entry
        existing = supa(f"outreach_log?lead_id=eq.{lid}&select=id")
        if existing:
            continue
        try:
            print(f"  Step 1 → {lead['email']} ({lead.get('company','')})")
            subject, body = generate_email(lead, 1)
            result = subprocess.run(
                ['gog', 'gmail', 'send',
                 '--account', FROM_EMAIL,
                 '--to',   lead['email'],
                 '--subject', subject,
                 '--body', body],
                capture_output=True, text=True, timeout=60
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr[:200])
            # parse gmail message id
            msg_id = ''
            for line in result.stdout.split('\n'):
                if 'message_id' in line.lower() or 'id:' in line.lower():
                    msg_id = line.split(':',1)[-1].strip()
                    break
            # log
            supa('outreach_log', 'POST', {
                'lead_id': lid, 'step': 1,
                'subject': subject, 'body': body,
                'gmail_message_id': msg_id,
            })
            # update lead
            supa(f'leads?id=eq.{lid}', 'PATCH', {
                'status': 'contacted',
                'last_contacted_at': now_utc().isoformat(),
            })
            sent_count += 1
            REMAINING -= 1
            time.sleep(2)
        except Exception as e:
            errors.append(f"Step1 {lead['email']}: {e}")
            print(f"  ERROR: {e}", file=sys.stderr)

# ── Step 2: contacted 4+ days ago, only step 1 done ───────────────────────────
if REMAINING > 0:
    contacted = supa("leads?status=eq.contacted&select=*")
    for lead in contacted:
        if REMAINING <= 0:
            break
        lid = lead['id']
        logs = supa(f"outreach_log?lead_id=eq.{lid}&select=step,sent_at&order=step.asc")
        steps_done = [l['step'] for l in logs]
        if steps_done != [1]:
            continue
        last_sent = logs[-1]['sent_at'] if logs else None
        if days_ago(last_sent) < 4:
            continue
        try:
            print(f"  Step 2 → {lead['email']} ({lead.get('company','')})")
            subject, body = generate_email(lead, 2)
            result = subprocess.run(
                ['gog', 'gmail', 'send',
                 '--account', FROM_EMAIL,
                 '--to',   lead['email'],
                 '--subject', subject,
                 '--body', body],
                capture_output=True, text=True, timeout=60
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr[:200])
            msg_id = ''
            for line in result.stdout.split('\n'):
                if 'message_id' in line.lower():
                    msg_id = line.split(':',1)[-1].strip()
                    break
            supa('outreach_log', 'POST', {
                'lead_id': lid, 'step': 2,
                'subject': subject, 'body': body,
                'gmail_message_id': msg_id,
            })
            supa(f'leads?id=eq.{lid}', 'PATCH', {
                'last_contacted_at': now_utc().isoformat(),
            })
            sent_count += 1
            REMAINING -= 1
            time.sleep(2)
        except Exception as e:
            errors.append(f"Step2 {lead['email']}: {e}")
            print(f"  ERROR: {e}", file=sys.stderr)

# ── Step 3: contacted 9+ days since step 2, only steps 1+2 done ───────────────
if REMAINING > 0:
    contacted = supa("leads?status=eq.contacted&select=*")
    for lead in contacted:
        if REMAINING <= 0:
            break
        lid = lead['id']
        logs = supa(f"outreach_log?lead_id=eq.{lid}&select=step,sent_at&order=step.asc")
        steps_done = [l['step'] for l in logs]
        if sorted(steps_done) != [1, 2]:
            continue
        last_sent = logs[-1]['sent_at'] if logs else None
        if days_ago(last_sent) < 9:
            continue
        try:
            print(f"  Step 3 → {lead['email']} ({lead.get('company','')})")
            subject, body = generate_email(lead, 3)
            result = subprocess.run(
                ['gog', 'gmail', 'send',
                 '--account', FROM_EMAIL,
                 '--to',   lead['email'],
                 '--subject', subject,
                 '--body', body],
                capture_output=True, text=True, timeout=60
            )
            if result.returncode != 0:
                raise RuntimeError(result.stderr[:200])
            msg_id = ''
            for line in result.stdout.split('\n'):
                if 'message_id' in line.lower():
                    msg_id = line.split(':',1)[-1].strip()
                    break
            supa('outreach_log', 'POST', {
                'lead_id': lid, 'step': 3,
                'subject': subject, 'body': body,
                'gmail_message_id': msg_id,
            })
            supa(f'leads?id=eq.{lid}', 'PATCH', {
                'status': 'sequence_complete',
                'last_contacted_at': now_utc().isoformat(),
            })
            sent_count += 1
            REMAINING -= 1
            time.sleep(2)
        except Exception as e:
            errors.append(f"Step3 {lead['email']}: {e}")
            print(f"  ERROR: {e}", file=sys.stderr)

# ── Summary ───────────────────────────────────────────────────────────────────
if sent_count > 0:
    tg(f"📤 <b>Alex Outreach</b> — {sent_count} email{'s' if sent_count > 1 else ''} sent today.\n"
       f"Errors: {len(errors)}")

if errors:
    print("ERRORS:", errors, file=sys.stderr)

print(f"Done. Sent: {sent_count}. Errors: {len(errors)}.")
PY
