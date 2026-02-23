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
MODEL="claude-sonnet-4-6"

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

export EMAILS_JSON KEY SUPABASE_URL BOT_TOKEN CHAT_ID SEEN_FILE ACCOUNT MODEL WS

python3 - <<'PY'
import os, json, subprocess, urllib.request, datetime, re, tempfile

EMAILS_JSON  = os.environ['EMAILS_JSON']
KEY          = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
SEEN_FILE    = os.environ['SEEN_FILE']
ACCOUNT      = os.environ['ACCOUNT']
MODEL        = os.environ['MODEL']
WS           = os.environ['WS']

emails = json.loads(EMAILS_JSON) if EMAILS_JSON.strip().startswith('[') else []

with open(SEEN_FILE) as f:
    seen = set(l.strip() for l in f if l.strip())

processed = 0

def tg_send(text):
    if not BOT_TOKEN or not CHAT_ID:
        return
    data = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        data=data, headers={'Content-Type': 'application/json'}, method='POST'
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

for email in emails:
    email_id = email.get('id') or email.get('messageId', '')
    if not email_id or email_id in seen:
        continue

    # Filter: skip weekly digests and marketing (only process actual meeting reports)
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
        print(f"  [skip] {subject} — body too short after fetch")
        seen.add(email_id)
        continue

    # Clean HTML/tracking noise
    clean_body = re.sub(r'<[^>]+>', ' ', body)
    clean_body = re.sub(r'https?://\S+', '', clean_body)
    clean_body = re.sub(r'[\u200b\u00ad\ufeff]', '', clean_body)  # zero-width chars
    clean_body = re.sub(r'\s{3,}', '\n\n', clean_body).strip()

    # Extract meeting name from subject:
    # Read AI:  "🗓 Meeting Name on Date @ Time | Read Meeting Report"
    # Gemini:   'Notes: "Meeting Name" Date'
    meeting_name = subject
    gemini_match = re.match(r'^Notes:\s*"(.+?)"', subject)
    readai_match = re.match(r'^[^\w]*(.+?)\s+on\s+\w+\s+\d+', subject)
    if gemini_match:
        meeting_name = gemini_match.group(1).strip()
    elif readai_match:
        meeting_name = readai_match.group(1).strip()

    print(f"  Processing: {meeting_name}")

    # ── Detect client and load context ────────────────────────────────────────
    CLIENT_KEYWORDS = {
        'ascend': 'qms-guard',
        'qms': 'qms-guard',
        'riaan': 'qms-guard',
        'farhaan': 'chrome-auto-care',
        'race technik': 'chrome-auto-care',
        'chrome': 'chrome-auto-care',
        'favlog': 'favorite-flow',
        'favorite': 'favorite-flow',
        'flair': 'favorite-flow',
        'irshad': 'favorite-flow',
    }
    CLIENT_CONTEXT_PATHS = {
        'qms-guard':        f"{WS}/clients/qms-guard/CONTEXT.md",
        'chrome-auto-care': f"{WS}/clients/chrome-auto-care/CONTEXT.md",
        'favorite-flow':    f"{WS}/clients/favorite-flow-9637aff2/CONTEXT.md",
    }
    probe = (subject + ' ' + clean_body[:500]).lower()
    client_key = next((v for k, v in CLIENT_KEYWORDS.items() if k in probe), None)
    client_context_section = ''
    if client_key:
        ctx_path = CLIENT_CONTEXT_PATHS.get(client_key, '')
        if ctx_path and os.path.exists(ctx_path):
            with open(ctx_path) as cf:
                client_context_section = f"\n## Client Context\n{cf.read()}\n"

    # ── Run Claude analysis ────────────────────────────────────────────────────
    prompt = f"""You are analysing a meeting for Josh Burton, founder of Amalfi AI (an AI agency building AI operating systems for SA businesses).
{client_context_section}
## Meeting
{subject}

## Notes / Transcript
{clean_body[:8000]}

## Your job
Give Josh a sharp debrief that fits into the ongoing client relationship. Structure:

**Meeting type:** [Discovery / Progress / Delivery / Relationship / Internal / Other]
**With:** [names and companies]
**Date/time:** [from subject]

**What happened:**
[3-5 bullets — key things discussed]

**Decisions & agreements:**
[what was confirmed or moved forward. None if nothing concrete]

**Action items:**
[who needs to do what. Flag Josh's items with 🔴]

**Relationship read:**
[where is this relationship? progressing/stalling/warm/cool? Trust signals or red flags?]

**Watch out for:**
[concerns, opportunities, follow-up needed]

**One-line verdict:**
[honest read on the meeting and what it means]

Keep it tight. Josh reads this on his phone. No padding.
"""

    tmpfile = tempfile.mktemp(suffix='.txt')
    with open(tmpfile, 'w') as f:
        f.write(prompt)

    analysis = ''
    try:
        import os as _os
        env = dict(_os.environ)
        env['CLAUDECODE'] = ''  # unset trick — actually need to delete it
        env.pop('CLAUDECODE', None)
        result = subprocess.run(
            ['claude', '--print', '--model', MODEL, '--dangerously-skip-permissions'],
            stdin=open(tmpfile), capture_output=True, text=True, timeout=120, env=env
        )
        analysis = result.stdout.strip()
        if not analysis:
            analysis = result.stderr.strip() or '(No analysis returned)'
    except Exception as e:
        analysis = f'(Analysis failed: {e})'
    finally:
        try:
            import os as _os2
            _os2.remove(tmpfile)
        except Exception:
            pass

    # ── Send Telegram debrief ──────────────────────────────────────────────────
    header = f"📋 <b>Meeting debrief: {meeting_name}</b>\n\n"
    # Telegram max 4096 chars — truncate analysis if needed
    max_body = 4096 - len(header) - 10
    body_text = analysis[:max_body] if len(analysis) > max_body else analysis
    tg_send(header + body_text)
    print(f"  [ok] Telegram debrief sent: {meeting_name}")

    # ── Save to research_sources for long-term pipeline ───────────────────────
    payload = {
        'title':       f"Meeting: {meeting_name}",
        'raw_content': f"Subject: {subject}\nFrom: {sender}\n\n{clean_body[:10000]}",
        'status':      'pending',
        'metadata':    {
            'type':        'meeting_notes',
            'email_id':    email_id,
            'from':        sender,
            'subject':     subject,
            'ingested_at': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
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

    # ── Mark email as read (thread ID = message ID for single-message threads) ─
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
