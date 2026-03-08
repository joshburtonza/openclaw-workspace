#!/usr/bin/env bash
# sophia-monday-report.sh
# Every Monday 09:00 SAST — sends Josh a full client status briefing via WhatsApp.
# Ascend LC gets a TTS voice note. All others get formatted text updates.
# Data sources: DEV_STATUS.md (nightly), context.md, open Supabase tasks, git log.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

WA_API="http://127.0.0.1:3001"
JOSH_NUMBER="${WA_OWNER_NUMBER:-+27812705358}"
SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
LOG="$WS/out/sophia-monday-report.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
mkdir -p "$WS/out" "$WS/tmp"

log "Monday report starting"

# ── Gather data for each client ────────────────────────────────────────────────
gather_client_data() {
  local SLUG="$1"
  local REPO="$2"
  local TASK_TAG="$3"

  local REPO_DIR="$WS/clients/$REPO"

  # DEV_STATUS
  local DEV_STATUS=""
  if [[ -f "$REPO_DIR/DEV_STATUS.md" ]]; then
    DEV_STATUS=$(sed 's/```[a-z]*//g' "$REPO_DIR/DEV_STATUS.md" | head -40)
  fi

  # Context
  local CTX=""
  if [[ -f "$REPO_DIR/context.md" ]]; then
    CTX=$(head -35 "$REPO_DIR/context.md")
  fi

  # Git commits past 7 days
  local COMMITS=""
  if [[ -d "$REPO_DIR/.git" ]]; then
    COMMITS=$(git -C "$REPO_DIR" log --since="7 days ago" --pretty=format:"%ad %s" --date=format:"%a %d %b" --no-merges 2>/dev/null | head -10 || true)
  fi

  # Open tasks from Supabase
  local TASKS=""
  if [[ -n "$SUPABASE_KEY" && -n "$TASK_TAG" ]]; then
    TASKS=$(curl -s "$SUPABASE_URL/rest/v1/tasks?tags=cs.{$TASK_TAG}&status=in.(todo,in_progress)&order=priority.desc&limit=8" \
      -H "apikey: $SUPABASE_KEY" \
      -H "Authorization: Bearer $SUPABASE_KEY" | python3 -c "
import sys, json
try:
    tasks = json.loads(sys.stdin.read())
    if isinstance(tasks, list) and tasks:
        for t in tasks:
            p = '[URGENT] ' if t.get('priority') == 'urgent' else '[HIGH] ' if t.get('priority') == 'high' else ''
            print(f'{p}[{t.get(\"status\",\"?\")}] {t.get(\"title\",\"?\")}')
except: pass
" 2>/dev/null || true)
  fi

  echo "=== $SLUG ==="
  echo "DEV STATUS:"
  echo "$DEV_STATUS"
  echo ""
  echo "CONTEXT:"
  echo "$CTX"
  echo ""
  if [[ -n "$COMMITS" ]]; then
    echo "COMMITS THIS WEEK:"
    echo "$COMMITS"
    echo ""
  fi
  if [[ -n "$TASKS" ]]; then
    echo "OPEN TASKS:"
    echo "$TASKS"
    echo ""
  fi
}

# ── Build data payload ─────────────────────────────────────────────────────────
export _ASCEND_DATA; _ASCEND_DATA=$(gather_client_data "Ascend LC (QMS Guard)" "qms-guard" "ascend-lc")
export _VANTA_DATA;  _VANTA_DATA=$(gather_client_data "Vanta Studios" "vanta-studios" "vanta-studios")
export _RACE_DATA;   _RACE_DATA=$(gather_client_data "Race Technik" "chrome-auto-care" "race-technik")
export _FAVLOG_DATA; _FAVLOG_DATA=$(gather_client_data "Favorite Logistics (FLAIR)" "favorite-flow-9637aff2" "favorite-logistics")
export _AMBASSADEX_DATA; _AMBASSADEX_DATA=$(gather_client_data "Ambassadex" "ambassadex" "ambassadex")
export _TODAY; _TODAY=$(date '+%A, %d %B %Y')
export _OPENAI_KEY="$OPENAI_KEY"
export _WA_API="$WA_API"
export _JOSH_NUMBER="$JOSH_NUMBER"

python3 - <<'PYREPORT'
import json, os, urllib.request, time

openai_key   = os.environ.get('_OPENAI_KEY', '')
wa_api       = os.environ.get('_WA_API', '')
josh_number  = os.environ.get('_JOSH_NUMBER', '')
today        = os.environ.get('_TODAY', '')

clients = [
    ('Ascend LC',           os.environ.get('_ASCEND_DATA', ''),   'voice'),
    ('Vanta Studios',       os.environ.get('_VANTA_DATA', ''),    'text'),
    ('Race Technik',        os.environ.get('_RACE_DATA', ''),     'text'),
    ('Favorite Logistics',  os.environ.get('_FAVLOG_DATA', ''),   'text'),
    ('Ambassadex',          os.environ.get('_AMBASSADEX_DATA', ''),'text'),
]

def call_gpt(system, user, model='gpt-4o', max_tokens=600):
    payload = json.dumps({
        'model': model,
        'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user',   'content': user},
        ],
        'max_tokens': max_tokens,
        'temperature': 0.4,
    }).encode()
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=payload,
        headers={'Authorization': f'Bearer {openai_key}', 'Content-Type': 'application/json'},
        method='POST')
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f'GPT error: {e}')
        return None

