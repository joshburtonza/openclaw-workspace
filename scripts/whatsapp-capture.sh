#!/usr/bin/env bash
# whatsapp-capture.sh — nightly WhatsApp inbox capture
#
# PRIMARY source: Supabase whatsapp_messages table (written by whatsapp-webhook Edge Function).
# FALLBACK source: data/whatsapp-messages.jsonl (legacy local file).
# Writes a markdown summary to data/whatsapp-inbox.md for morning-brief.sh.
# Marks messages as read in Supabase and via WhatsApp Cloud API.
#
# Runs at 06:00 SAST via LaunchAgent — before morning-brief at 07:30 SAST.

set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CONTACTS_FILE="$WORKSPACE/data/contacts.json"
MESSAGES_LOG="$WORKSPACE/data/whatsapp-messages.jsonl"
INBOX_OUT="$WORKSPACE/data/whatsapp-inbox.md"
LOG="$WORKSPACE/out/whatsapp-capture.log"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
WHATSAPP_TOKEN="${WHATSAPP_TOKEN:-}"
WHATSAPP_PHONE_ID="${WHATSAPP_PHONE_ID:-}"

mkdir -p "$WORKSPACE/data" "$WORKSPACE/tmp"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") whatsapp-capture starting" | tee -a "$LOG"

export WORKSPACE SUPABASE_URL SERVICE_KEY CONTACTS_FILE MESSAGES_LOG INBOX_OUT

