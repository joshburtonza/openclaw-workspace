#!/usr/bin/env bash
# whatsapp-capture.sh — nightly WhatsApp inbox capture
#
# Reads from data/whatsapp-messages.jsonl (written by your webhook receiver when
# WhatsApp Business Cloud API pushes messages to it).
# Filters messages from the last 24h for numbers in data/contacts.json.
# Writes a markdown summary to data/whatsapp-inbox.md for morning-brief.sh.
#
# WhatsApp Cloud API notes:
#   - Incoming messages arrive via webhook (no REST inbox endpoint exists)
#   - Your webhook receiver writes each message as a JSON line to whatsapp-messages.jsonl
#   - This script reads, deduplicates, and summarises those messages
#   - After capture, this script marks messages as read via the Cloud API
#
# Runs at 04:00 UTC (06:00 SAST) via LaunchAgent — before morning-brief at 05:30 UTC.

set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

CONTACTS_FILE="$WORKSPACE/data/contacts.json"
MESSAGES_LOG="$WORKSPACE/data/whatsapp-messages.jsonl"
INBOX_OUT="$WORKSPACE/data/whatsapp-inbox.md"
LOG="$WORKSPACE/out/whatsapp-capture.log"
MARKED_IDS_FILE="$WORKSPACE/tmp/whatsapp-marked-read.txt"

mkdir -p "$WORKSPACE/data" "$WORKSPACE/tmp"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") whatsapp-capture starting" | tee -a "$LOG"

# ── Handle empty/missing message log ─────────────────────────────────────────

