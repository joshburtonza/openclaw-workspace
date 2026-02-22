#!/bin/bash
# telegram-callback-poller.sh
# Continuous long-polling service for Telegram updates:
#   - Inline button callbacks (approve/hold/adjust email drafts)
#   - Text commands:
#       /newlead [first] [last] <email> [company]  → insert into leads table
#       /ooo [reason]                               → set Sophia OOO mode
#       /available                                  → clear Sophia OOO mode
#       /remind <time> <desc>                       → set a timed reminder
# Keeps state in a stable file (NOT /tmp — that resets between isolated sessions).
# Runs as a KeepAlive LaunchAgent — loops internally via long-polling (timeout=25s).

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
ANON_KEY="${SUPABASE_ANON_KEY:-}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

# Use workspace dir so offset survives between restarts
OFFSET_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/telegram_updates_offset"
mkdir -p "$(dirname "$OFFSET_FILE")"

JOSH_BOT_USERNAME="${JOSH_BOT_USERNAME:-JoshAmalfiBot}"
TG_API="https://api.telegram.org/bot${BOT_TOKEN}"

# ── Continuous long-polling loop ──────────────────────────────────────────────
while true; do

  # Read current offset each iteration (Python updates it after processing)
  OFFSET=""
  if [[ -f "$OFFSET_FILE" ]]; then
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || true)
  fi

  # Long-poll: timeout=25 — server holds connection until update arrives or 25s passes
  URL="${TG_API}/getUpdates?timeout=25&allowed_updates=message,callback_query"
  if [[ -n "$OFFSET" ]]; then
    URL+="&offset=${OFFSET}"
  fi

  # --max-time 35 gives a 10s buffer beyond the server's 25s hold
  RESP=$(curl -s --max-time 35 "$URL") || RESP=""

  if [[ -z "$RESP" ]]; then
    sleep 5
    continue
  fi

  export RESP OFFSET_FILE BOT_TOKEN SUPABASE_URL ANON_KEY SERVICE_KEY JOSH_BOT_USERNAME

  python3 - <<'PY' || true
import json, os, subprocess, sys, re
import requests

resp=json.loads(os.environ.get('RESP','{}'))
if not resp.get('ok'):
    print('Telegram getUpdates not ok', file=sys.stderr)
    sys.exit(0)

updates=resp.get('result', [])
if not updates:
    sys.exit(0)

max_update_id=None

SUPABASE_URL = os.environ['SUPABASE_URL']
ANON_KEY     = os.environ['ANON_KEY']
SERVICE_KEY  = os.environ['SERVICE_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']

def tg_send(chat_id, text):
    try:
        requests.post(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            json={'chat_id': chat_id, 'text': text, 'parse_mode': 'HTML'},
            timeout=10
        )
    except Exception:
        pass

def supa_patch_anon(path, body):
    subprocess.run([
        'curl','-s','-X','PATCH',
        f"{SUPABASE_URL}/rest/v1/{path}",
        '-H',f"apikey: {ANON_KEY}",
        '-H',f"Authorization: Bearer {ANON_KEY}",
        '-H','Content-Type: application/json',
        '-H','Prefer: return=minimal',
        '-d',json.dumps(body)
    ], stdout=subprocess.DEVNULL)

def supa_post_service(path, body):
    r = requests.post(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={
            'apikey': SERVICE_KEY,
            'Authorization': f'Bearer {SERVICE_KEY}',
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal',
        },
        json=body, timeout=15
    )
    return r.status_code, r.text