CAPTURE_RESULT=$(python3 - <<'PY'
import json, os, sys, datetime, re, urllib.request, urllib.parse
from pathlib import Path

SUPABASE_URL  = os.environ['SUPABASE_URL']
SERVICE_KEY   = os.environ['SERVICE_KEY']
CONTACTS_FILE = os.environ['CONTACTS_FILE']
MESSAGES_LOG  = os.environ['MESSAGES_LOG']
INBOX_OUT     = os.environ['INBOX_OUT']

# ── Load contacts map ─────────────────────────────────────────────────────────
try:
    with open(CONTACTS_FILE) as f:
        cdata = json.load(f)
    clients = cdata.get('clients', [])
except Exception as e:
    print(f'Warning: could not load contacts: {e}', file=sys.stderr)
    clients = []

def normalize_num(num):
    return re.sub(r'\D', '', str(num))

client_map = {}   # normalized digits → {name, slug}
for c in clients:
    num = normalize_num(c.get('number', ''))
    if num:
        client_map[num] = {'name': c.get('name', num), 'slug': c.get('slug', num)}

def lookup_client(from_number):
    digits = normalize_num(from_number)
    return client_map.get(digits)

# ── Fetch from Supabase (last 24h) ────────────────────────────────────────────
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
cutoff_iso = cutoff.isoformat().replace('+00:00', 'Z')

messages_by_client = {}  # slug → {name, messages[]}
ids_to_mark_read   = []  # Supabase row ids (for read_sent=true)
wa_msg_ids_read    = []  # WhatsApp message_ids (for Cloud API read receipt)

supabase_ok = False
try:
    params = urllib.parse.urlencode({
        'received_at': f'gte.{cutoff_iso}',
        'order': 'received_at.asc',
        'select': 'id,message_id,from_number,from_name,contact_slug,contact_name,message_type,body,timestamp_wa,read_sent',
    })
    url = f"{SUPABASE_URL}/rest/v1/whatsapp_messages?{params}"
    req = urllib.request.Request(url, headers={
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Accept': 'application/json',
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        rows = json.loads(r.read())
    supabase_ok = True
    print(f'Supabase: {len(rows)} messages in last 24h', file=sys.stderr)

    for row in rows:
        from_num    = row.get('from_number', '')
        from_name   = row.get('from_name') or ''
        c_slug      = row.get('contact_slug') or ''
        c_name      = row.get('contact_name') or ''

        # Try to resolve contact from local contacts map if not stored in DB
        if not c_slug:
            match = lookup_client(from_num)
            if match:
                c_slug = match['slug']
                c_name = match['name']

        if not c_name:
            c_name = from_name or from_num

        slug = c_slug or ('unknown_' + normalize_num(from_num)[-4:] if from_num else 'unknown')
        if slug not in messages_by_client:
            messages_by_client[slug] = {'name': c_name, 'messages': []}

        msg_type = row.get('message_type', 'text')
        body     = row.get('body') or f'[{msg_type}]'
        ts_raw   = row.get('timestamp_wa') or row.get('received_at') or ''

        try:
            ts = datetime.datetime.fromisoformat(ts_raw.replace('Z', '+00:00'))
            ts = ts.replace(tzinfo=None)
        except Exception:
            ts = datetime.datetime.utcnow()

        messages_by_client[slug]['messages'].append({'ts': ts, 'text': body})

        ids_to_mark_read.append(row['id'])
        if not row.get('read_sent'):
            wa_msg_ids_read.append(row.get('message_id', ''))

except Exception as e:
    print(f'Supabase fetch failed: {e} — falling back to local JSONL', file=sys.stderr)

# ── Fallback: local JSONL file ────────────────────────────────────────────────
if not supabase_ok and Path(MESSAGES_LOG).exists() and Path(MESSAGES_LOG).stat().st_size > 0:
    try:
        with open(MESSAGES_LOG) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except Exception:
                    continue
                ts_raw = msg.get('timestamp', '')
                try:
                    ts = datetime.datetime.fromisoformat(ts_raw.replace('Z', '+00:00')).replace(tzinfo=None)
                except Exception:
                    continue
                if ts < cutoff.replace(tzinfo=None):
                    continue
                from_num = msg.get('from', '')
                match = lookup_client(from_num)
                if match:
                    slug, name = match['slug'], match['name']
                else:
                    slug = 'unknown_' + normalize_num(from_num)[-4:] if from_num else 'unknown'
                    name = msg.get('from_name') or from_num
                if slug not in messages_by_client:
                    messages_by_client[slug] = {'name': name, 'messages': []}
                messages_by_client[slug]['messages'].append({'ts': ts, 'text': msg.get('text','')})
    except Exception as e:
        print(f'Fallback JSONL read failed: {e}', file=sys.stderr)

# ── Write inbox markdown ──────────────────────────────────────────────────────
for slug in messages_by_client:
    messages_by_client[slug]['messages'].sort(key=lambda m: m['ts'])

date_str = datetime.datetime.now().strftime('%A, %d %B %Y')
lines = [f'# WhatsApp Inbox — {date_str}', '']

if not messages_by_client:
    lines.append('*No WhatsApp messages in the last 24 hours.*')
else:
    total = sum(len(v['messages']) for v in messages_by_client.values())
    lines.append(f"*{total} message(s) from {len(messages_by_client)} contact(s) in the last 24 hours.*")
    lines.append('')
    for slug, data in sorted(messages_by_client.items()):
        lines.append(f"## {data['name']}")
        lines.append('')
        for m in data['messages']:
            ts_fmt = m['ts'].strftime('%H:%M')
            lines.append(f"**{ts_fmt}** {m['text']}")
        lines.append('')

with open(INBOX_OUT, 'w') as f:
    f.write('\n'.join(lines))

# Return IDs to mark read
print(json.dumps({'ids': ids_to_mark_read, 'wa_ids': wa_msg_ids_read,
                  'supabase_ok': supabase_ok, 'messages': total if messages_by_client else 0}))
PY
)

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Inbox written — $CAPTURE_RESULT" | tee -a "$LOG"

# ── Mark rows as read_sent in Supabase ────────────────────────────────────────
MARK_IDS=$(echo "$CAPTURE_RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(' '.join(d.get('ids',[])) if d.get('supabase_ok') else '')" 2>/dev/null) || true

if [[ -n "${MARK_IDS// /}" && -n "$SERVICE_KEY" ]]; then
  for ROW_ID in $MARK_IDS; do
    curl -s -X PATCH \
      "${SUPABASE_URL}/rest/v1/whatsapp_messages?id=eq.${ROW_ID}" \
      -H "apikey: ${SERVICE_KEY}" \
      -H "Authorization: Bearer ${SERVICE_KEY}" \
      -H "Content-Type: application/json" \
      -H "Prefer: return=minimal" \
      -d '{"read_sent":true}' >> "$LOG" 2>&1 || true
  done
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Marked $(echo "$MARK_IDS" | wc -w | tr -d ' ') rows as read_sent" | tee -a "$LOG"
fi

# ── Send read receipts back to WhatsApp Cloud API ─────────────────────────────
if [[ "${WHATSAPP_TOKEN:-REPLACE_WITH_WHATSAPP_ACCESS_TOKEN}" != "REPLACE_WITH_WHATSAPP_ACCESS_TOKEN" && -n "${WHATSAPP_TOKEN:-}" && -n "${WHATSAPP_PHONE_ID:-}" ]]; then
  WA_IDS=$(echo "$CAPTURE_RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print('\n'.join(d.get('wa_ids',[])))" 2>/dev/null) || true
  while IFS= read -r MSG_ID; do
    [[ -z "$MSG_ID" ]] && continue
    curl -s -X POST \
      "https://graph.facebook.com/v21.0/${WHATSAPP_PHONE_ID}/messages" \
      -H "Authorization: Bearer ${WHATSAPP_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"messaging_product\":\"whatsapp\",\"status\":\"read\",\"message_id\":\"${MSG_ID}\"}" \
      >> "$LOG" 2>&1 || true
  done <<< "$WA_IDS"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WhatsApp read receipts sent" | tee -a "$LOG"
else
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WHATSAPP_TOKEN not configured — skipping read receipts" | tee -a "$LOG"
fi

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") whatsapp-capture complete" | tee -a "$LOG"