if [[ ! -f "$MESSAGES_LOG" || ! -s "$MESSAGES_LOG" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") No messages log at $MESSAGES_LOG — writing empty inbox" | tee -a "$LOG"
  DATE_STR=$(date '+%A, %d %B %Y')
  cat > "$INBOX_OUT" << EOF
# WhatsApp Inbox — ${DATE_STR}

*No messages received in the last 24 hours.*

> Messages are captured via webhook (WhatsApp Business Cloud API pushes to your endpoint).
> Ensure the webhook receiver is running and posting to: \`$MESSAGES_LOG\`
> Each line must be JSON: \`{"from":"+27...","text":"...","timestamp":"2026-01-01T08:00:00Z","message_id":"wamid..."}\`
EOF
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Empty inbox written" | tee -a "$LOG"
  exit 0
fi

# ── Build inbox summary and mark messages as read ─────────────────────────────

CAPTURE_RESULT=$(python3 - <<'PY'
import json, os, sys, datetime, re
from pathlib import Path

WS            = os.environ.get('WORKSPACE', '')
contacts_file = os.path.join(WS, 'data', 'contacts.json')
messages_log  = os.path.join(WS, 'data', 'whatsapp-messages.jsonl')
inbox_out     = os.path.join(WS, 'data', 'whatsapp-inbox.md')
marked_file   = os.path.join(WS, 'tmp', 'whatsapp-marked-read.txt')

# Load contacts map
try:
    with open(contacts_file) as f:
        contacts_data = json.load(f)
    clients = contacts_data.get('clients', [])
except Exception as e:
    print(f"Warning: could not load contacts: {e}", file=sys.stderr)
    clients = []

def normalize(num):
    """Strip non-digits for comparison."""
    return re.sub(r'\D', '', str(num))

client_map = {}
for c in clients:
    num = normalize(c.get('number', ''))
    if num:
        client_map[num] = {
            'name': c.get('name', num),
            'slug': c.get('slug', num),
        }

# Load already-marked-read IDs to skip re-sending read receipts
marked_ids = set()
try:
    with open(marked_file) as f:
        marked_ids = set(l.strip() for l in f if l.strip())
except FileNotFoundError:
    pass

# Parse messages from last 24h
cutoff = datetime.datetime.utcnow() - datetime.timedelta(hours=24)
messages_by_client = {}
new_message_ids = []  # IDs to mark read via API

try:
    with open(messages_log) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue

            # Timestamp filter
            ts_raw = msg.get('timestamp', '')
            try:
                ts = datetime.datetime.fromisoformat(
                    ts_raw.replace('Z', '+00:00')
                ).replace(tzinfo=None)
            except Exception:
                continue
            if ts < cutoff:
                continue

            # Client filter
            from_num = normalize(msg.get('from', ''))
            client = client_map.get(from_num)
            if client is None:
                # Accept unknown senders too — Josh might want to see them
                slug = 'unknown_' + from_num[-4:] if from_num else 'unknown'
                client = {
                    'name': msg.get('from_name') or msg.get('from', 'Unknown'),
                    'slug': slug,
                }

            slug = client['slug']
            if slug not in messages_by_client:
                messages_by_client[slug] = {'name': client['name'], 'messages': []}

            messages_by_client[slug]['messages'].append({
                'ts': ts,
                'text': msg.get('text', ''),
                'media_type': msg.get('media_type', ''),
                'message_id': msg.get('message_id', ''),
            })

            msg_id = msg.get('message_id', '')
            if msg_id and msg_id not in marked_ids:
                new_message_ids.append(msg_id)

except Exception as e:
    print(f"Error reading messages: {e}", file=sys.stderr)

# Sort messages within each client
for slug in messages_by_client:
    messages_by_client[slug]['messages'].sort(key=lambda m: m['ts'])

# Write inbox summary
date_str = datetime.datetime.now().strftime('%A, %d %B %Y')
lines = [f"# WhatsApp Inbox — {date_str}", ""]

if not messages_by_client:
    lines.append("*No messages from tracked contacts in the last 24 hours.*")
else:
    total = sum(len(v['messages']) for v in messages_by_client.values())
    contact_count = len(messages_by_client)
    lines.append(
        f"*{total} message(s) from {contact_count} contact(s) in the last 24 hours.*"
    )
    lines.append("")

    for slug, data in sorted(messages_by_client.items()):
        lines.append(f"## {data['name']}")
        lines.append("")
        for m in data['messages']:
            ts_fmt = m['ts'].strftime('%H:%M')
            if m['text']:
                text = m['text']
            elif m.get('media_type'):
                text = f"[{m['media_type']} attachment]"
            else:
                text = "[no text]"
            lines.append(f"**{ts_fmt}** {text}")
        lines.append("")

with open(inbox_out, 'w') as f:
    f.write('\n'.join(lines))

# Persist new IDs for mark-read step
if new_message_ids:
    with open(marked_file, 'a') as f:
        for mid in new_message_ids:
            f.write(mid + '\n')

total_msgs = sum(len(v['messages']) for v in messages_by_client.values())
print(f"clients={len(messages_by_client)} messages={total_msgs} new_ids={len(new_message_ids)}")
PY
)

export WORKSPACE
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Inbox written — $CAPTURE_RESULT" | tee -a "$LOG"

# ── Mark messages as read via WhatsApp Cloud API ──────────────────────────────
# Only runs if WHATSAPP_TOKEN and WHATSAPP_PHONE_ID are configured (not placeholders)

if [[ "${WHATSAPP_TOKEN:-}" != "REPLACE_WITH_WHATSAPP_ACCESS_TOKEN" && -n "${WHATSAPP_TOKEN:-}" && -n "${WHATSAPP_PHONE_ID:-}" ]]; then
  MARKED_IDS_FILE="$WORKSPACE/tmp/whatsapp-marked-read.txt"
  # Read IDs written by the Python block above, mark each as read
  if [[ -f "$MARKED_IDS_FILE" ]]; then
    while IFS= read -r MSG_ID; do
      [[ -z "$MSG_ID" ]] && continue
      curl -s -X POST \
        "https://graph.facebook.com/v21.0/${WHATSAPP_PHONE_ID}/messages" \
        -H "Authorization: Bearer ${WHATSAPP_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"messaging_product\":\"whatsapp\",\"status\":\"read\",\"message_id\":\"${MSG_ID}\"}" \
        >> "$LOG" 2>&1 || true
    done < "$MARKED_IDS_FILE"
    # Reset file after marking (next capture starts fresh for new IDs)
    > "$MARKED_IDS_FILE"
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Mark-read API calls complete" | tee -a "$LOG"
  fi
else
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WHATSAPP_TOKEN not configured — skipping mark-read" | tee -a "$LOG"
fi

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") whatsapp-capture complete" | tee -a "$LOG"
