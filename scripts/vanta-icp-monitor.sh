#!/usr/bin/env bash
# vanta-icp-monitor.sh
# Runs every 30 min after ICP discovery message is sent.
# Watches Marcus's chat history for ICP answers, then generates a structured
# brief via GPT-4o and sends it to Josh on Telegram + saves to memory.

WS="/Users/henryburton/.openclaw/workspace-anthropic"
LOG="$WS/out/vanta-icp-monitor.log"
FLAG="$WS/tmp/vanta-icp-sent.flag"
BRIEF_FILE="$WS/memory/vanta-icp-brief.md"
DONE_FLAG="$WS/tmp/vanta-icp-done.flag"

export SUPABASE_SERVICE_ROLE_KEY=$(grep "^SUPABASE_SERVICE_ROLE_KEY=" "$WS/.env.scheduler" | cut -d= -f2-)
export OPENAI_API_KEY=$(grep "^OPENAI_API_KEY=" "$WS/.env.scheduler" | cut -d= -f2-)
export TELEGRAM_BOT_TOKEN=$(grep "^TELEGRAM_BOT_TOKEN=" "$WS/.env.scheduler" | cut -d= -f2-)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Only run after the discovery message was sent
if [ ! -f "$FLAG" ]; then
  log "ICP discovery message not sent yet — skipping"
  exit 0
fi

# Don't re-run if brief is already complete
if [ -f "$DONE_FLAG" ]; then
  log "ICP brief already generated — nothing to do"
  exit 0
fi

log "vanta-icp-monitor checking for replies"

# Find Marcus's chat history file
HIST_FILE=$(find "$WS/memory" -name "*Vanta*Studios*.jsonl" -o -name "*vanta*studios*.jsonl" -o -name "*27816057793*.jsonl" -o -name "*marcus*.jsonl" 2>/dev/null | head -1)
if [ -z "$HIST_FILE" ]; then
  log "No Marcus chat history found yet"
  exit 0
fi

# Check if there are replies after the ICP message was sent
SENT_AT=$(cat "$FLAG")
REPLY_COUNT=$(python3 -c "
import json, sys
from datetime import datetime, timezone

sent_at = datetime.fromisoformat('$SENT_AT'.replace('Z','+00:00'))
hist_file = '$HIST_FILE'

try:
    lines = [json.loads(l) for l in open(hist_file).readlines() if l.strip()]
    # Count messages from Marcus after sent_at
    replies = [l for l in lines
               if l.get('role') in ('user','human')
               and datetime.fromisoformat(l.get('ts','').replace('Z','+00:00')) > sent_at]
    print(len(replies))
except Exception as e:
    print(0)
" 2>/dev/null)

if [ "${REPLY_COUNT:-0}" -lt 2 ]; then
  log "Only $REPLY_COUNT replies so far — waiting for more before generating brief"
  exit 0
fi

log "Found $REPLY_COUNT replies — generating ICP brief"

# Build brief via GPT-4o
python3 << PYEOF
import json, os, urllib.request, datetime

WS = '$WS'
hist_file = '$HIST_FILE'
sent_at_str = '$SENT_AT'
openai_key = os.environ.get('OPENAI_API_KEY','')
bot_token = os.environ.get('TELEGRAM_BOT_TOKEN','')
brief_file = '$BRIEF_FILE'

from datetime import datetime, timezone
sent_at = datetime.fromisoformat(sent_at_str.replace('Z','+00:00'))

# Load chat history after discovery was sent
lines = [json.loads(l) for l in open(hist_file).readlines() if l.strip()]
conversation = []
for l in lines:
    ts_str = l.get('ts','')
    if not ts_str:
        continue
    try:
        ts = datetime.fromisoformat(ts_str.replace('Z','+00:00'))
    except:
        continue
    if ts >= sent_at:
        role = 'Marcus' if l.get('role') in ('user','human') else 'Sophia'
        conversation.append(f"{role}: {l.get('text','')}")

convo_text = '\n'.join(conversation)

# Generate structured ICP brief via GPT-4o
prompt = f"""You are reading a WhatsApp conversation between Sophia (an AI assistant) and Marcus, owner of Vanta Studios — a photography studio in South Africa.

Sophia sent Marcus ICP discovery questions. Below is the conversation. Extract all answers and generate a clean, structured ICP (Ideal Client Profile) brief.

CONVERSATION:
{convo_text}

Output a markdown document with these sections:
## Vanta Studios — ICP Brief
**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}

### Ideal Client Profile
(Who they are targeting — job title, type, size)

### Geography
(Which cities/regions)

### Niche / Photography Type
(Wedding, portrait, commercial, etc.)

### Outreach Tone
(How to communicate with their prospects)

### Instagram & Website
(Their social handles to reference in outreach)

### Discovery Hashtags
(Suggest 10 targeted Instagram hashtags based on the above)

### Suggested Email Subject Lines
(3 subject lines for cold outreach, tailored to their ICP)

### Suggested First Email Tone
(1 paragraph describing the outreach approach)

### Notes
(Anything else Marcus mentioned)

If Marcus hasn't answered a question yet, write "Pending — ask Marcus" for that field."""

data = json.dumps({
    'model': 'gpt-4o',
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': 1200,
    'temperature': 0.3
}).encode()

req = urllib.request.Request(
    'https://api.openai.com/v1/chat/completions',
    data=data,
    headers={'Authorization': f'Bearer {openai_key}', 'Content-Type': 'application/json'}
)
resp = urllib.request.urlopen(req, timeout=30)
brief = json.loads(resp.read())['choices'][0]['message']['content']

# Save to file
with open(brief_file, 'w') as f:
    f.write(brief)
print(f'Brief saved to {brief_file}')

# Send to Josh on Telegram
tg_msg = f"📋 *Vanta Studios — ICP Brief Ready*\n\nMarcus has replied to the discovery questions. Here's what we've got:\n\n{brief[:3500]}"
tg_data = json.dumps({'chat_id':'1140320036','text':tg_msg,'parse_mode':'Markdown'}).encode()
tg_req = urllib.request.Request(
    f'https://api.telegram.org/bot{bot_token}/sendMessage',
    data=tg_data, headers={'Content-Type':'application/json'}
)
try:
    urllib.request.urlopen(tg_req, timeout=10)
    print('Josh notified on Telegram')
except Exception as e:
    print(f'Telegram failed: {e}')
PYEOF

if [ $? -eq 0 ]; then
  touch "$DONE_FLAG"
  log "ICP brief generated and sent to Josh"
else
  log "Brief generation failed"
fi