def send_wa_text(message):
    payload = json.dumps({'to': josh_number, 'message': message}).encode()
    req = urllib.request.Request(f'{wa_api}/send', data=payload,
        headers={'Content-Type': 'application/json'}, method='POST')
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f'WA text error: {e}')

def send_wa_voice(text):
    payload = json.dumps({'to': josh_number, 'text': text}).encode()
    req = urllib.request.Request(f'{wa_api}/send-voice', data=payload,
        headers={'Content-Type': 'application/json'}, method='POST')
    try:
        urllib.request.urlopen(req, timeout=30)
    except Exception as e:
        print(f'WA voice error: {e}')

def generate_text_report(name, data):
    return call_gpt(
        'You are Sophia, Amalfi AI\'s client success manager. Write a structured Monday status update for Josh about one of his clients. No hyphens anywhere. No markdown headers. Use bold (*text*) for WhatsApp section labels. Max 250 words. Structure four sections: (1) *Done this week* covering specific completed work, (2) *Current status* covering where the project stands right now, (3) *Client journey* covering where they are in the engagement arc and relationship health, (4) *Coming up* covering next steps, upcoming deliverables, any flags. Be direct, specific, no filler.',
        f'Today: {today}\nClient: {name}\n\nData:\n{data[:2500]}\n\nWrite the Monday update. Start with the client name bolded. Cover all four sections: Done this week, Current status, Client journey, Coming up.'
    )

def generate_voice_script(name, data):
    return call_gpt(
        'You are Sophia, Amalfi AI\'s client success manager. Write a spoken Monday morning brief for Josh about one of his clients. This will be read aloud via TTS — no bullet points, no markdown, no asterisks, just natural spoken sentences. Warm but professional. Max 150 words. Cover four things naturally as one flowing spoken update: what was completed this week, where the project stands right now, where they are in the client journey and relationship arc, and what is coming up next.',
        f'Today: {today}\nClient: {name}\n\nData:\n{data[:2500]}\n\nWrite the spoken brief. Start with "Good morning Josh" then go straight into the update naturally covering: what got done, current status, where they are in the journey, and what is coming up.'
    )

# ── Opening header text ────────────────────────────────────────────────────────
send_wa_text(f'📊 *Monday Client Brief — {today}*\n\nHere\'s your weekly update across all active clients.')
time.sleep(2)

# ── Per-client reports ─────────────────────────────────────────────────────────
for name, data, mode in clients:
    print(f'Generating report for {name}...')

    if not data.strip():
        print(f'  No data for {name} — skipping')
        continue

    if mode == 'voice':
        script = generate_voice_script(name, data)
        if script:
            print(f'  Sending voice note for {name}')
            send_wa_voice(script)
            time.sleep(5)
        # Also send text card as follow-up for reference
        text = generate_text_report(name, data)
        if text:
            time.sleep(3)
            send_wa_text(text)
    else:
        text = generate_text_report(name, data)
        if text:
            print(f'  Sending text update for {name}')
            send_wa_text(text)

    time.sleep(4)

print('Monday report done')
PYREPORT

log "Monday report complete"