# ── Handle /newlead command ───────────────────────────────────────────────────
def handle_newlead(chat_id, text):
    """
    Formats accepted:
      /newlead John Smith john@example.com Acme Corp
      /newlead john@example.com Acme Corp
      /newlead John john@example.com
    """
    # Strip the command
    raw = re.sub(r'^/newlead\s*', '', text, flags=re.IGNORECASE).strip()
    if not raw:
        tg_send(chat_id,
            "📋 <b>Add a lead:</b>\n"
            "<code>/newlead FirstName LastName email@example.com Company Name</code>\n\n"
            "Examples:\n"
            "• /newlead Marcus Smith marcus@gallery.com The Gallery\n"
            "• /newlead sarah@startup.co Startup Inc"
        )
        return

    # Extract email
    email_match = re.search(r'[\w.+-]+@[\w-]+\.[a-z]{2,}', raw, re.IGNORECASE)
    if not email_match:
        tg_send(chat_id, "❌ No valid email found. Include an email address.")
        return

    email = email_match.group(0).lower()
    rest  = raw.replace(email, '').strip()

    # Split remaining words into name parts + company
    words = rest.split()
    first_name = words[0].capitalize() if words else 'Unknown'
    last_name  = words[1].capitalize() if len(words) > 1 else None
    company    = ' '.join(words[2:]) if len(words) > 2 else None

    # If only one word before email and it looks like a company, treat it as company
    if company is None and last_name and not re.match(r'^[A-Z][a-z]+$', last_name):
        company = last_name
        last_name = None

    payload = {
        'first_name': first_name,
        'last_name':  last_name,
        'email':      email,
        'company':    company,
        'source':     'telegram',
        'status':     'new',
        'assigned_to': 'Josh',
    }

    status_code, resp_text = supa_post_service('leads', payload)

    if status_code in (200, 201, 204):
        name_display = ' '.join(filter(None, [first_name, last_name]))
        tg_send(chat_id,
            f"✅ <b>Lead added!</b>\n"
            f"<b>{name_display}</b> @ {company or 'unknown company'}\n"
            f"<code>{email}</code>\n\n"
            f"Visible in Mission Control → Content → Cold Outreach."
        )
    elif status_code == 409 or 'unique' in resp_text.lower():
        tg_send(chat_id, f"⚠️ Lead with email <code>{email}</code> already exists.")
    else:
        tg_send(chat_id, f"❌ Failed to add lead (HTTP {status_code}). Check logs.")

