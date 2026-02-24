#!/usr/bin/env bash
# nightly-github-sync.sh — Race Technik Mac Mini
# Commits and pushes any uncommitted changes in chrome-auto-care.
# Runs at 23:00 SAST daily via LaunchAgent.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
WORKSPACE="${HOME}/.amalfiai/workspace"
ENV_FILE="${WORKSPACE}/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

CLIENTS="${WORKSPACE}/clients"
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
    echo "  $REPO_NAME: nothing to commit"
    return
  fi

  git -C "$REPO_PATH" commit -m "chore: nightly sync ${TIMESTAMP} [Race Technik Mac Mini]" 2>&1 || true
  git -C "$REPO_PATH" push 2>&1 && PUSHED+=("$REPO_NAME") || echo "  $REPO_NAME: push failed (check git auth)"
}

sync_repo "${CLIENTS}/chrome-auto-care" "chrome-auto-care"

if [[ ${#PUSHED[@]} -gt 0 ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Pushed: ${PUSHED[*]}"
else
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Nothing to push"
fi
