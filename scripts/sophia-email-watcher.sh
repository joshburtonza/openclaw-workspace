#!/usr/bin/env bash
# sophia-email-watcher.sh
# Polls both josh@ and sophia@ inboxes every 15 min.
#
# josh@ inbox:   alerts Josh via WA about important emails
# sophia@ inbox: detects actionable replies (reschedule confirmations,
#                meeting acceptances, etc.) and acts automatically on the calendar.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

JOSH_ACCOUNT="josh@amalfiai.com"
SOPHIA_ACCOUNT="sophia@amalfiai.com"
SEEN_FILE="$WS/tmp/email-watcher-seen.txt"
SEEN_SOPHIA_FILE="$WS/tmp/email-watcher-seen-sophia.txt"
LOG_FILE="$WS/out/sophia-email-watcher.log"
WA_API="http://127.0.0.1:3001/send"
JOSH_NUMBER="${WA_OWNER_NUMBER:-+27812705358}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

touch "$SEEN_FILE" "$SEEN_SOPHIA_FILE" 2>/dev/null || true
mkdir -p "$WS/out" "$WS/tmp"

log "Email watcher running"

# ── 1. Josh inbox — fetch unread emails ───────────────────────────────────────
export _JOSH_EMAILS_JSON
_JOSH_EMAILS_JSON=$(gog gmail list "is:unread in:inbox newer_than:30m" \
  --account "$JOSH_ACCOUNT" \
  --max 20 \
  --json --results-only --no-input 2>/dev/null || echo "[]")

# ── 2. Sophia inbox — fetch unread replies from external senders ──────────────
export _SOPHIA_EMAILS_JSON
_SOPHIA_EMAILS_JSON=$(gog gmail list "is:unread in:inbox -from:sophia@amalfiai.com" \
  --account "$SOPHIA_ACCOUNT" \
  --max 10 \
  --json --results-only --no-input 2>/dev/null || echo "[]")

export _SEEN_FILE="$SEEN_FILE"
export _SEEN_SOPHIA_FILE="$SEEN_SOPHIA_FILE"
export _JOSH_NUMBER="$JOSH_NUMBER"
export _WA_API="$WA_API"
export _OPENAI_KEY="${OPENAI_API_KEY:-}"
export _SOPHIA_ACCOUNT="$SOPHIA_ACCOUNT"
export _JOSH_ACCOUNT="$JOSH_ACCOUNT"
export _TODAY=$(date '+%Y-%m-%d')

python3 - <<'PYWATCH'
import json, os, re, subprocess, urllib.request, html
from datetime import datetime, timezone

josh_emails_raw   = json.loads(os.environ.get('_JOSH_EMAILS_JSON', '[]'))
sophia_emails_raw = json.loads(os.environ.get('_SOPHIA_EMAILS_JSON', '[]'))
if not isinstance(josh_emails_raw, list):
    josh_emails_raw = josh_emails_raw.get('threads', josh_emails_raw.get('messages', []))
if not isinstance(sophia_emails_raw, list):
    sophia_emails_raw = sophia_emails_raw.get('threads', sophia_emails_raw.get('messages', []))

seen_file        = os.environ.get('_SEEN_FILE', '')
seen_sophia_file = os.environ.get('_SEEN_SOPHIA_FILE', '')
josh_number      = os.environ.get('_JOSH_NUMBER', '')
wa_api           = os.environ.get('_WA_API', '')
openai_key       = os.environ.get('_OPENAI_KEY', '')
sophia_account   = os.environ.get('_SOPHIA_ACCOUNT', '')
josh_account     = os.environ.get('_JOSH_ACCOUNT', '')
today            = os.environ.get('_TODAY', datetime.now().strftime('%Y-%m-%d'))

seen = set()
if seen_file and os.path.exists(seen_file):
    seen = set(open(seen_file).read().split())
seen_sophia = set()
if seen_sophia_file and os.path.exists(seen_sophia_file):
    seen_sophia = set(open(seen_sophia_file).read().split())

# ── Helpers ───────────────────────────────────────────────────────────────────

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
    sender  = (email.get('from', '') or '').lower()
    subject = (email.get('subject', '') or '').lower()
    return any(n in sender for n in NOISE_SENDERS) or any(n in subject for n in NOISE_SUBJECTS)

def send_wa(message):
    payload = json.dumps({'to': josh_number, 'message': message}).encode()
    req = urllib.request.Request(wa_api, data=payload,
        headers={'Content-Type': 'application/json'}, method='POST')
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f'WA send error: {e}')

def gpt(system, user, max_tokens=200, json_mode=False):
    if not openai_key:
        return None
    payload = {
        'model': 'gpt-4o-mini',
        'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}],
        'max_tokens': max_tokens,
        'temperature': 0,
    }
    if json_mode:
        payload['response_format'] = {'type': 'json_object'}
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=json.dumps(payload).encode(),
        headers={'Authorization': f'Bearer {openai_key}', 'Content-Type': 'application/json'},
        method='POST')
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f'GPT error: {e}')
        return None

