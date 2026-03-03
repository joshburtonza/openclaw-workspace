#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/kill-switch.sh
# AOS client kill switch — pause or resume individual client services.
#
# Uses the `clients` table in AOS Supabase (already exists).
# status: 'active' | 'paused' | 'archived'
#   active   → everything runs normally
#   paused   → outbound agents skip this client, web app shows maintenance page
#   archived → fully stopped (used post-contract, not for billing pause)
#
# Usage:
#   kill-switch.sh <client_key> pause   [message]   # invoice overdue
#   kill-switch.sh <client_key> resume              # invoice paid
#   kill-switch.sh <client_key> status              # query current state
#   kill-switch.sh list                             # show all clients + status
#
# client_key: any known identifier (flexible):
#   ascend_lc | qms-guard | ascend-lc | ascend    → ascend_lc
#   race_technik | race-technik | chrome-auto-care  → race_technik
#   favorite_logistics | favorite-flow | favlog     → favorite_logistics
#   metal_solutions | metal-solutions | rt-metal    → metal_solutions
#   vanta_studios | vanta                           → vanta_studios
#
# What gets paused:
#   Web app: BillingGate checks clients.status on load → shows maintenance page
#   AOS task worker: research-implement.sh skips tasks for paused clients
#   Sophia: sophia-context.sh returns early for paused clients
#   Race Technik Mac Mini: SSH-triggered immediate agent unload
#
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WS="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$WS/.env.scheduler" ]] && set -a && source "$WS/.env.scheduler" && set +a

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SVC_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
export SUPABASE_URL SVC_KEY BOT_TOKEN CHAT_ID

log() { echo "[kill-switch] $*"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: kill-switch.sh <client_key|list> <pause|resume|status> [message]"
  exit 1
fi

RAW_KEY="$1"
ACTION="${2:-status}"
PAUSE_MSG="${3:-}"

# ── Normalise any client identifier → canonical slug ─────────────────────────
normalise_slug() {
  local key
  key=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  case "$key" in
    ascend_lc|ascend-lc|qms-guard|qmsguard|qms_guard|ascend)
      echo "ascend_lc" ;;
    race_technik|race-technik|chrome-auto-care|chrome_auto_care|rt|racetech|race)
      echo "race_technik" ;;
    favorite_logistics|favorite-logistics|favorite-flow|favlog|flair|favorite_flow|fav)
      echo "favorite_logistics" ;;
    metal_solutions|metal-solutions|rt-metal|rt_metal|luxe|luxe-living|metal)
      echo "metal_solutions" ;;
    vanta_studios|vanta-studios|vanta)
      echo "vanta_studios" ;;
    *) echo "$key" ;;
  esac
}

client_display_name() {
  case "$1" in
    ascend_lc)          echo "Ascend LC (QMS Guard)" ;;
    race_technik)        echo "Race Technik" ;;
    favorite_logistics)  echo "Favorite Logistics (FLAIR)" ;;
    metal_solutions)     echo "RT Metal / Luxe Living" ;;
    vanta_studios)       echo "Vanta Studios" ;;
    *)                   echo "$1" ;;
  esac
}

# ── List all clients ──────────────────────────────────────────────────────────
if [[ "$RAW_KEY" == "list" ]]; then
  python3 - <<PY
import urllib.request, json, os

URL = os.environ.get('SUPABASE_URL', 'https://afmpbtynucpbglwtbfuz.supabase.co')
KEY = os.environ.get('SVC_KEY', '')
req = urllib.request.Request(
    f"{URL}/rest/v1/clients?select=slug,name,status&order=name",
    headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'}
)
with urllib.request.urlopen(req, timeout=10) as r:
    rows = json.loads(r.read())

print(f"\n{'CLIENT':<35} {'SLUG':<25} STATUS")
print('-' * 70)
for row in rows:
    status = row.get('status', '?')
    icon = '✅' if status == 'active' else ('⏸' if status == 'paused' else '🗄')
    print(f"{row['name']:<35} {row['slug']:<25} {icon} {status}")
print()
PY
  exit 0
fi

export SUPABASE_URL SVC_KEY

SLUG="$(normalise_slug "$RAW_KEY")"
DISPLAY_NAME="$(client_display_name "$SLUG")"

log "Client: $DISPLAY_NAME ($SLUG)  Action: $ACTION"

# ── Execute action ────────────────────────────────────────────────────────────
export _KS_SLUG="$SLUG" _KS_ACTION="$ACTION" _KS_MSG="$PAUSE_MSG"

