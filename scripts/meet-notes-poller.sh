#!/bin/bash
# meet-notes-poller.sh
# Watches josh@amalfiai.com for Read AI meeting note emails.
# When found: fetches full content, runs Claude analysis, sends Telegram debrief immediately.
# Also saves to research_sources for long-term intel pipeline.
# Runs every 15 min via LaunchAgent.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a
source "$WS/scripts/lib/task-helpers.sh"

LOG="$WS/out/meet-notes-poller.log"
SEEN_FILE="$WS/tmp/meet-notes-seen.txt"
mkdir -p "$WS/out" "$WS/tmp"

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; echo "[$(date '+%H:%M:%S')] $*"; }
log "=== Meet notes poller ==="
TASK_ID=$(task_create "Meet Notes Poller" "Scanning for new meeting notes" "meet-notes-poller" "normal")

KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
ACCOUNT="josh@amalfiai.com"
OPENAI_KEY="${OPENAI_API_KEY:-}"

touch "$SEEN_FILE"

# ── Search for unread meeting note emails (two queries, merged) ────────────────
# Read AI:  from executiveassistant@e.read.ai
# Gemini:   from gemini-notes@google.com

READAI_JSON=$(gog gmail search \
  "from:executiveassistant@e.read.ai is:unread" \
  --account "$ACCOUNT" \
  --json --results-only 2>/dev/null || echo "[]")

GEMINI_JSON=$(gog gmail search \
  "from:gemini-notes@google.com is:unread" \
  --account "$ACCOUNT" \
  --json --results-only 2>/dev/null || echo "[]")