# ── Handle /ooo command ───────────────────────────────────────────────────────
def handle_ooo(chat_id, text):
    reason = re.sub(r'^/ooo\s*', '', text, flags=re.IGNORECASE).strip()
    if not reason:
        reason = "OOO — no reason specified"
    result = subprocess.run(
        ['bash',
         '/Users/henryburton/.openclaw/workspace-anthropic/scripts/sophia-ooo-set.sh',
         'set', reason],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        tg_send(chat_id, f"⏸ <b>OOO mode ON</b>\nReason: {reason}\n\nSophia is holding all drafts.")
    else:
        tg_send(chat_id, f"❌ Failed to set OOO: {result.stderr[:200]}")

# ── Handle /available command ─────────────────────────────────────────────────
def handle_available(chat_id):
    result = subprocess.run(
        ['bash',
         '/Users/henryburton/.openclaw/workspace-anthropic/scripts/sophia-ooo-set.sh',
         'clear'],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        tg_send(chat_id, "✅ <b>OOO mode OFF</b>\nSophia is back to normal operations.")
    else:
        tg_send(chat_id, f"❌ Failed to clear OOO: {result.stderr[:200]}")

# ── Handle /remind command ────────────────────────────────────────────────────
def handle_remind(chat_id, text):
    """
    Formats:
      /remind 30min Call Riaan
      /remind 1h Send invoice
      /remind 3pm Team sync
      /remind 15:30 Review PR
      /remind tomorrow 9am Send weekly report
    """
    import datetime as _dt, re as _re

    raw = _re.sub(r'^/remind\s*', '', text, flags=_re.IGNORECASE).strip()
    if not raw:
        tg_send(chat_id,
            "⏰ <b>Set a reminder:</b>\n\n"
            "/remind 30min Description\n"
            "/remind 2h Description\n"
            "/remind 3pm Description\n"
            "/remind 15:30 Description\n"
            "/remind tomorrow 9am Description"
        )
        return

    SAST = _dt.timezone(_dt.timedelta(hours=2))
    now  = _dt.datetime.now(SAST)
    due  = None
    desc = raw

    # Pattern: Xmin text
    m = _re.match(r'^(\d+)\s*(?:min(?:ute)?s?|m)\s+(.+)$', raw, _re.IGNORECASE)
    if m:
        due  = now + _dt.timedelta(minutes=int(m.group(1)))
        desc = m.group(2).strip()

    # Pattern: Xh / X hours text
    if not due:
        m = _re.match(r'^(\d+)\s*(?:hour(?:s)?|h(?:r)?)\s+(.+)$', raw, _re.IGNORECASE)
        if m:
            due  = now + _dt.timedelta(hours=int(m.group(1)))
            desc = m.group(2).strip()

    # Pattern: HH:MM text  or  H:MM text
    if not due:
        m = _re.match(r'^(\d{1,2}):(\d{2})\s+(.+)$', raw)
        if m:
            hour, minute, rest = int(m.group(1)), int(m.group(2)), m.group(3)
            due = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if due <= now:
                due += _dt.timedelta(days=1)
            desc = rest.strip()

    # Pattern: Ham/pm or Hpm text  (e.g. 3pm, 9am, 10pm)
    if not due:
        m = _re.match(r'^(\d{1,2})\s*(am|pm)\s+(.+)$', raw, _re.IGNORECASE)
        if m:
            hour, ampm, rest = int(m.group(1)), m.group(2).lower(), m.group(3)
            if ampm == 'pm' and hour != 12:
                hour += 12
            elif ampm == 'am' and hour == 12:
                hour = 0
            due = now.replace(hour=hour, minute=0, second=0, microsecond=0)
            if due <= now:
                due += _dt.timedelta(days=1)
            desc = rest.strip()

    # Pattern: tomorrow HAM/PM text  or  tomorrow HH:MM text
    if not due:
        m = _re.match(r'^tomorrow\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.+)$', raw, _re.IGNORECASE)
        if m:
            hour, minute = int(m.group(1)), int(m.group(2) or 0)
            ampm, rest   = m.group(3), m.group(4)
            if ampm:
                if ampm.lower() == 'pm' and hour != 12: hour += 12
                elif ampm.lower() == 'am' and hour == 12: hour = 0
            tmrw = now + _dt.timedelta(days=1)
            due  = tmrw.replace(hour=hour, minute=minute, second=0, microsecond=0)
            desc = rest.strip()

    if not due:
        tg_send(chat_id,
            f"❌ Couldn't parse the time from: <code>{raw[:80]}</code>\n\n"
            "Try: /remind 30min Call Riaan\n"
            "Or:  /remind 3pm Team sync"
        )
        return

    # Insert into Supabase notifications
    payload = {
        'type':     'reminder',
        'title':    desc,
        'status':   'unread',
        'priority': 'normal',
        'agent':    'Josh',
        'metadata': {'due': due.isoformat()},
    }
    try:
        r = requests.post(
            f"{SUPABASE_URL}/rest/v1/notifications",
            headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                     'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
            json=payload, timeout=15
        )
        if r.status_code in (200, 201, 204):
            if due.date() == now.date():
                due_display = due.strftime('%H:%M SAST')
            else:
                due_display = due.strftime('%a %d %b, %H:%M SAST')
            tg_send(chat_id, f'✅ Reminder set: <b>{desc}</b>\n⏰ {due_display}')
        else:
            tg_send(chat_id, f'❌ Failed to save reminder (HTTP {r.status_code})')
    except Exception as e:
        tg_send(chat_id, f'❌ Error saving reminder: {e}')

# ── Handle /help command ──────────────────────────────────────────────────────
def handle_help(chat_id):
    tg_send(chat_id,
        "<b>Amalfi AI — Claude Code</b>\n\n"
        "💬 <b>Just chat</b> — type anything, Claude will respond\n"
        "Examples:\n"
        "• \"What emails are pending approval?\"\n"
        "• \"Draft a follow-up for Riaan\"\n"
        "• \"Set me as OOO tomorrow\"\n"
        "• \"What did we push to QMS Guard this week?\"\n\n"
        "📋 <b>Commands</b>\n"
        "/remind 30min Description — set a reminder\n"
        "/remind 3pm Description\n"
        "/remind tomorrow 9am Description\n"
        "/newlead [Name] email@co.com [Company]\n"
        "/ooo [reason] — Sophia holds all drafts\n"
        "/available — Resume normal ops\n\n"
        "✅ <b>Email approvals</b> — tap the buttons on cards"
    )

# ── Main loop ─────────────────────────────────────────────────────────────────
for u in updates:
    uid = u.get('update_id')
    if uid is not None:
        max_update_id = max(max_update_id or uid, uid)

    # ── Callback query (button taps) ──────────────────────────────────────────
    cq = u.get('callback_query')
    if cq:
        data    = cq.get('data','')
        cb_id   = cq.get('id')
        msg     = cq.get('message') or {}
        chat_id = ((msg.get('chat') or {}).get('id'))

        # Ack quickly so Telegram UI stops spinning
        if cb_id:
            try:
                requests.post(
                    f"https://api.telegram.org/bot{BOT_TOKEN}/answerCallbackQuery",
                    json={'callback_query_id': cb_id},
                    timeout=5
                )
            except Exception:
                pass

        try:
            action, email_id = data.split(':', 1)
        except ValueError:
            continue

        if action not in ('approve', 'hold', 'adjust', 'remind_done', 'remind_snooze'):
            continue

        if action == 'approve':
            supa_patch_anon(f"email_queue?id=eq.{email_id}", {'status': 'approved'})
            if chat_id:
                tg_send(chat_id, '✅ Approved. Scheduler will send shortly.')

        elif action == 'hold':
            supa_patch_anon(f"email_queue?id=eq.{email_id}", {'status': 'awaiting_approval'})
            if chat_id:
                tg_send(chat_id, '⏸ Held. Still awaiting approval. You can hit Adjust later.')

        elif action == 'adjust':
            if chat_id:
                pending_file = f"/Users/henryburton/.openclaw/workspace-anthropic/tmp/telegram_pending_adjust_{chat_id}"
                with open(pending_file, 'w') as f:
                    f.write(email_id)
                tg_send(chat_id, '✏️ Cool. Reply in this chat with how you want me to adjust the draft.')

        elif action == 'remind_done':
            # Mark reminder dismissed
            requests.patch(
                f"{SUPABASE_URL}/rest/v1/notifications?id=eq.{email_id}",
                headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                         'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                json={'status': 'dismissed'}, timeout=10
            )
            if chat_id:
                tg_send(chat_id, '✅ Reminder done!')

        elif action == 'remind_snooze':
            # Snooze 15 min — update due time, clear last_sent_at
            import datetime as _dt
            SAST = _dt.timezone(_dt.timedelta(hours=2))
            snooze_until = (_dt.datetime.now(SAST) + _dt.timedelta(minutes=15)).isoformat()
            # Get current metadata
            try:
                resp = requests.get(
                    f"{SUPABASE_URL}/rest/v1/notifications?id=eq.{email_id}&select=metadata",
                    headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'},
                    timeout=10
                )
                rows = resp.json()
                meta = (rows[0].get('metadata') or {}) if rows else {}
                if isinstance(meta, str):
                    import json as _json
                    try: meta = _json.loads(meta)
                    except Exception: meta = {}
                meta['due'] = snooze_until
                meta['last_sent_at'] = None
                requests.patch(
                    f"{SUPABASE_URL}/rest/v1/notifications?id=eq.{email_id}",
                    headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                             'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                    json={'metadata': meta}, timeout=10
                )
            except Exception:
                pass
            if chat_id:
                tg_send(chat_id, '⏱ Snoozed 15 minutes.')

        continue  # done with this update

    # ── Text message (commands) ───────────────────────────────────────────────
    msg = u.get('message') or u.get('edited_message')
    if not msg:
        continue

    text    = (msg.get('text') or '').strip()
    chat_id = ((msg.get('chat') or {}).get('id'))
    chat_type = (msg.get('chat') or {}).get('type', 'private')  # private/group/supergroup

    if not text or not chat_id:
        continue

    is_group = chat_type in ('group', 'supergroup')
    JOSH_BOT_USERNAME = os.environ.get('JOSH_BOT_USERNAME', 'JoshAmalfiBot')
    WS = '/Users/henryburton/.openclaw/workspace-anthropic'

    # ── Private chat: persist chat_id so proactive scripts can reach Josh ────
    if not is_group:
        try:
            with open(f"{WS}/tmp/josh_private_chat_id", 'w') as _cf:
                _cf.write(str(chat_id))
        except Exception:
            pass

    # ── Group chat: log ALL messages to shared history ────────────────────────
    if is_group:
        import datetime as _dt
        sender = msg.get('from') or {}
        sender_name = sender.get('username') or sender.get('first_name') or 'Unknown'
        is_bot_msg  = sender.get('is_bot', False)

        group_history_file = f"{WS}/tmp/group-{chat_id}.jsonl"
        try:
            with open(group_history_file, 'a') as gf:
                import json as _json
                gf.write(_json.dumps({
                    'ts': _dt.datetime.utcnow().strftime('%H:%M'),
                    'role': sender_name,
                    'is_bot': is_bot_msg,
                    'message': text,
                }) + '\n')
            # Keep last 100 lines
            with open(group_history_file) as gf:
                lines = gf.readlines()
            if len(lines) > 100:
                with open(group_history_file, 'w') as gf:
                    gf.writelines(lines[-100:])
        except Exception:
            pass

        # Also write to Supabase so RaceTechnikAiBot (and any other bot) can read it
        try:
            import requests as _req
            _req.post(
                f"{SUPABASE_URL}/rest/v1/group_chat_history",
                headers={
                    'apikey': SERVICE_KEY,
                    'Authorization': f'Bearer {SERVICE_KEY}',
                    'Content-Type': 'application/json',
                    'Prefer': 'return=minimal',
                },
                json={
                    'chat_id': str(chat_id),
                    'sender': sender_name,
                    'is_bot': is_bot_msg,
                    'message': text,
                },
                timeout=5
            )
        except Exception:
            pass

        # Only respond if @mentioned — skip commands that aren't for us
        mention = f'@{JOSH_BOT_USERNAME}'
        if mention.lower() not in text.lower():
            continue  # log only, don't respond

    # ── Commands (work in both private and group chats) ───────────────────────
    text_lower = text.lower()

    if text_lower.startswith('/remind'):
        handle_remind(chat_id, text)

    elif text_lower.startswith('/newlead'):
        handle_newlead(chat_id, text)

    elif text_lower.startswith('/ooo'):
        handle_ooo(chat_id, text)

    elif text_lower.startswith('/available'):
        handle_available(chat_id)

    elif text_lower.startswith('/help') or text_lower == '/start':
        handle_help(chat_id)

    # Free-text → Claude gateway
    else:
        group_history_file = f"{WS}/tmp/group-{chat_id}.jsonl" if is_group else ''
        pending_file = f"{WS}/tmp/telegram_pending_adjust_{chat_id}"
        if os.path.exists(pending_file):
            try:
                with open(pending_file) as f:
                    email_id = f.read().strip()
                os.remove(pending_file)
                subprocess.Popen([
                    'bash',
                    f'{WS}/scripts/telegram-claude-gateway.sh',
                    str(chat_id),
                    f'Adjust the email draft for email_id={email_id}. The requested change: {text}',
                    group_history_file,
                ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
        else:
            subprocess.Popen([
                'bash',
                f'{WS}/scripts/telegram-claude-gateway.sh',
                str(chat_id),
                text,
                group_history_file,
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# advance offset
if max_update_id is not None:
    with open(os.environ['OFFSET_FILE'], 'w') as f:
        f.write(str(max_update_id + 1))
PY

done
