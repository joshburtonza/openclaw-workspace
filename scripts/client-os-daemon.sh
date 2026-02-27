#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# client-os-daemon.sh
# Runs on CLIENT Mac Mini (Race Technik, Vanta Studios, etc.)
# Every 5 min:
#   1. Reports heartbeat to Amalfi AI's master Supabase
#   2. Reads kill-switch status for this client
#   3. Loads or unloads agents based on: active / paused / stopped
#
# status = active  → all agents run normally
# status = paused  → outbound agents unloaded (Sophia/Alex/tasks stop)
#                    passive agents (morning brief, monitoring) stay up
# status = stopped → ALL agents unloaded. Nothing runs except this daemon.
#
# This daemon itself is KeepAlive=true — it CANNOT be killed by a status change.
# Client cannot bypass the kill switch without deleting this script.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/$(whoami)/.amalfiai/workspace}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

# ── Client identity (set in aos.env on client machine) ──────────────────────
CLIENT_SLUG="${AOS_CLIENT_SLUG:-unknown}"

# ── Master Supabase (Amalfi AI's — NOT client's own Supabase) ───────────────
MASTER_URL="${AOS_MASTER_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
MASTER_KEY="${AOS_MASTER_SERVICE_KEY:-}"

LOG="$WS/out/client-os-daemon.log"
mkdir -p "$WS/out"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

if [[ "$CLIENT_SLUG" == "unknown" || -z "$MASTER_KEY" ]]; then
  log "ERROR: AOS_CLIENT_SLUG or AOS_MASTER_SERVICE_KEY not set — daemon inactive"
  exit 0
fi

HOSTNAME_LABEL=$(hostname 2>/dev/null || echo "unknown")
PLIST_DIR="$HOME/Library/LaunchAgents"

export CLIENT_SLUG MASTER_URL MASTER_KEY WS PLIST_DIR HOSTNAME_LABEL LOG

python3 << 'PY'
import json, os, subprocess, urllib.request, urllib.parse, datetime

CLIENT_SLUG    = os.environ['CLIENT_SLUG']
MASTER_URL     = os.environ['MASTER_URL']
MASTER_KEY     = os.environ['MASTER_KEY']
WS             = os.environ['WS']
PLIST_DIR      = os.environ['PLIST_DIR']
HOSTNAME_LABEL = os.environ['HOSTNAME_LABEL']
LOG_PATH       = os.environ['LOG']

def log(msg):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    line = f'[{ts}] {msg}'
    print(line, flush=True)
    with open(LOG_PATH, 'a') as f: f.write(line + '\n')

def supa(method, path, data=None):
    url = f"{MASTER_URL}/rest/v1/{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method, headers={
        'apikey': MASTER_KEY,
        'Authorization': f'Bearer {MASTER_KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=representation',
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read()) if r.read else []
    except Exception as e:
        log(f'Supabase {method} failed ({path[:50]}): {e}')
        return None

# ── 1. Report heartbeat, read status ─────────────────────────────────────────
now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
result = supa('PATCH',
    f'client_os_registry?slug=eq.{CLIENT_SLUG}',
    {'last_heartbeat': now_iso, 'mac_hostname': HOSTNAME_LABEL}
)

rows = supa('GET', f'client_os_registry?slug=eq.{CLIENT_SLUG}&select=status,name')
if not rows:
    log(f'Client {CLIENT_SLUG} not found in registry — staying active')
    exit(0)

status = rows[0].get('status', 'active')
name   = rows[0].get('name', CLIENT_SLUG)
log(f'{name} status: {status}')

# ── Agent groups ──────────────────────────────────────────────────────────────
# OUTBOUND: stops when paused or stopped
OUTBOUND_AGENTS = [
    'com.amalfiai.sophia-outbound',
    'com.amalfiai.sophia-cron',
    'com.amalfiai.sophia-followup',
    'com.amalfiai.alex-outreach',
    'com.amalfiai.alex-reply-detection',
    'com.amalfiai.research-implement',
    'com.amalfiai.research-digest',
    'com.amalfiai.enrich-leads',
    'com.raceai.sophia-outbound',  # Race OS equivalents
    'com.raceai.rt-crm-cron',
    'com.raceai.research-implement',
]

# PASSIVE: stops only when stopped (not paused)
PASSIVE_AGENTS = [
    'com.amalfiai.morning-brief',
    'com.amalfiai.meet-notes-poller',
    'com.amalfiai.error-monitor',
    'com.amalfiai.memory-writer',
    'com.amalfiai.data-os-sync',
    'com.raceai.morning-brief',
    'com.raceai.error-monitor',
]

# PROTECTED: never touched — keeps system alive for resumption
PROTECTED = {
    'com.amalfiai.client-os-daemon',
    'com.raceai.client-os-daemon',
    'com.amalfiai.telegram-poller',
    'com.raceai.telegram-poller',
    'com.amalfiai.keepawake',
    'com.raceai.keepawake',
}

def is_loaded(label):
    r = subprocess.run(['launchctl', 'list', label], capture_output=True, text=True)
    return r.returncode == 0

def load_agent(label):
    if is_loaded(label): return
    plist = f'{PLIST_DIR}/{label}.plist'
    ws_plist = f'{WS}/launchagents/{label}.plist'
    if not os.path.exists(plist):
        plist = ws_plist
    if not os.path.exists(plist): return
    subprocess.run(['launchctl', 'load', plist], capture_output=True)
    log(f'  [load] {label}')

def unload_agent(label):
    if not is_loaded(label): return
    plist = f'{PLIST_DIR}/{label}.plist'
    ws_plist = f'{WS}/launchagents/{label}.plist'
    if not os.path.exists(plist):
        plist = ws_plist
    subprocess.run(['launchctl', 'unload', plist], capture_output=True)
    log(f'  [unload] {label}')

changes = 0

if status == 'active':
    # Resume everything that was stopped
    for label in OUTBOUND_AGENTS + PASSIVE_AGENTS:
        if label in PROTECTED: continue
        if not is_loaded(label):
            load_agent(label)
            changes += 1

elif status == 'paused':
    # Stop outbound, keep passive
    for label in OUTBOUND_AGENTS:
        if label in PROTECTED: continue
        if is_loaded(label):
            unload_agent(label)
            changes += 1

elif status == 'stopped':
    # Stop everything except protected daemons
    for label in OUTBOUND_AGENTS + PASSIVE_AGENTS:
        if label in PROTECTED: continue
        if is_loaded(label):
            unload_agent(label)
            changes += 1

if changes:
    log(f'Applied {changes} change(s) for status={status}')
else:
    log(f'No changes needed (status={status})')
PY
