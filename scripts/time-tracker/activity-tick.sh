#!/usr/bin/env bash
set -euo pipefail

# Activity tick: logs macOS user activity + repo movement
# Output: appends JSON line to workspace log file

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
LOG_FILE="$ROOT/memory/activity-log.jsonl"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

mkdir -p "$(dirname "$LOG_FILE")"

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

get_idle_seconds() {
  # HIDIdleTime is in nanoseconds
  local ns
  ns=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print $NF; exit}' || true)
  if [[ -z "${ns:-}" ]]; then
    echo "null"; return
  fi
  python3 - <<PY
ns=int($ns)
print(round(ns/1e9,3))
PY
}

get_loadavg() {
  sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1","$2","$3}' || echo ""
}

repo_tick() {
  local name="$1"; local dir="$2"
  if [[ ! -d "$dir/.git" ]]; then
    echo "{\"name\":\"$name\",\"missing\":true}"
    return
  fi

  local dirty_count last_commit_epoch ahead behind
  dirty_count=$(cd "$dir" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  last_commit_epoch=$(cd "$dir" && git log -1 --pretty=%ct 2>/dev/null || echo "")

  # ahead/behind (best-effort) — keep it fast; don't hang on network/credentials
  (cd "$dir" && GIT_TERMINAL_PROMPT=0 python3 - <<'PY'
import subprocess
try:
  subprocess.run([
    'git','fetch','--all','--prune'
  ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
except Exception:
  pass
PY
  ) || true
  local sb
  sb=$(cd "$dir" && git status -sb 2>/dev/null | head -n1 || true)
  ahead=$(echo "$sb" | sed -n 's/.*\[ahead \([0-9]*\).*/\1/p')
  behind=$(echo "$sb" | sed -n 's/.*\[behind \([0-9]*\).*/\1/p')
  [[ -z "${ahead:-}" ]] && ahead=0
  [[ -z "${behind:-}" ]] && behind=0

  echo "{\"name\":\"$name\",\"dirty_count\":$dirty_count,\"ahead\":$ahead,\"behind\":$behind,\"last_commit_epoch\":${last_commit_epoch:-null}}"
}

TS="$(now_iso)"
IDLE="$(get_idle_seconds)"
LOAD="$(get_loadavg)"

# Repos to watch
REPOS_JSON=$(cat <<EOF
[
  $(repo_tick "workspace" "$ROOT"),
  $(repo_tick "mission-control-hub" "$ROOT/mission-control-hub"),
  $(repo_tick "qms-guard" "$ROOT/qms-guard"),
  $(repo_tick "favorite-flow" "$ROOT/favorite-flow-9637aff2")
]
EOF
)

JSON=$(python3 - <<PY
import json
idle_raw = "$IDLE"
idle_val = None if idle_raw in ("", "null") else float(idle_raw)
obj={
  "ts":"$TS",
  "idle_seconds": idle_val,
  "loadavg":"$LOAD",
  "repos": json.loads('''$REPOS_JSON''')
}
print(json.dumps(obj, ensure_ascii=False))
PY
)

echo "$JSON" >> "$LOG_FILE"

# Also write to Supabase audit_log (best-effort)
# NOTE: uses anon key; RLS must allow insert. If blocked, we just continue.
curl -s --max-time 10 -X POST "$SUPABASE_URL/rest/v1/audit_log" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=minimal' \
  -d "{\"agent\":\"Time Tracker\",\"action\":\"activity_tick\",\"status\":\"success\",\"details\":$JSON}" \
  >/dev/null 2>&1 || true
