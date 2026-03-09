#!/usr/bin/env bash
# sophia-weekly-email-drafts.sh
# Every Thursday 18:00 SAST — generates weekly client email report drafts.
# Sends Josh a WhatsApp preview of each draft for approval.
# On approval ("send it" / "approved" / "looks good"), the gateway fires the emails.

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
PENDING_FILE="$WS/tmp/pending-weekly-reports.json"
LOG="$WS/out/sophia-weekly-email-drafts.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
mkdir -p "$WS/out" "$WS/tmp"

log "Weekly email draft generation starting"

gather_client_data() {
  local SLUG="$1"
  local REPO="$2"
  local TASK_TAG="$3"
  local REPO_DIR="$WS/clients/$REPO"

  local DEV_STATUS=""
  [[ -f "$REPO_DIR/DEV_STATUS.md" ]] && DEV_STATUS=$(sed 's/```[a-z]*//g' "$REPO_DIR/DEV_STATUS.md" | head -40)

  local CTX=""
  [[ -f "$REPO_DIR/context.md" ]] && CTX=$(head -30 "$REPO_DIR/context.md")

  local COMMITS=""
  [[ -d "$REPO_DIR/.git" ]] && COMMITS=$(git -C "$REPO_DIR" log --since="7 days ago" --pretty=format:"%ad %s" --date=format:"%a %d %b" --no-merges 2>/dev/null | head -10 || true)

  local TASKS=""
  if [[ -n "$SUPABASE_KEY" && -n "$TASK_TAG" ]]; then
    TASKS=$(curl -s "$SUPABASE_URL/rest/v1/tasks?tags=cs.{$TASK_TAG}&status=in.(todo,in_progress)&order=priority.desc&limit=6" \
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

  echo "DEV STATUS: $DEV_STATUS"
  echo "CONTEXT: $CTX"
  [[ -n "$COMMITS" ]] && echo "COMMITS: $COMMITS"
  [[ -n "$TASKS" ]] && echo "OPEN TASKS: $TASKS"
}

# Drafts generated Sunday — emails go out Monday. Use Monday's date for all content.
export _TODAY; _TODAY=$(date -v+1d '+%A, %d %B %Y' 2>/dev/null || date --date='+1 day' '+%A, %d %B %Y')
export _SEND_DATE; _SEND_DATE=$(date -v+1d '+%d %B %Y' 2>/dev/null || date --date='+1 day' '+%d %B %Y')
export _WEEK_END; _WEEK_END=$(date -v+6d '+%d %B' 2>/dev/null || date --date='+6 days' '+%d %B')
export _OPENAI_KEY="$OPENAI_KEY"
export _WA_API="$WA_API"
export _JOSH_NUMBER="$JOSH_NUMBER"
export _PENDING_FILE="$PENDING_FILE"

# Clients: name | repo | task_tag | recipient_email | recipient_name
declare -a CLIENTS=(
  "Ascend LC|qms-guard|ascend-lc|riaan@ascendlc.co.za|Riaan"
  "Race Technik|chrome-auto-care|race-technik|racetechnik010@gmail.com|Farhaan"
)

for entry in "${CLIENTS[@]}"; do
  IFS='|' read -r name repo tag email recipient <<< "$entry"
  export "_DATA_${repo//-/_}"; eval "_DATA_${repo//-/_}=$(gather_client_data "$name" "$repo" "$tag")"
done

export _ASCEND_DATA;  _ASCEND_DATA=$(gather_client_data "Ascend LC" "qms-guard" "ascend-lc")
export _RACE_DATA;    _RACE_DATA=$(gather_client_data "Race Technik" "chrome-auto-care" "race-technik")

python3 - <<'PYDRAFTS'
import json, os, urllib.request, time

openai_key  = os.environ.get('_OPENAI_KEY', '')
wa_api      = os.environ.get('_WA_API', '')
josh_number = os.environ.get('_JOSH_NUMBER', '')
today       = os.environ.get('_TODAY', '')
send_date   = os.environ.get('_SEND_DATE', today)
week_end    = os.environ.get('_WEEK_END', '')
pending_file = os.environ.get('_PENDING_FILE', '')

# name, data, email, greeting, project_notes
clients = [
    ('Ascend LC',    os.environ.get('_ASCEND_DATA', ''), 'riaan@ascendlc.co.za',     'Hi Riaan and André,',    ''),
    ('Race Technik', os.environ.get('_RACE_DATA', ''),   'racetechnik010@gmail.com', 'Hi Yaseen and Farhaan,', 'The app is called the Race Technik app (never chrome-auto-care or Chrome Auto Care). The Mac Mini is called the Maya Mac Mini (never just Mac Mini).'),
]

def call_gpt(system, user, model='gpt-4o', max_tokens=500):
    payload = json.dumps({
        'model': model,
        'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user',   'content': user},
        ],
        'max_tokens': max_tokens,
        'temperature': 0.7,
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

def send_wa(message):
    payload = json.dumps({'to': josh_number, 'message': message}).encode()
    req = urllib.request.Request(f'{wa_api}/send', data=payload,
        headers={'Content-Type': 'application/json'}, method='POST')
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f'WA error: {e}')

