#!/usr/bin/env bash
# sophia-email-watcher.sh
# Polls josh@amalfiai.com for new important emails every 15 min.
# Sends a WhatsApp brief to Josh via the Sophia gateway.
# Filters out newsletters, automated alerts, and noise.
# Tracks seen IDs in tmp/email-watcher-seen.txt to avoid re-alerting.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

ACCOUNT="josh@amalfiai.com"
SEEN_FILE="$WS/tmp/email-watcher-seen.txt"
LOG_FILE="$WS/out/sophia-email-watcher.log"
WA_API="http://127.0.0.1:3001/send"
JOSH_NUMBER="${WA_OWNER_NUMBER:-+27812705358}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

touch "$SEEN_FILE" 2>/dev/null || true
mkdir -p "$WS/out" "$WS/tmp"

log "Email watcher running"

# Fetch unread inbox emails from the last 30 min
export _EMAILS_JSON
_EMAILS_JSON=$(gog gmail list "is:unread in:inbox newer_than:30m" \
  --account "$ACCOUNT" \
  --max 20 \
  --json --results-only --no-input 2>/dev/null || echo "[]")

if [[ "$_EMAILS_JSON" == "[]" || -z "$_EMAILS_JSON" ]]; then
  log "No new emails"
  exit 0
fi

export _SEEN_FILE="$SEEN_FILE"
export _JOSH_NUMBER="$JOSH_NUMBER"
export _WA_API="$WA_API"
export _OPENAI_KEY="${OPENAI_API_KEY:-}"

python3 - <<'PYWATCH'
import json, os, re, urllib.request, urllib.parse

emails_raw = json.loads(os.environ.get('_EMAILS_JSON', '[]'))
if not isinstance(emails_raw, list):
    emails_raw = emails_raw.get('threads', emails_raw.get('messages', []))

seen_file = os.environ.get('_SEEN_FILE', '')
josh_number = os.environ.get('_JOSH_NUMBER', '')
wa_api = os.environ.get('_WA_API', '')
openai_key = os.environ.get('_OPENAI_KEY', '')

# Load seen IDs
seen = set()
if seen_file and os.path.exists(seen_file):
    seen = set(open(seen_file).read().split())

# Noise filters — skip automated, promotional, or system emails
NOISE_SENDERS = [
    'noreply', 'no-reply', 'donotreply', 'notifications@', 'alerts@',
    'mailer@', 'bounce@', 'newsletter', 'unsubscribe', 'marketing@',
    'support@stripe', 'sentry.io', 'github.com', 'accounts.google',
    'lovable.dev', 'vercel.com', 'supabase.io', 'anthropic.com',
]

NOISE_SUBJECTS = [
    'unsubscribe', 'newsletter', 'security alert', 'sign-in attempt',
    'verify your email', 'confirm your', 'payment receipt', 'invoice #',
    'your order', 'shipment', 'tracking number', 'welcome to your',
    'free trial', 'upgrade your plan', 'get started',
]

def is_noise(email):
    sender = (email.get('from', '') or '').lower()
    subject = (email.get('subject', '') or '').lower()
    for n in NOISE_SENDERS:
        if n in sender:
            return True
    for n in NOISE_SUBJECTS:
        if n in subject:
            return True
    return False

def send_wa(message):
    payload = json.dumps({'to': josh_number, 'message': message}).encode()
    req = urllib.request.Request(wa_api, data=payload,
        headers={'Content-Type': 'application/json'}, method='POST')
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f'WA send error: {e}')

def summarise_with_gpt(subject, sender, snippet):
    if not openai_key:
        return snippet[:120] if snippet else ''
    payload = json.dumps({
        'model': 'gpt-4o-mini',
        'messages': [
            {'role': 'system', 'content': 'Summarise this email in one short sentence (max 20 words). No filler. Just what it is about.'},
            {'role': 'user', 'content': f'Subject: {subject}\nFrom: {sender}\nSnippet: {snippet}'},
        ],
        'max_tokens': 60,
        'temperature': 0,
    }).encode()
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=payload,
        headers={'Authorization': f'Bearer {openai_key}', 'Content-Type': 'application/json'},
        method='POST')
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read())
            return d['choices'][0]['message']['content'].strip()
    except:
        return snippet[:120] if snippet else ''

new_seen = []
alerts = []

for email in emails_raw:
    eid = email.get('id', '') or email.get('threadId', '')
    if not eid or eid in seen:
        continue
    if is_noise(email):
        new_seen.append(eid)
        continue

    sender  = email.get('from', '') or email.get('sender', '') or 'Unknown'
    subject = email.get('subject', '') or '(No subject)'
    snippet = email.get('snippet', '') or email.get('body', '') or ''
    date    = (email.get('date', '') or '')[:16]

    summary = summarise_with_gpt(subject, sender, snippet)

    # Clean sender display: "Name <email@>" → "Name"
    sender_display = re.sub(r'\s*<[^>]+>', '', sender).strip() or sender

    alerts.append(f"📧 *{sender_display}*\n_{subject}_\n{summary}")
    new_seen.append(eid)

if alerts:
    if len(alerts) == 1:
        msg = f"New email:\n\n{alerts[0]}"
    else:
        msg = f"{len(alerts)} new emails:\n\n" + "\n\n".join(alerts)
    send_wa(msg)
    print(f"Alerted {len(alerts)} email(s)")
else:
    print("All new emails were noise — nothing to alert")

# Save seen IDs
if new_seen and seen_file:
    with open(seen_file, 'a') as f:
        f.write('\n'.join(new_seen) + '\n')

# Prune seen file to last 500 lines
if seen_file and os.path.exists(seen_file):
    lines = open(seen_file).readlines()
    if len(lines) > 500:
        open(seen_file, 'w').writelines(lines[-500:])
PYWATCH

log "Done"
