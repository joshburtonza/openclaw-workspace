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

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"

export SUPABASE_URL SERVICE_KEY BOT_TOKEN CHAT_ID

python3 - <<'PY'
import os, json, sys, requests, datetime

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SERVICE_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']

SAST           = datetime.timezone(datetime.timedelta(hours=2))
now            = datetime.datetime.now(SAST)
window_end     = now + datetime.timedelta(minutes=15)
stale_cutoff   = datetime.timedelta(minutes=60)  # don't fire if >60min overdue
auto_dismiss_h = datetime.timedelta(hours=4)     # auto-dismiss if >4h overdue and unread

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
    try:
        r = requests.patch(
            f"{SUPABASE_URL}/rest/v1/notifications?id=eq.{rid}",
            headers={
                'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                'Content-Type': 'application/json', 'Prefer': 'return=minimal',
            },
            json=body, timeout=10
        )
    except requests.exceptions.RequestException as e:
        print(f'[reminder-poller] WARN: patch network error for {rid}: {type(e).__name__}', file=sys.stdout)
        return False
    if r.status_code not in (200, 204):
        print(f'[reminder-poller] WARN: patch failed for {rid}: HTTP {r.status_code} {r.text[:500]}', file=sys.stderr)
        return False
    return True

# Fetch all unread reminders
try:
    resp = requests.get(
        f"{SUPABASE_URL}/rest/v1/notifications",
        params={'type': 'eq.reminder', 'status': 'eq.unread',
                'select': 'id,title,body,metadata,priority'},
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'},
        timeout=20
    )
except requests.exceptions.RequestException as e:
    print(f"[reminder-poller] Network error, skipping: {type(e).__name__}", file=sys.stdout)
    raise SystemExit(0)
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

    overdue = now - due

    # Auto-dismiss reminders that are very overdue — they were clearly missed
    if overdue > auto_dismiss_h:
        supa_patch(rid, {'status': 'read'})
        print(f'Auto-dismissed stale reminder: {title} ({int(overdue.total_seconds()//3600)}h overdue)')
        continue

    # Window: not more than 60 min overdue, and not more than 15 min in future
    if not (now - stale_cutoff <= due <= window_end):
        continue

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

    # Mark as 'read' so this reminder is never fired again.
    # The DB constraint (notifications_status_check) only allows unread→read directly;
    # dismissed/sent require intermediate state so 'read' is the safe post-fire status.
    ok = supa_patch(rid, {'status': 'read'})
    if not ok:
        print(f'[reminder-poller] ERROR: failed to mark {rid} read — will re-fire next run', file=sys.stderr)

    fired += 1
    print(f'Fired: {title} (due {due_display})')

if fired > 0:
    print(f'reminder-poller: {fired} reminder(s) sent')
PY