def generate_email_body(name, greeting, project_notes, data):
    notes_clause = f' Additional naming rules: {project_notes}' if project_notes else ''
    # Step 1: GPT-4o writes its own system prompt for this specific client email
    system_prompt = call_gpt(
        'You are a prompt engineer specialising in human-sounding client communication. '
        'Your job is to write a system prompt that will be used to instruct GPT-4o to write a weekly client update email. '
        'The prompt must result in an email that sounds genuinely human, warm and direct — from a real person who knows the client well. '
        'No corporate language, no hollow filler phrases, no bullet points. No hyphens. '
        'The email must always open with the exact greeting provided — never skip it or replace it. '
        'Output only the system prompt text, nothing else.',
        f'Write a system prompt for GPT-4o to use when writing a weekly update email from Sophia (Amalfi AI client success manager) '
        f'to {name}. The email opens with the greeting "{greeting}". It covers what was built this week, project status, and what is coming next. '
        f'Max 130 words for the system prompt.{notes_clause}'
    )
    if not system_prompt:
        system_prompt = f'You are Sophia from Amalfi AI. Write a warm, direct, human weekly update email. Always open with "{greeting}". No hyphens. No filler. Max 200 words.{notes_clause}'

    # Step 2: use that generated prompt to write the actual email
    return call_gpt(
        system_prompt,
        f'Today: {today}\nClient: {name}\nGreeting to use: {greeting}\n\nProject data:\n{data[:2500]}\n\n'
        f'Write the email body only. No subject line. Open with the greeting exactly as given. Sign off as Sophia, Amalfi AI.',
        max_tokens=600
    )

# Generate drafts
pending = []
previews = []

cc_map = {
    'Ascend LC': 'andre@ascendlc.co.za',
}

for name, data, email, greeting, project_notes in clients:
    if not data.strip():
        print(f'No data for {name} — skipping')
        continue

    print(f'Generating draft for {name}...')
    body = generate_email_body(name, greeting, project_notes, data)
    if not body:
        print(f'GPT returned nothing for {name}')
        continue

    subject = f'Weekly Update — {name} — {send_date}'

    pending.append({
        'client':    name,
        'to':        email,
        'cc':        cc_map.get(name, ''),
        'recipient': recipient,
        'subject':   subject,
        'body':      body,
        'group_slug': {
            'Ascend LC':   'ascend-lc',
            'Race Technik': 'race-technik',
        }.get(name, ''),
    })

    # WhatsApp preview
    cc_line = f'\nCC: {cc_map.get(name, "")}' if cc_map.get(name) else ''
    preview = f'*{name}*\nTo: {email}{cc_line}\nSubject: {subject}\n\n{body}'
    previews.append(preview)
    time.sleep(2)

# Save pending drafts
with open(pending_file, 'w') as f:
    json.dump(pending, f, indent=2)

# Send WA preview to Josh
if previews:
    send_wa(f'📧 *Weekly Client Email Drafts — {today}*\n\nReview each below. Reply *"send it"* to fire all, or give me edits.')
    time.sleep(2)
    for i, preview in enumerate(previews, 1):
        send_wa(f'*Draft {i}/{len(previews)}*\n\n{preview}')
        time.sleep(3)
    send_wa(f'That\'s all {len(previews)} drafts. Reply *"send it"* to send all, or tell me what to change.')
else:
    send_wa('Weekly email drafts: no client data found this week.')

print(f'Done: {len(pending)} draft(s) saved and previewed on WhatsApp')
PYDRAFTS

log "Weekly email drafts complete"
