#!/usr/bin/env bash
# nightly-ops.sh — Merged: nightly session flush + write current state
# Runs twice daily via LaunchAgent:
#   23:50 SAST — flush daily ops log to memory/YYYY-MM-DD.md
#   03:00 SAST — write CURRENT_STATE.md system snapshot
# Neither phase uses Claude API.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY}"
HOUR=$(TZ=Africa/Johannesburg date '+%-H')

# Decide which phase to run based on current hour
if [ "$HOUR" -ge 20 ] || [ "$HOUR" -le 6 ] && [ "$HOUR" -ge 1 ]; then
  # Between 01:00-06:00 → state snapshot phase
  # Between 20:00-23:59 → flush phase
  if [ "$HOUR" -ge 1 ] && [ "$HOUR" -le 6 ]; then
    PHASE="state"
  else
    PHASE="flush"
  fi
else
  # Fallback: if manually run during the day, do both
  PHASE="both"
fi

# Allow override via argument
[[ "${1:-}" == "flush" ]] && PHASE="flush"
[[ "${1:-}" == "state" ]] && PHASE="state"
[[ "${1:-}" == "both" ]] && PHASE="both"

# ============================================================================
# PHASE: FLUSH — Write daily ops log to memory/YYYY-MM-DD.md
# ============================================================================
do_flush() {
  DATE=$(TZ=Africa/Johannesburg date '+%Y-%m-%d')
  DOW=$(TZ=Africa/Johannesburg date '+%A, %B %-d, %Y')
  OUT_FILE="$WORKSPACE/memory/${DATE}.md"

  echo "[nightly-ops] Flush phase starting for $DATE"

  # ── Email activity today ──────────────────────────────────────────────────
  EMAIL_STATS=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?select=status,created_at&order=created_at.desc&limit=100" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | python3 -c "
import json, sys
from datetime import datetime
rows = json.loads(sys.stdin.read()) or []
today = datetime.now().strftime('%Y-%m-%d')
counts = {}
for r in rows:
    if r.get('created_at','')[:10] == today:
        s = r.get('status','?')
        counts[s] = counts.get(s,0) + 1
if not counts:
    print('No email activity today.')
else:
    print(', '.join(str(v)+' '+k for k,v in sorted(counts.items())))
" 2>/dev/null || echo "unavailable")

  # ── Agents status ─────────────────────────────────────────────────────────
  AGENT_STATUS=$(launchctl list | grep com.amalfiai | while IFS=$'\t' read -r pid code label; do
    name="${label#com.amalfiai.}"
    icon="✅"
    [[ "$code" != "0" && "$code" != "-" ]] && icon="⚠️ (exit $code)"
    echo "- $icon $name"
  done | sort)

  # ── Repo changes today ────────────────────────────────────────────────────
  REPO_LOG=""
  for ENTRY in "qms-guard:Ascend LC" "favorite-flow-9637aff2:Favorite Logistics" "chrome-auto-care:Race Technik"; do
    DIR="${ENTRY%%:*}"
    NAME="${ENTRY#*:}"
    COMMITS=$(git -C "$WORKSPACE/clients/$DIR" log --oneline --max-count=5 --since="24 hours ago" 2>/dev/null || true)
    if [[ -n "$COMMITS" ]]; then
      REPO_LOG="${REPO_LOG}**${NAME}:**
$COMMITS

"
    fi
  done
  [[ -z "$REPO_LOG" ]] && REPO_LOG="No commits in any client repo today."

  # ── Write daily log ─────────────────────────────────────────────────────────
  if [[ -f "$OUT_FILE" ]]; then
    echo "[nightly-ops] Log already exists for $DATE — appending system summary"
    cat >> "$OUT_FILE" << SECTION

## Nightly System Summary
- Email activity: ${EMAIL_STATS}
- All agents: $(launchctl list | grep -c com.amalfiai) running

### Repo activity
${REPO_LOG}
SECTION
  else
    cat > "$OUT_FILE" << LOG
# Daily Log — ${DOW}

## Email Activity
${EMAIL_STATS}

## Agent Health
${AGENT_STATUS}

## Repo Activity
${REPO_LOG}
LOG
  fi

  echo "[nightly-ops] Flush written: $OUT_FILE"
}

