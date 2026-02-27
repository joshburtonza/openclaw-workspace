#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agent-toggle-daemon.sh
# Reads agent_enabled_* keys from Supabase system_config and loads/unloads
# LaunchAgents accordingly. Runs every 5 min via LaunchAgent.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
LOG="$WS/out/agent-toggle.log"
PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$WS/out"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

export _SUPA_URL="$SUPABASE_URL" _SUPA_KEY="$KEY" _WS="$WS"

log "Checking agent toggle states..."

python3 << 'PY'
import json, os, subprocess, urllib.request

SUPABASE_URL = os.environ.get('_SUPA_URL','')
KEY          = os.environ.get('_SUPA_KEY','')
WS           = os.environ.get('_WS', '/Users/henryburton/.openclaw/workspace-anthropic')

agent_map = {
    'agent_enabled_sophia':          ['com.amalfiai.sophia-outbound', 'com.amalfiai.sophia-cron', 'com.amalfiai.sophia-followup'],
    'agent_enabled_alex':            ['com.amalfiai.alex-outreach', 'com.amalfiai.alex-reply-detection'],
    'agent_enabled_task_worker':     ['com.amalfiai.research-implement'],
    'agent_enabled_meet_intel':      ['com.amalfiai.meet-notes-poller'],
    'agent_enabled_morning_brief':   ['com.amalfiai.morning-brief'],
    'agent_enabled_research_digest': ['com.amalfiai.research-digest'],
}

# Fetch config rows
config = {}
try:
    url = f"{SUPABASE_URL}/rest/v1/system_config?key=like.agent_enabled_*&select=key,value"
    req = urllib.request.Request(url, headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'})
    with urllib.request.urlopen(req, timeout=10) as r:
        rows = json.loads(r.read())
    for row in rows:
        k = row.get('key','')
        v = row.get('value','true')
        try:
            parsed = json.loads(v)
            config[k] = bool(parsed) if isinstance(parsed, bool) else (str(parsed).lower() == 'true')
        except Exception:
            config[k] = (v.strip().lower() == 'true')
    print(f'Loaded {len(config)} config entries')
except Exception as e:
    print(f'Config fetch failed: {e} — assuming all enabled')

plist_dir = os.path.expanduser('~/Library/LaunchAgents')

def is_loaded(label):
    r = subprocess.run(['launchctl', 'list', label], capture_output=True, text=True)
    return r.returncode == 0

def load_agent(label):
    plist = f'{plist_dir}/{label}.plist'
    if not os.path.exists(plist):
        plist = f'{WS}/launchagents/{label}.plist'
    if not os.path.exists(plist):
        print(f'  [warn] plist not found for {label}')
        return
    r = subprocess.run(['launchctl', 'load', plist], capture_output=True, text=True)
    print(f'  [load] {label} → rc={r.returncode}')

def unload_agent(label):
    plist = f'{plist_dir}/{label}.plist'
    if not os.path.exists(plist):
        plist = f'{WS}/launchagents/{label}.plist'
    r = subprocess.run(['launchctl', 'unload', plist], capture_output=True, text=True)
    print(f'  [unload] {label} → rc={r.returncode}')

changes = 0
for config_key, labels in agent_map.items():
    enabled = config.get(config_key, True)
    for label in labels:
        loaded = is_loaded(label)
        if enabled and not loaded:
            load_agent(label)
            changes += 1
        elif not enabled and loaded:
            unload_agent(label)
            changes += 1

print(f'[agent-toggle] Applied {changes} change(s)' if changes else '[agent-toggle] No changes needed')
PY

log "Done."
