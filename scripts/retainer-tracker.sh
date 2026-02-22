#!/usr/bin/env bash
# retainer-tracker.sh
# Runs on the 5th of each month.
# Checks income_entries for the current month — if an active client has no
# payment logged yet, queues a Sophia email draft + Telegram alert to Josh.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
_CHAT_ID_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/josh_private_chat_id"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-$(cat "$_CHAT_ID_FILE" 2>/dev/null || echo "7584896900")}"
SOPHIA_EMAIL="sophia@amalfiai.com"

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN CHAT_ID SOPHIA_EMAIL

python3 - <<'PY'
import os, json, requests, datetime, sys

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_KEY']
BOT = os.environ['BOT_TOKEN']
CHAT = os.environ['CHAT_ID']

def supa(path, method='GET', body=None, prefer=None):
    headers = {
        'apikey': KEY,
        'Authorization': f'Bearer {KEY}',
        'Content-Type': 'application/json',
    }
    if prefer:
        headers['Prefer'] = prefer
    base = f"{URL}/rest/v1/{path}"
    if method == 'GET':
        r = requests.get(base, headers=headers, timeout=20)
    elif method == 'POST':
        r = requests.post(base, headers=headers, json=body, timeout=20)
    r.raise_for_status()
    if method == 'GET':
        return r.json()
    return None

def tg(text):
    requests.post(
        f"https://api.telegram.org/bot{BOT}/sendMessage",
        json={'chat_id': CHAT, 'text': text, 'parse_mode': 'HTML'},
        timeout=10
    )

SAST = datetime.timezone(datetime.timedelta(hours=2))
now  = datetime.datetime.now(SAST)
month_key = now.strftime('%Y-%m')  # e.g. "2026-03"

print(f"Checking retainer payments for {month_key}...")

# Get active clients
clients = supa("clients?status=eq.active&select=id,name,slug,email_addresses,notes")
if not clients:
    print("No active clients found.")
    sys.exit(0)

# Get income entries for this month
entries = supa(f"income_entries?month=eq.{month_key}&select=client,amount,status")
paid_clients = {e['client'] for e in entries if e.get('status') in ('paid', 'invoiced')}

print(f"Active clients: {[c['name'] for c in clients]}")
print(f"Paid/invoiced this month: {paid_clients}")

missing = [c for c in clients if c['name'] not in paid_clients]

if not missing:
    print("All clients have payments logged. Nothing to chase.")
    sys.exit(0)

for client in missing:
    name = client['name']
    slug = client['slug']
    emails = client.get('email_addresses') or []
    to_email = emails[0] if emails else None

    print(f"  Missing payment: {name}")

    if not to_email:
        print(f"    No email on file for {name} — skipping email draft")
        tg(f"⚠️ <b>Retainer: {name}</b> has no payment logged for {month_key} and no email on file. Check manually.")
        continue

    # Build email draft
    subject = f"Quick note re: {month_key} invoice"
    body = (
        f"Hi there,\n\n"
        f"Just a friendly heads up that we have not yet received the retainer payment for {month_key}.\n\n"
        f"If you have already processed it, please ignore this. If not, whenever you get a chance would be great.\n\n"
        f"Let me know if you have any questions.\n\n"
        f"Warm regards,\nSophia\nAmalfi AI"
    )

    # Insert into email_queue as awaiting_approval
    row = {
        'from_email': os.environ['SOPHIA_EMAIL'],
        'to_email':   to_email,
        'subject':    subject,
        'body':       body,
        'client':     slug,
        'status':     'awaiting_approval',
        'requires_approval': True,
        'priority':   5,
        'analysis':   json.dumps({
            'intent': 'retainer_chase',
            'month':  month_key,
            'auto_generated': True,
        }),
    }
    supa('email_queue', 'POST', row, prefer='return=representation')

    # Send Telegram card for Josh to approve
    tg(
        f"💰 <b>Retainer chase: {name}</b>\n"
        f"No payment logged for {month_key}.\n\n"
        f"Draft email queued in Mission Control → Approvals.\n"
        f"Approve it to send the chase to <code>{to_email}</code>."
    )

print(f"Done. Missing payments: {[c['name'] for c in missing]}")
PY
