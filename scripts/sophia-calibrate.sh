#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# sophia-calibrate.sh
# Onboard a new client for Sophia in one Telegram conversation.
# Called by telegram-callback-poller.sh when /calibrate <slug> is received,
# or run directly: bash sophia-calibrate.sh <slug>
#
# Usage:
#   bash sophia-calibrate.sh new          → starts interactive wizard
#   bash sophia-calibrate.sh <slug>       → re-calibrate existing client
#   bash sophia-calibrate.sh list         → list all configured clients
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
OWNER_NAME="${AOS_OWNER_NAME:-Josh}"
COMPANY="${AOS_COMPANY:-Amalfi AI}"

ARG="${1:-new}"
LOG="$WS/out/sophia-calibrate.log"
mkdir -p "$WS/out" "$WS/tmp" "$WS/clients" "$WS/data"

# ── Helpers ───────────────────────────────────────────────────────────────────
tg_send() {
  local text="$1" parse_mode="${2:-HTML}"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$text"),\"parse_mode\":\"${parse_mode}\"}" \
    > /dev/null
}

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }

# ── List mode ─────────────────────────────────────────────────────────────────
if [[ "$ARG" == "list" ]]; then
  python3 - << 'PY'
import json, os
WS = os.environ.get('AOS_ROOT', '/Users/henryburton/.openclaw/workspace-anthropic')
f = f'{WS}/data/client-projects.json'
try:
    d = json.load(open(f))
    clients = d.get('clients', [])
    if not clients:
        print("No clients configured yet.")
    else:
        for c in clients:
            print(f"  • {c['slug']:20s} {c['name']:25s} [{c.get('retainer_status','?')}]")
except Exception as e:
    print(f"Could not read client-projects.json: {e}")
PY
  exit 0
fi

# ── Determine slug ────────────────────────────────────────────────────────────
if [[ "$ARG" == "new" ]]; then
  log "Starting new client calibration wizard"
  tg_send "🧠 <b>Sophia Calibration Wizard</b>

Let's onboard a new client. I'll ask you a few questions and build their full context profile.

Reply with their <b>company name</b> to start."

  # Write wizard state file — poller will detect and route follow-up messages
  cat > "$WS/tmp/calibrate-state-${CHAT_ID}.json" << STATEEOF
{"step": "company_name", "slug": null, "data": {}}
STATEEOF
  log "State file written — waiting for company name input"
  exit 0
fi

# Called with a slug directly — means we have data to write (from the poller accumulation)
SLUG="$ARG"

# ── Read accumulated calibration data ────────────────────────────────────────
STATE_FILE="$WS/tmp/calibrate-data-${CHAT_ID}.json"
if [[ ! -f "$STATE_FILE" ]]; then
  log "No calibration data found for $SLUG"
  tg_send "⚠️ No calibration data found. Start with /calibrate new"
  exit 1
fi

export STATE_FILE OPENAI_KEY OWNER_NAME COMPANY WS SLUG BOT_TOKEN CHAT_ID LOG

python3 - << 'PY'
import json, os, re, urllib.request, datetime

WS         = os.environ['WS']
SLUG       = os.environ['SLUG']
OPENAI_KEY = os.environ['OPENAI_KEY']
OWNER_NAME = os.environ['OWNER_NAME']
COMPANY    = os.environ['COMPANY']
BOT_TOKEN  = os.environ['BOT_TOKEN']
CHAT_ID    = os.environ['CHAT_ID']
LOG_PATH   = os.environ['LOG']
STATE_FILE = os.environ['STATE_FILE']

def log(msg):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    line = f'[{ts}] {msg}'
    print(line)
    with open(LOG_PATH, 'a') as f: f.write(line + '\n')

def tg(text):
    payload = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        data=payload, headers={'Content-Type': 'application/json'}
    )
    try: urllib.request.urlopen(req, timeout=10)
    except Exception as e: log(f'tg send failed: {e}')

