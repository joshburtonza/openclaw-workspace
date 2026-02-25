#!/usr/bin/env bash
# daily-repo-sync.sh — pulls client repos, scans 24h commits, summaries via Claude
# Runs at 09:00 SAST daily via LaunchAgent
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
unset CLAUDECODE

REPOS=(
  "qms-guard:Ascend LC (QMS Guard)"
  "favorite-flow-9637aff2:Favorite Logistics (FLAIR)"
)

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Daily repo sync starting"

SUMMARIES=()
ANY_CHANGES=false

for ENTRY in "${REPOS[@]}"; do
  REPO_DIR="${ENTRY%%:*}"
  REPO_NAME="${ENTRY#*:}"
  REPO_PATH="$WORKSPACE/$REPO_DIR"

  if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "  Skipping $REPO_DIR — not a git repo"
    continue
  fi

  # Pull latest
  echo "  Pulling $REPO_DIR..."
  git -C "$REPO_PATH" pull --quiet --rebase 2>&1 || echo "  Warning: pull failed for $REPO_DIR"

  # Get commits from last 24 hours
  COMMITS=$(git -C "$REPO_PATH" log --oneline --since="24 hours ago" 2>/dev/null || echo "")

  if [[ -z "$COMMITS" ]]; then
    echo "  $REPO_DIR — no commits in last 24h"
    continue
  fi

  ANY_CHANGES=true
  echo "  $REPO_DIR — $(echo "$COMMITS" | wc -l | tr -d ' ') commits"

  # Summarise with Claude
  PROMPT_TMP=$(mktemp /tmp/repo-sync-XXXXXX)
  cat > "$PROMPT_TMP" << PROMPT
Summarise these git commits in 1-2 plain English sentences. Be specific. Do not use technical jargon — write as if telling a non-technical founder what the developers worked on.

Repo: ${REPO_NAME}

Commits:
${COMMITS}

Reply with just the summary sentence(s), nothing else.
PROMPT

  SUMMARY=$(claude --print --model claude-haiku-4-5-20251001 < "$PROMPT_TMP" 2>/dev/null || echo "$REPO_NAME: development work committed")
  rm -f "$PROMPT_TMP"

  SUMMARIES+=("${REPO_NAME}: ${SUMMARY}")
done

if [[ "$ANY_CHANGES" == "false" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") No changes in any repo today"
  bash "$WORKSPACE/notifications-bridge.sh" \
    "repo" \
    "Repo Sync: No changes in 24h" \
    "All 3 client repos quiet today." \
    "Repo Watcher" \
    "low"
  exit 0
fi

# Build full summary
FULL_SUMMARY=$(printf '%s\n' "${SUMMARIES[@]}")

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Changes found, posting summary"
echo "$FULL_SUMMARY"

# Post to Mission Control notifications
bash "$WORKSPACE/notifications-bridge.sh" \
  "repo" \
  "Repo Sync: Changes detected" \
  "$FULL_SUMMARY" \
  "Repo Watcher" \
  "normal"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Daily repo sync complete"
