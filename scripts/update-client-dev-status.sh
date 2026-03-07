#!/bin/bash
# update-client-dev-status.sh
# Generates DEV_STATUS.md for each client from recent git commits.
# Run nightly. Loaded by the WhatsApp gateway for on-demand group awareness.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
TODAY=$(date '+%A %d %B %Y %H:%M SAST')

update_client() {
  local SLUG="$1"
  local REPO="$2"
  local NAME="$3"
  local REPO_PATH="$WS/clients/$REPO"
  local OUT_FILE="$REPO_PATH/DEV_STATUS.md"

  if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "[update-dev-status] Skipping $SLUG — repo not found at $REPO_PATH" >&2
    return 0
  fi

  echo "[update-dev-status] Updating $SLUG..."

  {
    echo "# Dev Status — $NAME"
    echo "Last updated: $TODAY"
    echo ""
    echo "## What was shipped (last 14 days)"
    echo ""

    COMMITS=$(git -C "$REPO_PATH" log \
      --since="14 days ago" \
      --pretty=format:"[%as] %s" \
      --no-merges \
      2>/dev/null | head -25 || echo "")

    if [[ -z "$COMMITS" ]]; then
      echo "No commits in the last 14 days."
    else
      # Strip conventional commit prefixes (feat:, fix:, chore: etc) for readability
      echo "$COMMITS" | sed -E \
        's/\[([0-9-]+)\] (feat|fix|chore|refactor|docs|style|test|perf|build|wip)(\([^)]+\))?:\s*/[\1] /I' | \
        sed 's/^/- /'
    fi

    echo ""
    echo "## Older history (last 30 days)"
    echo ""

    OLDER=$(git -C "$REPO_PATH" log \
      --since="30 days ago" \
      --until="14 days ago" \
      --pretty=format:"[%as] %s" \
      --no-merges \
      2>/dev/null | head -15 || echo "")

    if [[ -z "$OLDER" ]]; then
      echo "Nothing beyond the 14-day window."
    else
      echo "$OLDER" | sed -E \
        's/\[([0-9-]+)\] (feat|fix|chore|refactor|docs|style|test|perf|build|wip)(\([^)]+\))?:\s*/[\1] /I' | \
        sed 's/^/- /'
    fi

  } > "$OUT_FILE"

  echo "[update-dev-status] $SLUG → $OUT_FILE"
}

update_client "race_technik"       "chrome-auto-care"          "Race Technik (Chrome Auto Care)"
update_client "ascend_lc"          "qms-guard"                 "Ascend LC (QMS Guard)"
update_client "favorite_logistics" "favorite-flow-9637aff2"    "Favlog (FLAIR ERP)"

echo "[update-dev-status] Done"
