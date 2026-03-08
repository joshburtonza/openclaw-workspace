#!/usr/bin/env bash
# write-sophia-awareness.sh
# Runs every 30 min. Collects activity from CLI, WhatsApp, GitHub, Vercel,
# LaunchAgent logs and Supabase tasks, then writes memory/sophia-awareness.md
# so Sophia is fully aware of everything happening across all systems.

set -uo errexit

WS="/Users/henryburton/.openclaw/workspace-anthropic"
OUT="$WS/memory/sophia-awareness.md"
LOG="$WS/out/sophia-awareness.log"
export SUPABASE_SERVICE_ROLE_KEY=$(grep "^SUPABASE_SERVICE_ROLE_KEY=" "$WS/.env.scheduler" | cut -d= -f2-)
export SUPABASE_URL=$(grep "^SUPABASE_URL=" "$WS/.env.scheduler" | cut -d= -f2- | tr -d '\n')

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
log "write-sophia-awareness starting"

NOW=$(date '+%Y-%m-%d %H:%M')
TODAY=$(date '+%Y-%m-%d')

# ── Collect all sections in a temp file ────────────────────────────────────

TMPOUT=$(mktemp /tmp/awareness-XXXXXX)

cat >> "$TMPOUT" << HEADER
# Sophia Awareness Feed
_Generated: $NOW — refreshes every 30 min_

This is your real-time awareness of everything happening across all Amalfi AI systems.
Use this to answer questions about work in progress, recent deployments, system health,
and ongoing projects without needing to ask Josh what has been going on.

---
HEADER

# ── 1. RECENT CLI SESSIONS ─────────────────────────────────────────────────
cat >> "$TMPOUT" << 'SEC'
## Recent Claude Code Sessions
SEC

python3 << 'PYEOF' >> "$TMPOUT"
import json, os, glob, datetime

CLAUDE_BASE = os.path.expanduser('~/.claude/projects')
cutoff = datetime.datetime.now().timestamp() - 86400  # last 24h

# Gather all jsonl files modified in last 24h, sorted by mtime desc
all_files = sorted(
    [f for f in glob.glob(f'{CLAUDE_BASE}/*/*.jsonl') if os.path.getmtime(f) > cutoff],
    key=os.path.getmtime, reverse=True
)[:10]

if not all_files:
    print("_No CLI sessions in the last 24 hours._\n")
else:
    for fpath in all_files:
        proj = os.path.basename(os.path.dirname(fpath)).replace('-Users-henryburton--openclaw-workspace-anthropic-','').replace('-Users-henryburton--openclaw-workspace-anthropic','workspace').replace('-Users-henryburton-','~/')
        mtime = datetime.datetime.fromtimestamp(os.path.getmtime(fpath)).strftime('%H:%M')
        lines = open(fpath).readlines()
        msgs = []
        for l in reversed(lines):
            try:
                d = json.loads(l)
                if d.get('type') == 'user':
                    content = d.get('message', {}).get('content', '')
                    text = ''
                    if isinstance(content, list):
                        for item in content:
                            if isinstance(item, dict) and item.get('type') == 'text':
                                text = item.get('text', '').strip()
                                break
                    elif isinstance(content, str):
                        text = content.strip()
                    # skip system-reminder injected lines and very short messages
                    if text and len(text) > 8 and not text.startswith('<system') and not text.startswith('Called the'):
                        msgs.append(text)
                        if len(msgs) >= 3:
                            break
            except:
                pass
        if msgs:
            print(f"**{proj}** (last active {mtime})")
            for m in reversed(msgs):
                snippet = m[:160].replace('\n', ' ')
                print(f"  - {snippet}")
            print()
PYEOF

# ── 2. GITHUB — recent commits across all repos ─────────────────────────
cat >> "$TMPOUT" << 'SEC'
## GitHub — Recent Commits
SEC

REPOS=(
  "$WS"
  "$WS/mission-control-hub"
  "$WS/qms-guard"
  "$WS/chrome-auto-care"
  "$WS/favorite-flow-9637aff2"
  "$WS/clients/vanta-studios/vanta-mission-control"
)

for REPO in "${REPOS[@]}"; do
  if [ -d "$REPO/.git" ]; then
    RNAME=$(basename "$REPO")
    COMMITS=$(git -C "$REPO" log --oneline --since="48 hours ago" --format="%h %s (%cr)" 2>/dev/null | head -4)
    if [ -n "$COMMITS" ]; then
      echo "**$RNAME**" >> "$TMPOUT"
      echo "$COMMITS" | while IFS= read -r line; do echo "  - $line" >> "$TMPOUT"; done
      echo "" >> "$TMPOUT"
    fi
  fi
done

# ── 3. VERCEL — recent deployments ─────────────────────────────────────
cat >> "$TMPOUT" << 'SEC'
## Vercel — Recent Deployments
SEC

/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/vercel/dist/index.js ls --scope joshuaburton096-gmailcoms-projects 2>/dev/null | head -15 >> "$TMPOUT" || echo "_Vercel deploy info unavailable_" >> "$TMPOUT"
echo "" >> "$TMPOUT"

# ── 4. LAUNCHAGENT ACTIVITY — key system logs ───────────────────────────
cat >> "$TMPOUT" << 'SEC'
## Active System Agents — Recent Activity
SEC

