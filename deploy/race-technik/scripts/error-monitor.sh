#!/usr/bin/env bash
# error-monitor.sh — Race Technik Mac Mini
# Watches *.err.log files and alerts Farhaan via Telegram if errors are found.
# Runs every 10 minutes via LaunchAgent.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
WORKSPACE="${HOME}/.amalfiai/workspace"
ENV_FILE="${WORKSPACE}/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

STATE_FILE="${WORKSPACE}/tmp/error-monitor-last-check"
OUT_DIR="${WORKSPACE}/out"
mkdir -p "${WORKSPACE}/tmp"

if [[ -z "$BOT_TOKEN" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: No TELEGRAM_BOT_TOKEN" >&2
  exit 1
fi

send_telegram() {
  local text="$1"
  export _EM_TEXT="$text"
  python3 - <<'PY'
import os, json, urllib.request
token = os.environ.get('BOT_TOKEN','')
chat  = os.environ.get('CHAT_ID','')
text  = os.environ.get('_EM_TEXT','')
if not (token and chat and text):
    raise SystemExit(0)
data = json.dumps({"chat_id": chat, "text": text}).encode()
req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=data, headers={"Content-Type":"application/json"}, method="POST"
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print(f"send_telegram error: {e}")
PY
}

SINCE=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
NOW=$(date +%s)

ERRORS_FOUND=()

for LOG_FILE in "${OUT_DIR}"/*.err.log; do
  [[ -f "$LOG_FILE" ]] || continue
  AGENT=$(basename "${LOG_FILE%.err.log}")

  # Check modification time
  FILE_MOD=$(python3 -c "import os; print(int(os.path.getmtime('${LOG_FILE}')))" 2>/dev/null || echo "0")
  if [[ "$FILE_MOD" -le "$SINCE" ]]; then
    continue
  fi

  # Check for new error lines since last check
  NEW_ERRORS=$(python3 - <<PY
import os, time

log_file = '${LOG_FILE}'
since = ${SINCE}

try:
    with open(log_file) as f:
        lines = f.readlines()
    recent = []
    for line in lines[-30:]:
        line = line.strip()
        if line and any(kw in line.upper() for kw in ['ERROR','FATAL','EXCEPTION','TRACEBACK','FAIL']):
            recent.append(line[:200])
    print('\n'.join(recent[-5:]))
except Exception:
    pass
PY
  2>/dev/null || true)

  if [[ -n "$NEW_ERRORS" ]]; then
    ERRORS_FOUND+=("${AGENT}:\n${NEW_ERRORS}")
  fi
done

echo "$NOW" > "$STATE_FILE"

if [[ ${#ERRORS_FOUND[@]} -gt 0 ]]; then
  MSG="Race Technik Mac Mini — errors detected:\n\n"
  for ERR in "${ERRORS_FOUND[@]}"; do
    MSG+="${ERR}\n\n"
  done
  send_telegram "$(echo -e "$MSG")"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Sent error alert for ${#ERRORS_FOUND[@]} agent(s)"
else
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") No new errors found"
fi