def call_openai(prompt):
    if not OPENAI_KEY: return None
    body = json.dumps({'model': 'gpt-4o', 'messages': [{'role':'user','content':prompt}],
                       'temperature': 0.3}).encode()
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions', data=body,
        headers={'Authorization': f'Bearer {OPENAI_KEY}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())['choices'][0]['message']['content'].strip()
    except Exception as e:
        log(f'OpenAI failed: {e}')
        return None

try:
    data = json.load(open(STATE_FILE))
except Exception as e:
    log(f'Could not read state file: {e}')
    tg('⚠️ Calibration data missing. Start with /calibrate new')
    exit(1)

log(f'Writing calibration for {SLUG}')
log(f'Data keys: {list(data.keys())}')

name            = data.get('company_name', SLUG)
contact_name    = data.get('contact_name', '')
contact_email   = data.get('contact_email', '')
contact_role    = data.get('contact_role', '')
industry        = data.get('industry', '')
what_they_do    = data.get('what_they_do', '')
current_project = data.get('current_project', '')
email_tone      = data.get('email_tone', 'professional and warm')
key_priorities  = data.get('key_priorities', '')
retainer_status = data.get('retainer_status', 'project_only')
project_start   = data.get('project_start_date', datetime.date.today().isoformat())

# ── Generate CONTEXT.md via GPT ───────────────────────────────────────────────
today = datetime.date.today().strftime('%b %Y')
context_prompt = f"""Write a client context file for an AI assistant called Sophia who manages client relationships for {COMPANY}, an AI consulting firm run by {OWNER_NAME}.

Client details:
- Company: {name}
- Industry: {industry}
- What they do: {what_they_do}
- Primary contact: {contact_name} ({contact_role}) — {contact_email}
- Current project: {current_project}
- Email tone preference: {email_tone}
- Key priorities: {key_priorities}
- Relationship started: {project_start}

Write the CONTEXT.md using EXACTLY this structure (fill in all sections):

# Client Context — {name}

## The Business
[2-3 sentences about what they do, their market, their size/stage]

## Key People
- **{contact_name}** — {contact_role}

## What We're Building
[Description of the current project/engagement]

## Tone & Communication
[Communication style, how to address them, what they care about]

## What Matters to Them
[3-5 bullet points on their priorities]

## Current Focus ({today})
[Current work, where things stand]

## Relationship Status ({today})
[How the relationship is going, trust level, next milestone]

## Tech Notes
[Any technical notes relevant to the project, or "N/A" if not technical]

Write naturally and specifically. Do NOT use hyphens (-) in bullet points — use • instead."""

log('Generating CONTEXT.md with GPT-4o...')
context_md = call_openai(context_prompt)

if not context_md:
    # Fallback template
    context_md = f"""# Client Context — {name}

## The Business
{what_they_do}

## Key People
• **{contact_name}** — {contact_role} ({contact_email})

## What We're Building
{current_project}

## Tone & Communication
{email_tone}

## What Matters to Them
{key_priorities}

## Current Focus ({today})
Project in progress.

## Relationship Status ({today})
Newly onboarded. Building rapport.

## Tech Notes
N/A
"""

# ── Write CONTEXT.md ──────────────────────────────────────────────────────────
client_dir = f'{WS}/clients/{SLUG}'
os.makedirs(client_dir, exist_ok=True)
context_path = f'{client_dir}/CONTEXT.md'
with open(context_path, 'w') as f:
    f.write(context_md)
log(f'CONTEXT.md written to {context_path}')

# ── Update client-projects.json ───────────────────────────────────────────────
projects_file = f'{WS}/data/client-projects.json'
try:
    projects = json.load(open(projects_file))
except Exception:
    projects = {'clients': []}

clients = projects.get('clients', [])
# Remove existing entry for this slug if present
clients = [c for c in clients if c.get('slug') != SLUG]

clients.append({
    'slug': SLUG,
    'name': name,
    'email': contact_email,
    'retainer_status': retainer_status,
    'relationship_type': 'retainer' if retainer_status == 'retainer' else 'client',
    'project_start_date': project_start,
    'project_type': current_project[:80] if current_project else '',
    'retainer_nudge_sent': False,
})

projects['clients'] = clients
with open(projects_file, 'w') as f:
    json.dump(projects, f, indent=2)
log(f'client-projects.json updated — {len(clients)} clients')

# ── Update Sophia memory ──────────────────────────────────────────────────────
sophia_mem_path = f'{WS}/memory/sophia/memory.md'
os.makedirs(f'{WS}/memory/sophia', exist_ok=True)
try:
    existing_mem = open(sophia_mem_path).read() if os.path.exists(sophia_mem_path) else ''
except Exception:
    existing_mem = ''

new_entry = f"\n## {name} (slug: {SLUG}) — added {today}\n{email_tone}. Contact: {contact_name}. Project: {current_project[:80]}.\n"

if SLUG not in existing_mem:
    with open(sophia_mem_path, 'a') as f:
        f.write(new_entry)
    log('Sophia memory updated')

# ── Confirm ───────────────────────────────────────────────────────────────────
confirm = (
    f"✅ <b>{name} onboarded</b>\n\n"
    f"• CONTEXT.md written\n"
    f"• Added to client-projects.json\n"
    f"• Sophia memory updated\n\n"
    f"<b>Contact:</b> {contact_name} ({contact_role})\n"
    f"<b>Project:</b> {current_project[:80]}\n"
    f"<b>Status:</b> {retainer_status}\n\n"
    f"Sophia will use this context for all emails to {name}. "
    f"Update anytime with /calibrate {SLUG}"
)
tg(confirm)
log(f'Calibration complete for {SLUG}')

# Clean up state file
try: os.remove(STATE_FILE)
except Exception: pass
PY