def fetch_email_body(msg_id, account):
    """Fetch full message body via gog gmail get."""
    try:
        r = subprocess.run(
            ['gog', 'gmail', 'get', msg_id, '--account', account, '--json', '--results-only', '--no-input'],
            capture_output=True, text=True, timeout=15
        )
        if r.returncode != 0:
            return ''
        data = json.loads(r.stdout)
        body = data.get('body', '') or ''
        # Strip HTML tags
        body = re.sub(r'<[^>]+>', ' ', body)
        body = html.unescape(body)
        body = re.sub(r'\s+', ' ', body).strip()
        return body[:1000]
    except Exception as e:
        print(f'fetch_email_body error: {e}')
        return ''

def list_calendar_events(account, days=7):
    """Return list of upcoming calendar events."""
    try:
        r = subprocess.run(
            ['gog', 'calendar', 'events', 'primary', '--account', account,
             '--days', str(days), '--json', '--results-only', '--no-input'],
            capture_output=True, text=True, timeout=15
        )
        if r.returncode != 0:
            return []
        data = json.loads(r.stdout)
        if isinstance(data, list):
            return data
        return data.get('items', data.get('events', []))
    except Exception as e:
        print(f'list_calendar_events error: {e}')
        return []

def delete_calendar_event(event_id, account):
    try:
        r = subprocess.run(
            ['gog', 'calendar', 'delete', 'primary', event_id,
             '--account', account, '--force', '--no-input'],
            capture_output=True, text=True, timeout=15
        )
        return r.returncode == 0
    except Exception:
        return False

def create_calendar_event(account, summary, start_iso, end_iso, attendee_email):
    try:
        r = subprocess.run(
            ['gog', 'calendar', 'create', 'primary',
             '--account', account,
             '--summary', summary,
             '--from', start_iso,
             '--to', end_iso,
             '--attendees', attendee_email,
             '--send-updates', 'all',
             '--force', '--no-input'],
            capture_output=True, text=True, timeout=15
        )
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                if line.startswith('id\t'):
                    return line.split('\t')[1].strip()
        return None
    except Exception as e:
        print(f'create_calendar_event error: {e}')
        return None

def send_email_reply(account, to, subject, thread_id, body_html):
    try:
        subprocess.run(
            ['gog', 'gmail', 'send',
             '--account', account,
             '--to', to,
             '--subject', subject,
             '--thread-id', thread_id,
             '--body-html', body_html,
             '--force', '--no-input'],
            capture_output=True, text=True, timeout=15
        )
    except Exception as e:
        print(f'send_email_reply error: {e}')

# ── Section A: josh@ inbox — notify Josh about important emails ───────────────

def summarise_email(subject, sender, snippet):
    result = gpt(
        'Summarise this email in one short sentence (max 20 words). No filler. Just what it is about.',
        f'Subject: {subject}\nFrom: {sender}\nSnippet: {snippet}',
        max_tokens=60
    )
    return result or (snippet[:120] if snippet else '')

new_seen = []
alerts = []

for email in josh_emails_raw:
    eid = email.get('id', '') or email.get('threadId', '')
    if not eid or eid in seen:
        continue
    if is_noise(email):
        new_seen.append(eid)
        continue

    sender  = email.get('from', '') or email.get('sender', '') or 'Unknown'
    subject = email.get('subject', '') or '(No subject)'
    snippet = email.get('snippet', '') or email.get('body', '') or ''

    summary = summarise_email(subject, sender, snippet)
    sender_display = re.sub(r'\s*<[^>]+>', '', sender).strip() or sender
    alerts.append(f"\U0001f4e7 *{sender_display}*\n_{subject}_\n{summary}")
    new_seen.append(eid)

if alerts:
    msg = f"New email:\n\n{alerts[0]}" if len(alerts) == 1 else f"{len(alerts)} new emails:\n\n" + "\n\n".join(alerts)
    send_wa(msg)
    print(f"Alerted {len(alerts)} email(s)")
else:
    print("Josh inbox: nothing to alert")

if new_seen and seen_file:
    with open(seen_file, 'a') as f:
        f.write('\n'.join(new_seen) + '\n')
if seen_file and os.path.exists(seen_file):
    lines = open(seen_file).readlines()
    if len(lines) > 500:
        open(seen_file, 'w').writelines(lines[-500:])

# ── Section B: sophia@ inbox — detect and act on actionable replies ───────────

new_seen_sophia = []
calendar_actions_taken = 0