for LOGNAME in \
  "WhatsApp-Gateway:$WS/out/whatsapp-wjs-gateway.log" \
  "Telegram-Poller:$WS/out/telegram-poller.log" \
  "Task-Worker:$WS/out/claude-task-worker.log" \
  "ROS-Watchdog:$WS/out/ros-watchdog.log" \
  "Sophia-Mark-Monitor:$WS/out/sophia-mark-monitor.log" \
  "Apollo-Sourcer:$WS/out/apollo-sourcer.log" \
  "Alex-Outreach:$WS/out/alex-outreach.log" \
  "CSM-Supervisor:$WS/out/csm-supervisor.log" \
  "Error-Monitor:$WS/out/error-monitor.log" \
  "Reminder-Dispatcher:$WS/out/reminder-dispatcher.log"
do
  _NAME="${LOGNAME%%:*}"
  _FILE="${LOGNAME#*:}"
  if [ -f "$_FILE" ]; then
    _LAST=$(tail -2 "$_FILE" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
    if [ -n "$_LAST" ]; then
      echo "**$_NAME:** $_LAST" >> "$TMPOUT"
    fi
  fi
done
echo "" >> "$TMPOUT"

# ── 5. ERRORS — .err.log files with recent content ──────────────────────
cat >> "$TMPOUT" << 'SEC'
## Recent Errors (last 24h)
SEC

ERROR_OUT=$(find "$WS/out" -name "*.err.log" -mmin -1440 -size +0c 2>/dev/null | while read -r EFILE; do
  AGENT=$(basename "$EFILE" .err.log)
  # Filter out the universal Chrome path noise — not a real error
  SNIPPET=$(grep -v "Chrome: command not found" "$EFILE" 2>/dev/null | tail -3 | tr '\n' ' ' | cut -c1-250)
  if [ -n "$(echo "$SNIPPET" | tr -d ' ')" ]; then
    echo "**$AGENT:** $SNIPPET"
  fi
done)
if [ -n "$ERROR_OUT" ]; then
  echo "$ERROR_OUT" >> "$TMPOUT"
else
  echo "_No new errors in the last 24 hours_" >> "$TMPOUT"
fi
echo "" >> "$TMPOUT"

# ── 6. SUPABASE TASKS — current task list ───────────────────────────────
cat >> "$TMPOUT" << 'SEC'
## Active Tasks (Supabase)
SEC

python3 << PYEOF >> "$TMPOUT"
import urllib.request, json, os

url = os.environ.get('SUPABASE_URL', '') or 'https://afmpbtynucpbglwtbfuz.supabase.co'
key = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')

try:
    req = urllib.request.Request(
        f"{url}/rest/v1/tasks?status=in.(todo,in_progress)&order=priority.desc,created_at.asc&limit=10",
        headers={'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json'}
    )
    data = json.loads(urllib.request.urlopen(req, timeout=8).read())
    if data:
        for t in data:
            status = t.get('status','')
            priority = t.get('priority','normal')
            title = t.get('title','?')
            assigned = t.get('assigned_to','')
            icon = '🔴' if priority == 'urgent' else ('🟡' if priority == 'high' else '⚪')
            print(f"{icon} [{status}] {title}" + (f" — {assigned}" if assigned else ""))
    else:
        print("_No active tasks_")
except Exception as e:
    print(f"_Tasks unavailable: {e}_")
PYEOF
echo "" >> "$TMPOUT"

# ── 7. WHATSAPP STATS — today's conversation volume ────────────────────
cat >> "$TMPOUT" << 'SEC'
## WhatsApp — Today's Activity
SEC

python3 << PYEOF >> "$TMPOUT"
import os, json, glob

WS = '/Users/henryburton/.openclaw/workspace-anthropic'
hist_dir = os.path.join(WS, 'memory', 'sophia', 'history') if os.path.isdir(os.path.join(WS, 'memory', 'sophia', 'history')) else os.path.join(WS, 'memory')

today = __import__('datetime').date.today().isoformat()
total_msgs = 0
active_chats = []

seen = set()
all_files = []
for pat in [f'{hist_dir}/**/*.jsonl', f'{hist_dir}/*.jsonl']:
    for p in glob.glob(pat, recursive=True):
        rp = os.path.realpath(p)
        if rp not in seen:
            seen.add(rp)
            all_files.append(p)

for f in all_files:
    try:
        msgs = [json.loads(l) for l in open(f).readlines() if l.strip()]
        today_msgs = [m for m in msgs if m.get('ts','').startswith(today)]
        if today_msgs:
            name = os.path.basename(f).replace('.jsonl','')
            active_chats.append(f"{name} ({len(today_msgs)} msgs)")
            total_msgs += len(today_msgs)
    except:
        pass

if active_chats:
    print(f"Total messages today: {total_msgs}")
    for c in active_chats:
        print(f"  - {c}")
else:
    print("_No WhatsApp conversations yet today_")
PYEOF
echo "" >> "$TMPOUT"

# ── 8. DEV STATUS — client project states ──────────────────────────────
cat >> "$TMPOUT" << 'SEC'
## Client Dev Status
SEC

if [ -f "$WS/DEV_STATUS.md" ]; then
  head -40 "$WS/DEV_STATUS.md" >> "$TMPOUT"
else
  echo "_DEV_STATUS.md not yet generated_" >> "$TMPOUT"
fi
echo "" >> "$TMPOUT"

# ── Write output ─────────────────────────────────────────────────────────
mv "$TMPOUT" "$OUT"
log "sophia-awareness.md written ($(wc -l < "$OUT") lines)"
