#!/bin/bash
# telegram-callback-poller.sh
# Poll Telegram getUpdates for:
#   - Inline button callbacks (approve/hold/adjust email drafts)
#   - Text commands:
#       /newlead [first] [last] <email> [company]  → insert into leads table
#       /ooo [reason]                               → set Sophia OOO mode
#       /available                                  → clear Sophia OOO mode
# Keeps state in a stable file (NOT /tmp — that resets between isolated sessions).

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
ANON_KEY="${SUPABASE_ANON_KEY:-}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

# Use workspace dir so offset survives between isolated OpenClaw sessions
OFFSET_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/telegram_updates_offset"
mkdir -p "$(dirname "$OFFSET_FILE")"
OFFSET=""
if [[ -f "$OFFSET_FILE" ]]; then
  OFFSET=$(cat "$OFFSET_FILE" || true)
fi

URL="https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?timeout=0"
if [[ -n "$OFFSET" ]]; then
  URL+="&offset=${OFFSET}"
fi

RESP=$(curl -s "$URL")
export RESP OFFSET_FILE BOT_TOKEN SUPABASE_URL ANON_KEY SERVICE_KEY

python3 - <<'PY'
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

        if action not in ('approve', 'hold', 'adjust'):
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

        continue  # done with this update

    # ── Text message (commands) ───────────────────────────────────────────────
    msg = u.get('message') or u.get('edited_message')
    if not msg:
        continue

    text    = (msg.get('text') or '').strip()
    chat_id = ((msg.get('chat') or {}).get('id'))

    if not text or not chat_id:
        continue

    text_lower = text.lower()

    if text_lower.startswith('/newlead'):
        handle_newlead(chat_id, text)

    elif text_lower.startswith('/ooo'):
        handle_ooo(chat_id, text)

    elif text_lower.startswith('/available'):
        handle_available(chat_id)

    elif text_lower.startswith('/help') or text_lower == '/start':
        handle_help(chat_id)

    # Check for pending adjust reply, then fall through to Claude gateway
    else:
        pending_file = f"/Users/henryburton/.openclaw/workspace-anthropic/tmp/telegram_pending_adjust_{chat_id}"
        if os.path.exists(pending_file):
            try:
                with open(pending_file) as f:
                    email_id = f.read().strip()
                os.remove(pending_file)
                # Pass adjust request to Claude gateway for real regeneration
                subprocess.Popen([
                    'bash',
                    '/Users/henryburton/.openclaw/workspace-anthropic/scripts/telegram-claude-gateway.sh',
                    str(chat_id),
                    f'Adjust the email draft for email_id={email_id}. The requested change: {text}',
                ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
        else:
            # Free-text message → route to Claude Code gateway
            subprocess.Popen([
                'bash',
                '/Users/henryburton/.openclaw/workspace-anthropic/scripts/telegram-claude-gateway.sh',
                str(chat_id),
                text,
            ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# advance offset
if max_update_id is not None:
    with open(os.environ['OFFSET_FILE'], 'w') as f:
        f.write(str(max_update_id + 1))
PY
