#!/usr/bin/env bash
# daily-repo-sync.sh — Race Technik Mac Mini
# Pulls chrome-auto-care, scans recent commits, sends summary to Farhaan.
# Runs at 09:00 SAST daily via LaunchAgent.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
WORKSPACE="${HOME}/.amalfiai/workspace"
ENV_FILE="${WORKSPACE}/.env.scheduler"
source "$ENV_FILE"
unset CLAUDECODE

BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
CHAT_ID="${TELEGRAM_CHAT_ID}"
CLIENTS="${WORKSPACE}/clients"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Daily repo sync starting"

send_telegram() {
  local text="$1"
  export _DS_TEXT="$text"
  python3 - <<'PY'
import os, json, urllib.request
token = os.environ.get('BOT_TOKEN','')
chat  = os.environ.get('CHAT_ID','')
text  = os.environ.get('_DS_TEXT','')
if not (token and chat and text):
    raise SystemExit(0)
data = json.dumps({"chat_id": chat, "text": text}).encode()
req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=data, headers={"Content-Type":"application/json"}, method="POST"
)
try:
    urllib.request.urlopen(req, timeout=15)
except Exception as e:
    print(f"send error: {e}")
PY
}

REPO_DIR="${CLIENTS}/chrome-auto-care"
REPO_NAME="chrome-auto-care (Race Technik)"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") chrome-auto-care not cloned yet — skipping"
  send_telegram "Daily sync: chrome-auto-care repo not found at ${REPO_DIR}. Please clone it first."
  exit 0
fi

# Pull latest
echo "  Pulling ${REPO_NAME}..."
git -C "$REPO_DIR" pull --ff-only 2>&1 | tail -3 || true

# Get commits from last 24h
COMMITS=$(git -C "$REPO_DIR" log --since="24 hours ago" --oneline --no-merges 2>/dev/null | head -15 || echo "")

if [[ -z "$COMMITS" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") No commits in last 24h"
  exit 0
fi

# Summarise via Claude
PROMPT_TMP=$(mktemp /tmp/rt-sync-XXXXXX)
cat > "$PROMPT_TMP" << PROMPT
Summarise these recent commits to the Race Technik booking platform (chrome-auto-care) in 3 to 5 bullet points. Be concise and explain what changed in plain English for Farhaan (non-technical). No hyphens, use em dashes instead.

Commits:
${COMMITS}
PROMPT

SUMMARY=$(claude --print --dangerously-skip-permissions --model claude-sonnet-4-6 < "$PROMPT_TMP" 2>/dev/null || echo "$COMMITS")
rm -f "$PROMPT_TMP"

TODAY=$(date '+%A, %d %B %Y')
send_telegram "Race Technik — Daily Repo Update (${TODAY})

${SUMMARY}"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Daily sync complete"