for email in sophia_emails_raw:
    eid       = email.get('id', '') or email.get('threadId', '')
    thread_id = email.get('threadId', '') or eid
    if not eid or eid in seen_sophia:
        continue

    sender  = email.get('from', '') or ''
    subject = email.get('subject', '') or ''

    # Skip noise and self-sent
    if is_noise(email) or 'sophia@amalfiai' in sender.lower():
        new_seen_sophia.append(eid)
        continue

    # Fetch the full reply body
    body = fetch_email_body(eid, sophia_account)
    if not body:
        new_seen_sophia.append(eid)
        continue

    sender_display = re.sub(r'\s*<[^>]+>', '', sender).strip() or sender
    sender_email   = re.search(r'<([^>]+)>', sender)
    sender_email   = sender_email.group(1) if sender_email else sender

    # Ask GPT to classify and extract action
    classification = gpt(
        '''You are an email action classifier for Sophia, an AI assistant at Amalfi AI.
Classify the email and return JSON only.

If the email is a reschedule confirmation (person agreeing to a new meeting time):
{"action": "reschedule", "person_name": "<first name>", "new_time_iso": "<YYYY-MM-DDTHH:MM:SS+02:00>", "reply": "<short friendly confirmation reply, 1-2 sentences>"}

If the email is a meeting acceptance or confirmation of an existing meeting:
{"action": "confirm_meeting", "person_name": "<first name>", "reply": "<short friendly reply>"}

If it is a general reply needing no calendar action:
{"action": "general", "summary": "<one sentence summary>"}

If it is noise/automated:
{"action": "noise"}

Today is ''' + today + '. SAST is UTC+2. If someone says "3pm today" or "3:00 today", resolve to today at 15:00+02:00.',
        f'From: {sender_display}\nSubject: {subject}\nBody: {body}',
        max_tokens=200,
        json_mode=True
    )

    try:
        result = json.loads(classification) if classification else {}
    except Exception:
        result = {'action': 'general', 'summary': body[:80]}

    action = result.get('action', 'general')
    print(f"sophia@ reply from {sender_display}: action={action}")

    if action == 'noise':
        new_seen_sophia.append(eid)
        continue

    elif action == 'reschedule':
        person_name  = result.get('person_name', sender_display)
        new_time_iso = result.get('new_time_iso', '')
        reply_text   = result.get('reply', f'Perfect, confirmed! See you then.')

        if not new_time_iso:
            # Couldn't parse time — alert Josh to handle manually
            send_wa(f"\U0001f4e7 Reply from *{sender_display}* about rescheduling — couldn't parse time. Check email.\n\n_{subject}_\n{body[:200]}")
            new_seen_sophia.append(eid)
            continue

        # Find matching calendar events for this person
        events = list_calendar_events(josh_account, days=14)
        matching = [
            e for e in events
            if person_name.lower() in (e.get('summary', '') or '').lower()
        ]

        deleted = []
        for e in matching:
            eid_cal = e.get('id', '')
            if eid_cal and delete_calendar_event(eid_cal, josh_account):
                deleted.append(e.get('summary', ''))
                print(f"Deleted calendar event: {e.get('summary','')} at {e.get('start',{}).get('dateTime','')}")

        # Parse end time (default 30 min)
        try:
            from datetime import timedelta
            dt_start = datetime.fromisoformat(new_time_iso)
            dt_end   = dt_start + timedelta(minutes=30)
            end_iso  = dt_end.isoformat()
        except Exception:
            end_iso = new_time_iso

        new_event_id = create_calendar_event(
            josh_account,
            f'Meeting with {person_name}',
            new_time_iso,
            end_iso,
            sender_email
        )

        # Format time for messages
        try:
            dt = datetime.fromisoformat(new_time_iso)
            time_display = dt.strftime('%I:%M%p').lstrip('0').lower() + ' SAST'
        except Exception:
            time_display = new_time_iso

        # Reply to the client confirming
        reply_html = f'<p>{reply_text}</p><p>Warm regards,<br>Sophia<br>Amalfi AI</p>'
        send_email_reply(sophia_account, sender_email, f'Re: {subject}', thread_id, reply_html)

        # Notify Josh
        deleted_str = f" (removed old: {', '.join(deleted)})" if deleted else ''
        send_wa(
            f"\U0001f4c5 *Rescheduled automatically*\n"
            f"Meeting with {person_name} confirmed for *{time_display}*{deleted_str}\n"
            f"Calendar updated. Reply sent to {sender_display}."
        )
        calendar_actions_taken += 1

    elif action == 'confirm_meeting':
        person_name = result.get('person_name', sender_display)
        reply_text  = result.get('reply', 'Great, looking forward to it!')
        reply_html  = f'<p>{reply_text}</p><p>Warm regards,<br>Sophia<br>Amalfi AI</p>'
        send_email_reply(sophia_account, sender_email, f'Re: {subject}', thread_id, reply_html)
        send_wa(f"\u2705 *{sender_display}* confirmed the meeting. Reply sent.")
        calendar_actions_taken += 1

    elif action == 'general':
        summary = result.get('summary', body[:120])
        send_wa(f"\U0001f4e7 Reply from *{sender_display}*\n_{subject}_\n{summary}")

    new_seen_sophia.append(eid)

if calendar_actions_taken > 0:
    print(f"Calendar actions taken: {calendar_actions_taken}")
else:
    print("Sophia inbox: no calendar actions needed")

if new_seen_sophia and seen_sophia_file:
    with open(seen_sophia_file, 'a') as f:
        f.write('\n'.join(new_seen_sophia) + '\n')
if seen_sophia_file and os.path.exists(seen_sophia_file):
    lines = open(seen_sophia_file).readlines()
    if len(lines) > 500:
        open(seen_sophia_file, 'w').writelines(lines[-500:])

PYWATCH

log "Done"
