#!/usr/bin/env bash
# alex-reply-detection.sh
# Polls alex@amalfiai.com for replies from contacted leads.
# If a lead replies: update status → replied, fire Telegram alert to Josh.
# Runs hourly via cron.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="7584896900"
ACCOUNT="alex@amalfiai.com"

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN CHAT_ID ACCOUNT

python3 - <<'PY'
import os, json, subprocess, sys, datetime, requests

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SUPABASE_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
ACCOUNT      = os.environ['ACCOUNT']

def supa_get(path):
    r = requests.get(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'},
        timeout=20
    )
    r.raise_for_status()
    return r.json()

def supa_patch(path, body):
    requests.patch(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
        json=body, timeout=20
    ).raise_for_status()

def tg(text):
    try:
        requests.post(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            json={'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'},
            timeout=10
        )
    except Exception:
        pass

def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

# Get all contacted leads (any status that indicates we've reached out)
leads = supa_get(
    "leads?status=in.(contacted,sequence_complete)&select=id,first_name,last_name,email,company,status"
)

if not leads:
    print("No contacted leads to check.")
    sys.exit(0)

print(f"Checking {len(leads)} contacted leads for replies...")

new_replies = []

for lead in leads:
    email = lead.get('email', '')
    if not email:
        continue

    # Search for any reply from this sender
    result = subprocess.run(
        ['gog', 'gmail', 'search',
         f'from:{email}',
         '--account', ACCOUNT,
         '--max', '1'],
        capture_output=True, text=True, timeout=30
    )

    if result.returncode != 0:
        print(f"  gog error for {email}: {result.stderr[:100]}", file=sys.stderr)
        continue

    output = result.stdout.strip()
    if not output or 'no messages' in output.lower() or 'no results' in output.lower():
        continue

    # There is a reply — update lead
    print(f"  ✉️  Reply detected from {email}")
    supa_patch(f"leads?id=eq.{lead['id']}", {
        'status': 'replied',
        'reply_received_at': now_utc(),
        'reply_sentiment': 'unknown',  # can be enriched later
    })

    name = f"{lead.get('first_name','')} {lead.get('last_name','') or ''}".strip()
    company = lead.get('company') or email
    new_replies.append({'name': name, 'email': email, 'company': company})

if new_replies:
    lines = [f"📥 <b>Alex — {len(new_replies)} new lead repl{'ies' if len(new_replies) > 1 else 'y'}!</b>\n"]
    for r in new_replies:
        lines.append(f"• <b>{r['name']}</b> @ {r['company']} ({r['email']})")
    lines.append("\nCheck Mission Control → Cold Outreach to review + qualify.")
    tg('\n'.join(lines))

print(f"Done. New replies detected: {len(new_replies)}.")
PY
