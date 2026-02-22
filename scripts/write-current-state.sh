#!/usr/bin/env bash
# write-current-state.sh — generates CURRENT_STATE.md with live system snapshot
# Runs nightly at 01:00 UTC (03:00 SAST) via LaunchAgent
# Output is read by telegram-claude-system.md for rich context
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
OUT_FILE="$WORKSPACE/CURRENT_STATE.md"

source "$ENV_FILE"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
KEY="${SUPABASE_SERVICE_ROLE_KEY}"
NOW_UTC=$(date -u +"%Y-%m-%d %H:%M UTC")
TODAY=$(date -u +"%Y-%m-%d")

exec > /tmp/current-state-build.txt 2>&1

echo "Building CURRENT_STATE.md at $NOW_UTC"

# ── Agent health ──────────────────────────────────────────────────────────────
AGENT_STATUS=$(launchctl list 2>/dev/null | grep "com.amalfiai" | while read pid status label; do
  icon="✅"
  [[ "$status" != "0" && "$status" != "-" ]] && icon="⚠️"
  printf "  %s %s (exit %s)\n" "$icon" "${label#com.amalfiai.}" "$status"
done)

# ── Email queue stats ─────────────────────────────────────────────────────────
EQ_STATS=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?select=status,created_at&order=created_at.desc&limit=50" \
  -H "apikey: $KEY" \
  -H "Authorization: Bearer $KEY" | \
  python3 -c '
import json, sys, os
from datetime import datetime, timezone

rows = json.loads(sys.stdin.read()) or []
today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
counts = {}
today_counts = {}
for r in rows:
    s = r.get("status","?")
    counts[s] = counts.get(s,0) + 1
    created = r.get("created_at","")
    if created.startswith(today):
        today_counts[s] = today_counts.get(s,0) + 1

lines = []
for s, n in sorted(counts.items()):
    t = today_counts.get(s,0)
    suffix = f" ({t} today)" if t else ""
    lines.append(f"  {s}: {n}{suffix}")
print("\n".join(lines) if lines else "  (no rows)")
' 2>/dev/null || echo "  (query failed)")

# ── Pending approvals ─────────────────────────────────────────────────────────
PENDING=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?or=(status.eq.awaiting_approval,status.eq.auto_pending)&select=id,client,subject,status,created_at&order=created_at.asc&limit=10" \
  -H "apikey: $KEY" \
  -H "Authorization: Bearer $KEY" | \
  python3 -c '
import json, sys
rows = json.loads(sys.stdin.read()) or []
if not rows:
    print("  None")
else:
    for r in rows:
        icon = "⏳" if r["status"]=="awaiting_approval" else "⚡"
        client = r["client"]
        subject = r["subject"][:60]
        status = r["status"]
        print("  "+icon+" ["+client+"] "+subject+" ("+status+")")
' 2>/dev/null || echo "  (query failed)")

# ── OOO status ────────────────────────────────────────────────────────────────
OOO_STATUS="Josh available"
if [[ -f "$WORKSPACE/tmp/sophia-ooo-cache" ]]; then
  OOO_VAL=$(cat "$WORKSPACE/tmp/sophia-ooo-cache" 2>/dev/null || echo "false")
  [[ "$OOO_VAL" != "false" ]] && OOO_STATUS="⚠️ Josh OOO: $OOO_VAL"
fi

# ── Recent activity (last 5 entries) ─────────────────────────────────────────
RECENT_ACTIVITY=""
if [[ -f "$WORKSPACE/memory/activity-log.jsonl" ]]; then
  RECENT_ACTIVITY=$(tail -5 "$WORKSPACE/memory/activity-log.jsonl" | python3 -c '
import json, sys
from datetime import datetime, timezone

for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        r = json.loads(line)
        ts = r.get("ts","")[:16].replace("T"," ")
        repos = r.get("repos",[])
        dirty = [x["name"] for x in repos if x.get("dirty_count",0)>0]
        behind = [x["name"] for x in repos if x.get("behind",0)>0]
        parts = []
        if dirty: parts.append("dirty: "+", ".join(dirty))
        if behind: parts.append("behind: "+", ".join(behind))
        note = " | ".join(parts) if parts else "all clean"
        print("  "+ts+" — "+note)
    except: pass
' 2>/dev/null || echo "  (unavailable)")
fi

# ── Repo summary (latest entry) ───────────────────────────────────────────────
REPO_SUMMARY=$(tail -1 "$WORKSPACE/memory/activity-log.jsonl" 2>/dev/null | python3 -c '
import json, sys
from datetime import datetime, timezone

line = sys.stdin.read().strip()
if not line:
    print("  (unavailable)")
    sys.exit()
r = json.loads(line)
repos = r.get("repos",[])
for repo in repos:
    dirty = repo.get("dirty_count",0)
    ahead = repo.get("ahead",0)
    behind = repo.get("behind",0)
    parts = []
    if dirty: parts.append(str(dirty)+" dirty")
    if ahead: parts.append(str(ahead)+" ahead")
    if behind: parts.append(str(behind)+" behind")
    flag = ", ".join(parts) if parts else "clean"
    print("  "+repo["name"]+": "+flag)
' 2>/dev/null || echo "  (unavailable)")

# ── Active reminders ──────────────────────────────────────────────────────────
REMINDERS=$(curl -s "${SUPABASE_URL}/rest/v1/notifications?type=eq.reminder&status=eq.unread&select=title,metadata&limit=5" \
  -H "apikey: $KEY" \
  -H "Authorization: Bearer $KEY" | \
  python3 -c '
import json, sys
rows = json.loads(sys.stdin.read()) or []
if not rows:
    print("  None")
else:
    for r in rows:
        meta = r.get("metadata") or {}
        due = meta.get("due","?")[:16].replace("T"," ")
        print(f"  ⏰ {r[\"title\"]} — due {due}")
' 2>/dev/null || echo "  (none)")

# ── Today's log file ──────────────────────────────────────────────────────────
TODAY_LOG=""
if [[ -f "$WORKSPACE/memory/${TODAY}.md" ]]; then
  TODAY_LOG=$(cat "$WORKSPACE/memory/${TODAY}.md" | head -40)
else
  TODAY_LOG="  (no log yet today)"
fi

# ── Write the file ────────────────────────────────────────────────────────────
cat > "$OUT_FILE" << EOF
# CURRENT STATE — ${NOW_UTC}
> Auto-generated every night. Read this file for live operational context.

## Agent Health
${AGENT_STATUS}

## Email Queue
${EQ_STATS}

## Pending Approvals / Auto-Sends
${PENDING}

## OOO Status
  ${OOO_STATUS}

## Active Reminders
${REMINDERS}

## Repo Status
${REPO_SUMMARY}

## Recent Activity
${RECENT_ACTIVITY}

## Today's Log
${TODAY_LOG}
EOF

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") CURRENT_STATE.md written to $OUT_FILE"
cp /tmp/current-state-build.txt /dev/null 2>/dev/null || true
