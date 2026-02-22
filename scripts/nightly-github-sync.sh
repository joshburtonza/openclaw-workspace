#!/usr/bin/env bash
# nightly-github-sync.sh — commits + pushes workspace and mission-control-hub
# Runs at 23:00 SAST (21:00 UTC) daily via LaunchAgent
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/Users/henryburton"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
PUSHED=()

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

  git -C "$REPO_PATH" commit -m "Auto-sync: $TIMESTAMP SAST" --no-verify 2>&1
  git -C "$REPO_PATH" push origin HEAD 2>&1
  echo "  $REPO_NAME — pushed ✓"
  PUSHED+=("$REPO_NAME")
}

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Nightly GitHub sync starting"

sync_repo "$WORKSPACE" "workspace"
sync_repo "$WORKSPACE/mission-control-hub" "mission-control-hub"

if [[ ${#PUSHED[@]} -eq 0 ]]; then
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