RESULT=$(python3 - <<'PY'
import urllib.request, json, os, sys, datetime

URL    = os.environ.get('SUPABASE_URL',    'https://afmpbtynucpbglwtbfuz.supabase.co')
KEY    = os.environ.get('SVC_KEY',         '')
SLUG   = os.environ.get('_KS_SLUG',        '')
ACTION = os.environ.get('_KS_ACTION',      'status')
MSG    = os.environ.get('_KS_MSG',         '')

def supa(method, path, data=None):
    url  = f"{URL}/rest/v1/{path}"
    body = json.dumps(data).encode() if data else None
    hdrs = {'apikey': KEY, 'Authorization': f'Bearer {KEY}',
            'Content-Type': 'application/json', 'Prefer': 'return=representation'}
    req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode()
        print(f"ERROR: Supabase {method} {path[:60]}: {e.code} {body_txt[:200]}", file=sys.stderr)
        return None

# Query current state
rows = supa('GET', f'clients?slug=eq.{SLUG}&select=id,slug,name,status,notes')
if not rows:
    print(f"ERROR: Client '{SLUG}' not found in clients table")
    sys.exit(1)

row = rows[0]
current_status = row.get('status', 'active')
current_name   = row.get('name', SLUG)

if ACTION == 'status':
    print(f"STATUS: {current_status}")
    notes = row.get('notes') or ''
    if 'PAUSE_MSG:' in notes:
        for line in notes.split('\n'):
            if line.startswith('PAUSE_MSG:'):
                print(f"MESSAGE: {line[10:].strip()}")
    sys.exit(0)

now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
notes   = row.get('notes') or ''

if ACTION == 'pause':
    # Prepend pause message to notes
    pause_msg = MSG or 'Service temporarily paused. Contact Amalfi AI to resolve.'
    # Remove any existing PAUSE_MSG line
    notes_clean = '\n'.join(l for l in notes.split('\n') if not l.startswith('PAUSE_MSG:'))
    new_notes = f"PAUSE_MSG:{pause_msg}\n[{now_iso[:10]}] PAUSED by AOS kill-switch\n{notes_clean}".strip()
    result = supa('PATCH', f'clients?slug=eq.{SLUG}', {
        'status': 'paused',
        'notes':  new_notes,
        'updated_at': now_iso,
    })
    print(f"PAUSED: {current_name}")

elif ACTION == 'resume':
    # Remove PAUSE_MSG from notes
    notes_clean = '\n'.join(l for l in notes.split('\n') if not l.startswith('PAUSE_MSG:'))
    new_notes = f"[{now_iso[:10]}] RESUMED by AOS kill-switch\n{notes_clean}".strip()
    result = supa('PATCH', f'clients?slug=eq.{SLUG}', {
        'status': 'active',
        'notes':  new_notes,
        'updated_at': now_iso,
    })
    print(f"RESUMED: {current_name}")

else:
    print(f"ERROR: Unknown action '{ACTION}'. Use: pause / resume / status")
    sys.exit(1)
PY
)

log "$RESULT"

if echo "$RESULT" | grep -q "^ERROR:"; then
  log "Kill switch failed — see error above"
  exit 1
fi

# ── Race Technik: SSH to Mac Mini for immediate agent control ─────────────────
if [[ "$SLUG" == "race_technik" ]]; then
  RT_SSH="raceai@100.114.191.52"
  log "Race Technik: triggering immediate agent update on Mac Mini..."

  if [[ "$ACTION" == "pause" ]]; then
    # Unload all outbound com.raceai.* agents immediately
    ssh -i ~/.ssh/race_technik -o ConnectTimeout=10 -o BatchMode=yes "$RT_SSH" \
      'for plist in ~/Library/LaunchAgents/com.raceai.research-implement.plist ~/Library/LaunchAgents/com.raceai.rt-crm-cron.plist ~/Library/LaunchAgents/com.raceai.lead-followup-cron.plist ~/Library/LaunchAgents/com.raceai.review-request-cron.plist ~/Library/LaunchAgents/com.raceai.sophia-cron.plist 2>/dev/null; do [ -f "$plist" ] && launchctl unload "$plist" 2>/dev/null && echo "Unloaded: $plist"; done' \
      2>&1 | head -20 || log "RT Mac Mini SSH failed — will need manual intervention"

  elif [[ "$ACTION" == "resume" ]]; then
    # Reload all outbound com.raceai.* agents
    ssh -i ~/.ssh/race_technik -o ConnectTimeout=10 -o BatchMode=yes "$RT_SSH" \
      'for plist in ~/Library/LaunchAgents/com.raceai.research-implement.plist ~/Library/LaunchAgents/com.raceai.rt-crm-cron.plist ~/Library/LaunchAgents/com.raceai.lead-followup-cron.plist ~/Library/LaunchAgents/com.raceai.review-request-cron.plist ~/Library/LaunchAgents/com.raceai.sophia-cron.plist 2>/dev/null; do [ -f "$plist" ] && launchctl load "$plist" 2>/dev/null && echo "Loaded: $plist"; done' \
      2>&1 | head -20 || log "RT Mac Mini SSH failed — daemon will pick up next heartbeat"
  fi
fi

# ── Telegram notification ─────────────────────────────────────────────────────
if [[ -n "$BOT_TOKEN" ]]; then
  case "$ACTION" in
    pause)  EMOJI="⏸"; STATUS_LABEL="PAUSED" ;;
    resume) EMOJI="▶️"; STATUS_LABEL="RESUMED" ;;
    *)      EMOJI="ℹ️"; STATUS_LABEL="STATUS" ;;
  esac

  MSG_LINE=""
  [[ -n "$PAUSE_MSG" ]] && MSG_LINE="
<i>${PAUSE_MSG}</i>"

  if [[ "$ACTION" == "pause" ]]; then
    EFFECT="Web app → maintenance page\nAOS agents → skipping this client\nSophia → not engaging"
    [[ "$SLUG" == "race_technik" ]] && EFFECT="${EFFECT}\nRT Mac Mini → outbound agents unloaded"
  else
    EFFECT="Web app → back online\nAll agents → resumed"
  fi

  TG_TEXT="${EMOJI} Kill Switch — <b>${STATUS_LABEL}</b>

<b>${DISPLAY_NAME}</b>${MSG_LINE}

${EFFECT}"

  export _KS_BOT="$BOT_TOKEN" _KS_CHAT="$CHAT_ID" _KS_TXT="$TG_TEXT"
  python3 - <<'PYEOF'
import urllib.request, json, os
urllib.request.urlopen(urllib.request.Request(
    f"https://api.telegram.org/bot{os.environ['_KS_BOT']}/sendMessage",
    data=json.dumps({'chat_id': os.environ['_KS_CHAT'], 'text': os.environ['_KS_TXT'],
                     'parse_mode': 'HTML'}).encode(),
    headers={'Content-Type': 'application/json'}, method='POST',
), timeout=10)
PYEOF
fi

log "Done"
