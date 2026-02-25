#!/usr/bin/env bash
# reminder-poller.sh
# Fires Telegram alerts for reminders due within the next 15 minutes.
# Runs every 5 minutes via LaunchAgent.
# Deduplicates: won't re-send within 10 min of last send.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$ROOT/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="1140320036"

export SUPABASE_URL SERVICE_KEY BOT_TOKEN CHAT_ID

python3 - <<'PY'
import os, json, sys, requests, datetime

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SERVICE_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']

SAST         = datetime.timezone(datetime.timedelta(hours=2))
now          = datetime.datetime.now(SAST)
window_end   = now + datetime.timedelta(minutes=15)
resend_gap   = datetime.timedelta(minutes=10)  # min gap between re-alerts
stale_cutoff = datetime.timedelta(minutes=60)  # don't fire if >60min overdue

def tg_send(text, markup=None):
    payload = {'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}
    if markup:
        payload['reply_markup'] = markup
    try:
        requests.post(
            f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
            json=payload, timeout=10
        )
    except Exception:
        pass

def supa_patch(rid, body):
    requests.patch(
        f"{SUPABASE_URL}/rest/v1/notifications?id=eq.{rid}",
        headers={
            'apikey': KEY, 'Authorization': f'Bearer {KEY}',
            'Content-Type': 'application/json', 'Prefer': 'return=minimal',
        },
        json=body, timeout=10
    )

# Fetch all unread reminders
resp = requests.get(
    f"{SUPABASE_URL}/rest/v1/notifications",
    params={'type': 'eq.reminder', 'status': 'eq.unread',
            'select': 'id,title,body,metadata,priority'},
    headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'},
    timeout=20
)
if resp.status_code != 200:
    print(f"[reminder-poller] Supabase error {resp.status_code}: {resp.text[:200]}", file=sys.stderr)
    raise SystemExit(0)
reminders = resp.json()

fired = 0
for rem in reminders:
    rid   = rem['id']
    title = rem.get('title') or 'Reminder'
    body  = rem.get('body') or ''
    meta  = rem.get('metadata') or {}
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except Exception:
            meta = {}

    due_str = meta.get('due')
    if not due_str:
        continue  # no due time set — skip

    # Parse due
    try:
        due = datetime.datetime.fromisoformat(due_str)
        if due.tzinfo is None:
            due = due.replace(tzinfo=datetime.timezone.utc)
        due = due.astimezone(SAST)
    except Exception:
        continue

    # Window: not more than 60 min overdue, and not more than 15 min in future
    if not (now - stale_cutoff <= due <= window_end):
        continue

    # Dedup: don't re-alert within 10 min of last send
    last_sent_str = meta.get('last_sent_at')
    if last_sent_str:
        try:
            last_sent = datetime.datetime.fromisoformat(last_sent_str)
            if last_sent.tzinfo is None:
                last_sent = last_sent.replace(tzinfo=datetime.timezone.utc)
            last_sent = last_sent.astimezone(SAST)
            if now - last_sent < resend_gap:
                continue
        except Exception:
            pass

    # Format due time
    if due.date() == now.date():
        due_display = due.strftime('%H:%M SAST')
    else:
        due_display = due.strftime('%a %d %b, %H:%M SAST')

    msg = f'🔔 <b>{title}</b>'
    if body:
        msg += f'\n{body}'
    msg += f'\n\n⏰ {due_display}'

    markup = {
        'inline_keyboard': [[
            {'text': '✅ Done',        'callback_data': f'remind_done:{rid}'},
            {'text': '⏱ Snooze 15min', 'callback_data': f'remind_snooze:{rid}'},
        ]]
    }
    tg_send(msg, markup)

    # Record last_sent_at so we don't spam
    meta['last_sent_at'] = now.isoformat()
    supa_patch(rid, {'metadata': meta})

    fired += 1
    print(f'Fired: {title} (due {due_display})')

if fired > 0:
    print(f'reminder-poller: {fired} reminder(s) sent')
PY
