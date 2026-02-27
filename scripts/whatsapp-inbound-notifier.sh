#!/usr/bin/env bash
# whatsapp-inbound-notifier.sh
# Polls Supabase whatsapp_messages for unnotified messages.
# Sends a Telegram alert to Josh for each new inbound WhatsApp message.
# Marks messages notified=true after sending.
# Runs every 5 min via LaunchAgent.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$ROOT/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
CONTACTS_FILE="$ROOT/data/contacts.json"

export SUPABASE_URL SERVICE_KEY BOT_TOKEN CHAT_ID CONTACTS_FILE

python3 - <<'PY'
import os, json, sys, datetime, urllib.request, urllib.parse

SUPABASE_URL  = os.environ['SUPABASE_URL']
SERVICE_KEY   = os.environ['SERVICE_KEY']
BOT_TOKEN     = os.environ['BOT_TOKEN']
CHAT_ID       = os.environ['CHAT_ID']
CONTACTS_FILE = os.environ['CONTACTS_FILE']

# ── Load contacts map (slug → name) ──────────────────────────────────────────
contact_name_map = {}  # slug → display name
contact_slug_map = {}  # e164 number → slug

try:
    with open(CONTACTS_FILE) as f:
        cdata = json.load(f)
    for c in cdata.get('clients', []):
        slug = c.get('slug', '')
        name = c.get('name', slug)
        num  = c.get('number', '').replace(' ', '')
        if slug:
            contact_name_map[slug] = name
        if num:
            # Normalize: ensure + prefix, strip spaces
            if not num.startswith('+'):
                num = '+' + num
            contact_slug_map[num] = slug
except Exception as e:
    print(f'[wa-notifier] Warning: could not load contacts: {e}', file=sys.stderr)

# ── Helpers ───────────────────────────────────────────────────────────────────

class TableNotFoundError(Exception):
    pass

def supa_get(path, params=None):
    import urllib.error
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    if params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Accept': 'application/json',
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            try:
                body = json.loads(e.read())
                if body.get('code') == 'PGRST205':
                    raise TableNotFoundError(path)
            except (json.JSONDecodeError, AttributeError):
                pass
        raise

def supa_patch(path, params, body):
    url = f"{SUPABASE_URL}/rest/v1/{path}?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method='PATCH', headers={
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status in (200, 204)
    except Exception as e:
        print(f'[wa-notifier] WARN patch failed: {e}', file=sys.stderr)
        return False

def tg_send(text, markup=None):
    payload = {
        'chat_id': CHAT_ID,
        'text': text,
        'parse_mode': 'HTML',
    }
    if markup:
        payload['reply_markup'] = markup
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        data=data,
        headers={'Content-Type': 'application/json'},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f'[wa-notifier] Telegram send failed: {e}', file=sys.stderr)
        return None

def friendly_time(ts_str):
    """Format ISO timestamp as human-friendly SAST time."""
    try:
        SAST = datetime.timezone(datetime.timedelta(hours=2))
        ts = datetime.datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
        ts_sast = ts.astimezone(SAST)
        now = datetime.datetime.now(SAST)
        if ts_sast.date() == now.date():
            return ts_sast.strftime('%H:%M SAST')
        return ts_sast.strftime('%a %d %b, %H:%M SAST')
    except Exception:
        return ts_str

# ── Fetch unnotified messages ─────────────────────────────────────────────────
try:
    msgs = supa_get('whatsapp_messages', {
        'notified': 'eq.false',
        'order': 'received_at.asc',
        'select': 'id,message_id,from_number,from_name,contact_slug,contact_name,message_type,body,timestamp_wa',
    })
except TableNotFoundError:
    # Table not yet created — WhatsApp setup incomplete, skip silently
    sys.exit(0)
except Exception as e:
    print(f'[wa-notifier] Supabase fetch error: {e}', file=sys.stderr)
    sys.exit(0)

if not msgs:
    sys.exit(0)

sent = 0
for msg in msgs:
    row_id       = msg['id']
    from_num     = msg.get('from_number', '')
    from_name    = msg.get('from_name') or ''
    contact_slug = msg.get('contact_slug') or contact_slug_map.get(from_num, '')
    contact_name = msg.get('contact_name') or contact_name_map.get(contact_slug, '') or from_name or from_num
    msg_type     = msg.get('message_type', 'text')
    body         = msg.get('body') or ''
    ts           = msg.get('timestamp_wa') or msg.get('received_at') or ''

    time_str = friendly_time(ts)

    # Build display name
    if contact_name and contact_name != from_num:
        display = f"{contact_name} ({from_num})"
    else:
        display = from_num

    # Truncate long messages in Telegram preview
    preview = body[:300] + '...' if len(body) > 300 else body
    if not preview:
        preview = f'[{msg_type}]'

    tg_text = (
        f'📱 <b>WhatsApp from {display}</b>\n'
        f'{preview}\n\n'
        f'⏰ {time_str}'
    )

    # Inline keyboard: Reply via /reply wa, or dismiss
    reply_cmd = f'/reply wa {contact_slug or from_num} '
    markup = {
        'inline_keyboard': [[
            {'text': '↩️ Reply', 'switch_inline_query_current_chat': reply_cmd},
            {'text': '✅ Dismiss', 'callback_data': f'wa_dismiss:{row_id}'},
        ]]
    }

    result = tg_send(tg_text, markup)
    if result and result.get('ok'):
        # Mark notified
        supa_patch('whatsapp_messages', {'id': f'eq.{row_id}'}, {
            'notified': True,
            'notified_at': datetime.datetime.utcnow().isoformat() + 'Z',
        })
        sent += 1
        print(f'[wa-notifier] Notified: {display} — "{body[:60]}"')
    else:
        print(f'[wa-notifier] Telegram send failed for {row_id}', file=sys.stderr)

if sent:
    print(f'[wa-notifier] {sent} notification(s) sent')
PY