# ============================================================================
# PHASE: STATE — Write CURRENT_STATE.md system snapshot
# ============================================================================
do_state() {
  OUT_FILE="$WORKSPACE/CURRENT_STATE.md"
  NOW_UTC=$(date -u +"%Y-%m-%d %H:%M UTC")
  TODAY=$(date -u +"%Y-%m-%d")

  echo "[nightly-ops] State snapshot starting at $NOW_UTC"

  # ── Agent health ──────────────────────────────────────────────────────────
  AGENT_STATUS=$(launchctl list 2>/dev/null | grep "com.amalfiai" | while read pid status label; do
    icon="✅"
    [[ "$status" != "0" && "$status" != "-" ]] && icon="⚠️"
    printf "  %s %s (exit %s)\n" "$icon" "${label#com.amalfiai.}" "$status"
  done)

  # ── Email queue stats ─────────────────────────────────────────────────────
  EQ_STATS=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?select=status,created_at&order=created_at.desc&limit=50" \
    -H "apikey: $KEY" \
    -H "Authorization: Bearer $KEY" | \
    python3 -c '
import json, sys
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

  # ── Pending approvals ─────────────────────────────────────────────────────
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

  # ── OOO status ────────────────────────────────────────────────────────────
  OOO_STATUS="Josh available"
  if [[ -f "$WORKSPACE/tmp/sophia-ooo-cache" ]]; then
    OOO_VAL=$(cat "$WORKSPACE/tmp/sophia-ooo-cache" 2>/dev/null || echo "false")
    [[ "$OOO_VAL" != "false" ]] && OOO_STATUS="⚠️ Josh OOO: $OOO_VAL"
  fi

  # ── Recent activity (last 5 entries) ──────────────────────────────────────
  RECENT_ACTIVITY=""
  if [[ -f "$WORKSPACE/memory/activity-log.jsonl" ]]; then
    RECENT_ACTIVITY=$(tail -5 "$WORKSPACE/memory/activity-log.jsonl" | python3 -c '
import json, sys
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

  # ── Repo summary (latest entry) ───────────────────────────────────────────
  REPO_SUMMARY=$(tail -1 "$WORKSPACE/memory/activity-log.jsonl" 2>/dev/null | python3 -c '
import json, sys
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

  # ── Active reminders ──────────────────────────────────────────────────────
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

  # ── Scope creep alerts ────────────────────────────────────────────────────
  SCOPE_FLAGS=""
  if [[ -f "$WORKSPACE/tmp/scope-creep-flags.txt" ]] && [[ -s "$WORKSPACE/tmp/scope-creep-flags.txt" ]]; then
    SCOPE_FLAGS=$(sed 's/^/  ⚠️ /' "$WORKSPACE/tmp/scope-creep-flags.txt")
  else
    SCOPE_FLAGS="  (none)"
  fi

  # ── Today's log file ──────────────────────────────────────────────────────
  TODAY_LOG=""
  if [[ -f "$WORKSPACE/memory/${TODAY}.md" ]]; then
    TODAY_LOG=$(head -40 "$WORKSPACE/memory/${TODAY}.md")
  else
    TODAY_LOG="  (no log yet today)"
  fi

  # ── Write the file ────────────────────────────────────────────────────────
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

## Scope Creep Alerts
${SCOPE_FLAGS}

## Today's Log
${TODAY_LOG}
EOF

  echo "[nightly-ops] CURRENT_STATE.md written"
}

# ============================================================================
# RUN
# ============================================================================
case "$PHASE" in
  flush)  do_flush ;;
  state)  do_state ;;
  both)   do_flush; do_state ;;
esac

echo "[nightly-ops] Done (phase=$PHASE)"
