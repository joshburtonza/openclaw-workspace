#!/usr/bin/env bash
# nightly-github-sync.sh — commits + pushes workspace and mission-control-hub
# Runs at 23:00 SAST (21:00 UTC) daily via LaunchAgent
set -uo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/Users/henryburton"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
PUSHED=()
FAILED=()

tg_alert() {
  local msg="$1"
  local token="${TELEGRAM_BOT_TOKEN:-}"
  local chat_id="1140320036"
  [[ -z "$token" ]] && return
  curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${chat_id}\",\"text\":\"${msg}\"}" \
    > /dev/null 2>&1 || true
}

sync_repo() {
  local REPO_PATH="$1"
  local REPO_NAME="$2"

  if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "  Skipping $REPO_NAME — not a git repo"
    return
  fi

  echo "  Syncing $REPO_NAME..."
  git -C "$REPO_PATH" add -A

  if git -C "$REPO_PATH" diff --staged --quiet; then
    echo "  $REPO_NAME — nothing to commit"
    return
  fi

  if ! git -C "$REPO_PATH" commit -m "Auto-sync: $TIMESTAMP SAST" --no-verify 2>&1; then
    echo "  $REPO_NAME — commit failed"
    FAILED+=("$REPO_NAME (commit failed)")
    return
  fi

  local push_out
  push_out=$(git -C "$REPO_PATH" push origin HEAD 2>&1)
  local push_rc=$?
  echo "$push_out"

  if [[ $push_rc -ne 0 ]]; then
    echo "  $REPO_NAME — push FAILED (exit $push_rc)"
    local short_err
    short_err=$(echo "$push_out" | tail -3 | tr '\n' ' ')
    FAILED+=("$REPO_NAME: $short_err")
    tg_alert "⚠️ Nightly sync push FAILED for \`$REPO_NAME\`%0A$short_err"
    return
  fi

  echo "  $REPO_NAME — pushed ✓"
  PUSHED+=("$REPO_NAME")
}

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Nightly GitHub sync starting"

sync_repo "$WORKSPACE" "workspace"
sync_repo "$WORKSPACE/mission-control-hub" "mission-control-hub"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  BODY="⚠️ Push failed for: $(IFS=", "; echo "${FAILED[*]}")"
  [[ ${#PUSHED[@]} -gt 0 ]] && BODY="$BODY | Pushed: $(IFS=", "; echo "${PUSHED[*]}")"
elif [[ ${#PUSHED[@]} -eq 0 ]]; then
  BODY="No changes to push tonight."
else
  BODY="Pushed: $(IFS=", "; echo "${PUSHED[*]}")"
fi

bash "$WORKSPACE/notifications-bridge.sh" \
  "system" \
  "Nightly GitHub sync complete" \
  "$BODY" \
  "Alex Claww" \
  "low"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Nightly GitHub sync complete — $BODY"
