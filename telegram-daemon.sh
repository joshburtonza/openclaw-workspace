#!/bin/bash
# telegram-daemon.sh
# Persistent long-poll Telegram bot daemon.
# Uses getUpdates?timeout=25 — Telegram holds the connection and returns the
# instant a message arrives. Same real-time responsiveness as OpenClaw.
#
# Run as a KeepAlive LaunchAgent — auto-restarts on crash.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
ANON_KEY="${SUPABASE_ANON_KEY:-}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
OFFSET_FILE="$WS/tmp/telegram_updates_offset"
mkdir -p "$WS/tmp"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Telegram daemon started"

OFFSET=""
if [[ -f "$OFFSET_FILE" ]]; then
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || true)
fi

export BOT_TOKEN SUPABASE_URL ANON_KEY SERVICE_KEY OFFSET_FILE WS

while true; do
  # Long-poll: blocks up to 25s, returns instantly when a message arrives
  URL="https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=25&limit=10"
  [[ -n "$OFFSET" ]] && URL="${URL}&offset=${OFFSET}"

  RESP=$(curl -s --max-time 30 "$URL" 2>/dev/null || true)

  if [[ -z "$RESP" ]]; then
    sleep 2
    continue
  fi

  NEW_OFFSET=$(RESP="$RESP" python3 - <<'PY'
import json, os, subprocess, sys, re

RESP         = os.environ['RESP']
BOT_TOKEN    = os.environ['BOT_TOKEN']
SUPABASE_URL = os.environ['SUPABASE_URL']
ANON_KEY     = os.environ['ANON_KEY']
SERVICE_KEY  = os.environ['SERVICE_KEY']
OFFSET_FILE  = os.environ['OFFSET_FILE']
WS           = os.environ['WS']

try:
    resp = json.loads(RESP)
except Exception:
    sys.exit(0)

if not resp.get('ok'):
    sys.exit(0)

updates = resp.get('result', [])
if not updates:
    sys.exit(0)

max_update_id = None

def tg_send(chat_id, text, parse_mode='HTML'):
    try:
        subprocess.run([
            'curl','-s','-X','POST',
            f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
            '-H','Content-Type: application/json',
            '-d', json.dumps({'chat_id': chat_id, 'text': text, 'parse_mode': parse_mode}),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        pass

def tg_ack(cb_id):
    try:
        subprocess.run([
            'curl','-s','-X','POST',
            f'https://api.telegram.org/bot{BOT_TOKEN}/answerCallbackQuery',
            '-H','Content-Type: application/json',
            '-d', json.dumps({'callback_query_id': cb_id}),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        pass

def supa_patch(path, body):
    subprocess.run([
        'curl','-s','-X','PATCH',
        f'{SUPABASE_URL}/rest/v1/{path}',
        '-H', f'apikey: {ANON_KEY}',
        '-H', f'Authorization: Bearer {ANON_KEY}',
        '-H','Content-Type: application/json',
        '-H','Prefer: return=minimal',
        '-d', json.dumps(body),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def supa_post(path, body):
    import requests
    r = requests.post(
        f'{SUPABASE_URL}/rest/v1/{path}',
        headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
        json=body, timeout=15)
    return r.status_code, r.text

def gateway(chat_id, text):
    """Spawn Claude gateway non-blocking."""
    subprocess.Popen([
        'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
        str(chat_id), text,
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def handle_newlead(chat_id, text):
    raw = re.sub(r'^/newlead\s*', '', text, flags=re.IGNORECASE).strip()
    if not raw:
        tg_send(chat_id, "📋 <b>Add a lead:</b>\n<code>/newlead FirstName LastName email@example.com Company</code>")
        return
    email_match = re.search(r'[\w.+-]+@[\w-]+\.[a-z]{2,}', raw, re.IGNORECASE)
    if not email_match:
        tg_send(chat_id, "❌ No valid email found. Include an email address.")
        return
    email = email_match.group(0).lower()
    rest  = raw.replace(email, '').strip()
    words = rest.split()
    first_name = words[0].capitalize() if words else 'Unknown'
    last_name  = words[1].capitalize() if len(words) > 1 else None
    company    = ' '.join(words[2:]) if len(words) > 2 else None
    payload = {'first_name': first_name, 'last_name': last_name, 'email': email,
                'company': company, 'source': 'telegram', 'status': 'new', 'assigned_to': 'Josh'}
    status_code, resp_text = supa_post('leads', payload)
    if status_code in (200, 201, 204):
        name = f"{first_name} {last_name or ''}".strip()
        tg_send(chat_id, f"✅ <b>Lead added:</b> {name} — <code>{email}</code>")
    elif 'unique' in resp_text.lower():
        tg_send(chat_id, f"⚠️ Lead <code>{email}</code> already exists.")
    else:
        tg_send(chat_id, f"❌ Failed (HTTP {status_code})")

def handle_ooo(chat_id, text):
    reason = re.sub(r'^/ooo\s*', '', text, flags=re.IGNORECASE).strip() or 'OOO'
    result = subprocess.run(['bash', f'{WS}/scripts/sophia-ooo-set.sh', 'set', reason],
                            capture_output=True, text=True, timeout=30)
    if result.returncode == 0:
        tg_send(chat_id, f"⏸ <b>OOO mode ON</b>\nReason: {reason}\n\nSophia is holding all drafts.")
    else:
        tg_send(chat_id, f"❌ Failed: {result.stderr[:200]}")

def handle_available(chat_id):
    result = subprocess.run(['bash', f'{WS}/scripts/sophia-ooo-set.sh', 'clear'],
                            capture_output=True, text=True, timeout=30)
    if result.returncode == 0:
        tg_send(chat_id, "✅ <b>OOO mode OFF</b> — Sophia back to normal.")
    else:
        tg_send(chat_id, f"❌ Failed: {result.stderr[:200]}")

def handle_help(chat_id):
    tg_send(chat_id,
        "<b>Amalfi AI — Claude Code</b>\n\n"
        "💬 <b>Just chat</b> — type anything, I'll respond\n"
        "• \"What emails are pending approval?\"\n"
        "• \"Draft a follow-up for Riaan\"\n"
        "• \"What did we push to QMS Guard this week?\"\n\n"
        "📋 <b>Commands</b>\n"
        "/newlead [Name] email@co.com [Company]\n"
        "/ooo [reason] — Sophia holds all drafts\n"
        "/available — Resume normal ops\n\n"
        "✅ Email approvals — tap the buttons on cards"
    )

for u in updates:
    uid = u.get('update_id')
    if uid is not None:
        max_update_id = max(max_update_id or uid, uid)

    # ── Button callbacks ──────────────────────────────────────────────────
    cq = u.get('callback_query')
    if cq:
        data    = cq.get('data', '')
        cb_id   = cq.get('id')
        msg     = cq.get('message') or {}
        chat_id = ((msg.get('chat') or {}).get('id'))
        if cb_id:
            tg_ack(cb_id)
        try:
            action, email_id = data.split(':', 1)
        except ValueError:
            continue
        if action == 'approve':
            supa_patch(f'email_queue?id=eq.{email_id}', {'status': 'approved'})
            if chat_id:
                tg_send(chat_id, '✅ Approved. Scheduler will send shortly.')
        elif action == 'hold':
            supa_patch(f'email_queue?id=eq.{email_id}', {'status': 'awaiting_approval'})
            if chat_id:
                tg_send(chat_id, '⏸ Held.')
        elif action == 'adjust':
            if chat_id:
                with open(f'{WS}/tmp/telegram_pending_adjust_{chat_id}', 'w') as f:
                    f.write(email_id)
                tg_send(chat_id, '✏️ What change do you want to make to the draft?')
        continue

    # ── Text messages ─────────────────────────────────────────────────────
    msg = u.get('message') or u.get('edited_message')
    if not msg:
        continue
    text    = (msg.get('text') or '').strip()
    chat_id = ((msg.get('chat') or {}).get('id'))
    if not text or not chat_id:
        continue

    tl = text.lower()
    if tl.startswith('/newlead'):
        handle_newlead(chat_id, text)
    elif tl.startswith('/ooo'):
        handle_ooo(chat_id, text)
    elif tl.startswith('/available'):
        handle_available(chat_id)
    elif tl.startswith('/help') or tl == '/start':
        handle_help(chat_id)
    else:
        pending_file = f'{WS}/tmp/telegram_pending_adjust_{chat_id}'
        import os as _os
        if _os.path.exists(pending_file):
            with open(pending_file) as f:
                email_id = f.read().strip()
            _os.remove(pending_file)
            gateway(chat_id, f'Adjust email_id={email_id}. Change requested: {text}')
        else:
            gateway(chat_id, text)

if max_update_id is not None:
    next_offset = str(max_update_id + 1)
    with open(OFFSET_FILE, 'w') as f:
        f.write(next_offset)
    print(next_offset)
PY
  )

  [[ -n "$NEW_OFFSET" ]] && OFFSET="$NEW_OFFSET"
done