# Merge both lists, deduplicate by id
EMAILS_JSON=$(python3 -c "
import json, sys
readai = json.loads('$READAI_JSON'.replace(\"'\", '\"')) if '$READAI_JSON'.strip().startswith('[') else []
gemini = json.loads('$GEMINI_JSON'.replace(\"'\", '\"')) if '$GEMINI_JSON'.strip().startswith('[') else []
" 2>/dev/null || echo "[]")

export READAI_JSON GEMINI_JSON

EMAILS_JSON=$(python3 - <<'PYMERGE'
import os, json
readai_raw = os.environ.get('READAI_JSON', '[]')
gemini_raw = os.environ.get('GEMINI_JSON', '[]')
try:
    readai = json.loads(readai_raw) if readai_raw.strip().startswith('[') else []
except Exception:
    readai = []
try:
    gemini = json.loads(gemini_raw) if gemini_raw.strip().startswith('[') else []
except Exception:
    gemini = []
seen_ids = set()
merged = []
for e in readai + gemini:
    eid = e.get('id') or e.get('messageId','')
    if eid and eid not in seen_ids:
        seen_ids.add(eid)
        merged.append(e)
print(json.dumps(merged))
PYMERGE
)

COUNT=$(echo "$EMAILS_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo "0")

if [[ "$COUNT" -eq 0 ]]; then
  log "No new meeting notes."
  exit 0
fi

log "Found $COUNT meeting note email(s). Processing..."

export EMAILS_JSON KEY SUPABASE_URL BOT_TOKEN CHAT_ID SEEN_FILE ACCOUNT OPENAI_KEY WS

python3 - <<'PY'
import os, json, subprocess, urllib.request, urllib.error, datetime, re, tempfile

EMAILS_JSON  = os.environ['EMAILS_JSON']
KEY          = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
SEEN_FILE    = os.environ['SEEN_FILE']
ACCOUNT      = os.environ['ACCOUNT']
OPENAI_KEY   = os.environ.get('OPENAI_KEY', '')
WS           = os.environ['WS']

emails = json.loads(EMAILS_JSON) if EMAILS_JSON.strip().startswith('[') else []

with open(SEEN_FILE) as f:
    seen = set(l.strip() for l in f if l.strip())

# Track meeting names processed this run to avoid duplicate debriefs
# (same meeting from both Read AI + Gemini)
seen_meeting_names = set()

processed = 0

def tg_send(text):
    if not BOT_TOKEN or not CHAT_ID:
        return
    data = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'Markdown'}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        data=data, headers={'Content-Type': 'application/json'}, method='POST'
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def openai_complete(system_prompt, user_content, model='gpt-4o'):
    if not OPENAI_KEY:
        return ''
    payload = json.dumps({
        'model': model,
        'messages': [
            {'role': 'system', 'content': system_prompt},
            {'role': 'user',   'content': user_content},
        ],
        'temperature': 0.4,
    }).encode()
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=payload,
        headers={'Authorization': f'Bearer {OPENAI_KEY}', 'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
            return data['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f"  [warn] OpenAI call failed: {e}")
        return ''

SYSTEM_PROMPT = """You are a sharp meeting intelligence analyst for Josh Burton, founder of Amalfi AI — an AI agency building AI operating systems for South African businesses.

Your job: give Josh a fast, honest, useful debrief he can act on immediately. He reads this on his phone.

TONE: Direct and conversational. Like a smart colleague who was in the room. Not a consultant's report.

FORMAT — use exactly this structure, plain Markdown, no extra headers:

📋 *[Meeting name]* — [type: Discovery/Progress/Delivery/Internal]
*With:* [names + companies]
*When:* [date/time]

*What happened:*
[3-5 tight sentences — what was actually discussed, not just topics listed]

*Decisions & agreements:*
[What was confirmed or moved. "Nothing concrete" if unclear]

*Action items:*
[🔴 Josh: specific thing]
[Other person: specific thing]

*Relationship read:*
[One honest paragraph — where does this relationship stand? Warm/cool/stalling/promising? Trust signals or red flags?]

*Watch out for:*
[1-3 specific concerns or follow-up items. Real risks, not generic warnings]

*Verdict:*
[One sentence. Honest read on what this meeting means for the business]

RULES:
- If the transcript was truncated or cut off, say so at the very top before anything else: "⚠️ Transcript was cut off — debrief based on partial notes"
- If names/companies are unknown, say so rather than guessing
- Flag scope creep, compliance risk, or unclear priorities
- No padding, no "great session" filler, no corporate speak"""

for email in emails:
    email_id = email.get('id') or email.get('messageId', '')
    if not email_id or email_id in seen:
        continue

    # Filter: skip weekly digests and marketing
    subject = email.get('subject', '') or ''
    if any(skip in subject for skip in ['Weekly Kickoff', 'Weekly Summary', "won't generate", 'next meeting']):
        seen.add(email_id)
        continue

    sender = email.get('from', '')
    body   = email.get('body') or email.get('snippet', '')

    # Fetch full email content
    try:
        result = subprocess.run(
            ['gog', 'gmail', 'read', email_id, '--account', ACCOUNT, '--results-only'],
            capture_output=True, text=True, timeout=30
        )
        if result.stdout.strip():
            body = result.stdout.strip()
    except Exception as e:
        print(f"  [warn] Could not fetch full body for {email_id}: {e}")

    if not body or len(body.strip()) < 100:
        print(f"  [skip] {subject} — body too short")
        seen.add(email_id)
        continue

    # Clean HTML/tracking noise
    clean_body = re.sub(r'<[^>]+>', ' ', body)
    clean_body = re.sub(r'https?://\S+', '', clean_body)
    clean_body = re.sub(r'[\u200b\u00ad\ufeff]', '', clean_body)
    clean_body = re.sub(r'\s{3,}', '\n\n', clean_body).strip()

    # Extract meeting name from subject
    meeting_name = subject
    gemini_match = re.match(r'^Notes:\s*"(.+?)"', subject)
    readai_match = re.match(r'^[^\w]*(.+?)\s+on\s+\w+\s+\d+', subject)
    if gemini_match:
        meeting_name = gemini_match.group(1).strip()
    elif readai_match:
        meeting_name = readai_match.group(1).strip()

    # Deduplicate by meeting name — skip if already sent a debrief for this meeting today
    name_key = re.sub(r'\s+', ' ', meeting_name.lower().strip())
    if name_key in seen_meeting_names:
        print(f"  [skip] Duplicate meeting debrief suppressed: {meeting_name}")
        seen.add(email_id)
        continue
    seen_meeting_names.add(name_key)

    print(f"  Processing: {meeting_name}")

    # Detect client and load context
    CLIENT_KEYWORDS = {
        'ascend': 'qms-guard', 'qms': 'qms-guard', 'riaan': 'qms-guard',
        'favlog': 'favorite-flow', 'favorite': 'favorite-flow',
        'flair': 'favorite-flow', 'irshad': 'favorite-flow',
        'race technik': 'chrome-auto-care', 'farhaan': 'chrome-auto-care',
    }
    CLIENT_CONTEXT_PATHS = {
        'qms-guard':        f"{WS}/clients/qms-guard/CONTEXT.md",
        'favorite-flow':    f"{WS}/clients/favorite-flow-9637aff2/CONTEXT.md",
        'chrome-auto-care': f"{WS}/clients/chrome-auto-care/CONTEXT.md",
    }
    probe = (subject + ' ' + clean_body[:500]).lower()
    client_key = next((v for k, v in CLIENT_KEYWORDS.items() if k in probe), None)
    client_context_section = ''
    if client_key:
        ctx_path = CLIENT_CONTEXT_PATHS.get(client_key, '')
        if ctx_path and os.path.exists(ctx_path):
            with open(ctx_path) as cf:
                client_context_section = f"\n## Client Context\n{cf.read()}\n"

    # Run OpenAI analysis
    user_content = f"""## Meeting subject
{subject}
{client_context_section}
## Notes / Transcript
{clean_body[:12000]}"""

    analysis = openai_complete(SYSTEM_PROMPT, user_content, model='gpt-4o')
    if not analysis:
        analysis = f'_(Analysis unavailable — OpenAI call failed)_'

    # Send Telegram debrief
    # Split if over 4096 chars
    if len(analysis) <= 4000:
        tg_send(analysis)
    else:
        chunks = []
        current = ''
        for para in analysis.split('\n\n'):
            if len(current) + len(para) + 2 > 3800:
                if current:
                    chunks.append(current.strip())
                current = para
            else:
                current += ('\n\n' if current else '') + para
        if current:
            chunks.append(current.strip())
        for chunk in chunks:
            tg_send(chunk)

    print(f"  [ok] Telegram debrief sent: {meeting_name}")

    # Save to research_sources
    payload = {
        'title':       f"Meeting: {meeting_name}",
        'raw_content': f"Subject: {subject}\nFrom: {sender}\n\n{clean_body[:10000]}",
        'status':      'pending',
        'metadata':    {
            'type':        'meeting_notes',
            'email_id':    email_id,
            'from':        sender,
            'subject':     subject,
            'ingested_at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        },
    }
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/research_sources",
        data=json.dumps(payload).encode(),
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
        method='POST',
    )
    try:
        urllib.request.urlopen(req, timeout=15)
    except Exception as e:
        print(f"  [warn] research_sources insert failed: {e}")

    # Mark email as read
    subprocess.run(
        ['gog', 'gmail', 'thread', 'modify', email_id,
         '--account', ACCOUNT, '--remove=UNREAD', '--force'],
        capture_output=True, timeout=15
    )

    seen.add(email_id)
    processed += 1

# Persist seen IDs
all_seen = list(seen)[-500:]
with open(SEEN_FILE, 'w') as f:
    f.write('\n'.join(all_seen))

print(f"Done — {processed} meeting(s) analysed.")
PY

task_complete "$TASK_ID" "Meet notes poller complete"
log "Meet notes poller complete."
