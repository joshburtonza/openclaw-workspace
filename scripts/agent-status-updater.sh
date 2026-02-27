#!/bin/bash
# agent-status-updater.sh
# Runs every 30 min. Checks each agent's log file for recent activity
# and writes live status back to the Supabase agents table.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

export SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
export API_KEY="${SUPABASE_SERVICE_ROLE_KEY}"
export WS

python3 - <<'PY'
import os, time, datetime, subprocess, json, urllib.parse

SUPABASE_URL = os.environ['SUPABASE_URL']
API_KEY      = os.environ['API_KEY']
WS           = os.environ['WS']
NOW          = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

ONLINE_THRESHOLD = 3600    # 1 hour
IDLE_THRESHOLD   = 86400   # 24 hours

# DB agent name -> list of log files to check (freshest wins)
AGENT_LOGS = {
    'Sophia CSM': [
        f'{WS}/out/sophia-cron.log',
        f'{WS}/out/sophia-followup.log',
        f'{WS}/out/email-response-scheduler.log',
    ],
    'Alex Outreach': [
        f'{WS}/out/alex-outreach.log',
        f'{WS}/out/alex-reply-detection.log',
    ],
    'System Monitor': [
        f'{WS}/out/heartbeat.log',
        f'{WS}/out/error-monitor.log',
    ],
    'Repo Watcher': [
        f'{WS}/out/activity-tracker.log',
        f'{WS}/out/daily-repo-sync.log',
    ],
    'Video Bot': [
        f'{WS}/out/morning-video-scripts.log',
    ],
    'Alex Claww': [
        f'{WS}/out/claude-task-worker.log',
        f'{WS}/out/research-implement.log',
    ],
    'Sophia Outbound': [
        f'{WS}/logs/sophia-outbound.log',
    ],
}

AGENT_ROLES = {
    'Sophia CSM':      'csm',
    'Alex Outreach':   'outreach',
    'System Monitor':  'monitor',
    'Repo Watcher':    'automation',
    'Video Bot':       'automation',
    'Alex Claww':      'automation',
    'Sophia Outbound': 'csm',
}

AGENT_TASKS = {
    'Sophia CSM':      'Monitoring client inboxes and sending responses',
    'Alex Outreach':   'Cold outreach sequences and reply detection',
    'System Monitor':  'Heartbeat checks and error monitoring',
    'Repo Watcher':    'Tracking repo activity and syncing code',
    'Video Bot':       'Generating daily video scripts',
    'Alex Claww':      'Processing autonomous research and implementation tasks',
    'Sophia Outbound': 'Outbound lead intro emails and meeting bookings',
}

def log_age_and_mtime(logs):
    now_ts = time.time()
    best_age = 999999
    best_mtime = None
    for lf in logs:
        if os.path.exists(lf):
            mt = os.path.getmtime(lf)
            age = now_ts - mt
            if age < best_age:
                best_age = age
                best_mtime = mt
    if best_mtime:
        dt = datetime.datetime.utcfromtimestamp(best_mtime)
        return best_age, dt.strftime('%Y-%m-%dT%H:%M:%SZ')
    return 999999, NOW

def derive_status(age):
    if age < ONLINE_THRESHOLD:
        return 'online'
    elif age < IDLE_THRESHOLD:
        return 'idle'
    return 'offline'

def upsert_agent(name, role, status, last_activity, current_task):
    patch_payload = {
        'status':        status,
        'last_activity': last_activity,
        'current_task':  current_task,
        'updated_at':    NOW,
    }
    insert_payload = dict(patch_payload, name=name, role=role)
    encoded_name = urllib.parse.quote(name)

    # Try PATCH first (update existing row by name)
    r = subprocess.run([
        'curl', '-s', '-X', 'PATCH',
        f"{SUPABASE_URL}/rest/v1/agents?name=eq.{encoded_name}",
        '-H', 'Content-Type: application/json',
        '-H', 'Prefer: return=representation',
        '-H', f"apikey: {API_KEY}",
        '-H', f"Authorization: Bearer {API_KEY}",
        '-d', json.dumps(patch_payload),
    ], capture_output=True, text=True)

    # If no row existed, insert
    if r.stdout.strip() in ('[]', ''):
        subprocess.run([
            'curl', '-s', '-X', 'POST',
            f"{SUPABASE_URL}/rest/v1/agents",
            '-H', 'Content-Type: application/json',
            '-H', f"apikey: {API_KEY}",
            '-H', f"Authorization: Bearer {API_KEY}",
            '-d', json.dumps(insert_payload),
        ], capture_output=True)

    return r.returncode == 0

for agent_name, logs in AGENT_LOGS.items():
    age, last_act = log_age_and_mtime(logs)
    status = derive_status(age)
    role   = AGENT_ROLES[agent_name]
    task   = AGENT_TASKS[agent_name]

    ok = upsert_agent(agent_name, role, status, last_act, task)
    age_str = f"{int(age/60)}m" if age < 3600 else f"{int(age/3600)}h"
    print(f"[agent-status] {agent_name:20s} -> {status:8s} (last seen {age_str} ago) {'OK' if ok else 'FAIL'}")

print(f"[agent-status] Done at {NOW}")
PY
