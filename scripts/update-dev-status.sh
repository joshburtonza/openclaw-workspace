#!/bin/bash
# update-dev-status.sh
# Generates DEV_STATUS.md for each active client repo by summarising recent git commits.
# Run nightly — keeps the weekly brief and ad-hoc Sophia queries accurate.
#
# Schedule: Nightly at 23:30 SAST (handled by LaunchAgent)

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
LOG="$WS/out/update-dev-status.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Kill switch
if [[ -f "${HOME}/.openclaw/KILL_SWITCH" ]]; then
  log "KILL SWITCH active — update-dev-status suppressed"
  exit 0
fi

unset CLAUDECODE

# Write DEV_STATUS.md for a client repo
write_status() {
  local SLUG="$1"      # e.g. chrome-auto-care
  local REPO="$2"      # path under workspace/clients/

  local REPO_DIR="$WS/clients/$REPO"
  local OUT="$REPO_DIR/DEV_STATUS.md"

  if [[ ! -d "$REPO_DIR/.git" ]]; then
    log "  $SLUG: no git repo at $REPO_DIR — skipping"
    return 0
  fi

  log "  $SLUG: generating..."

  # Pull latest
  git -C "$REPO_DIR" pull --quiet --ff-only 2>/dev/null || true

  # Last 30 commits (past 2 weeks) with date, author, message
  local COMMITS
  COMMITS=$(git -C "$REPO_DIR" log \
    --since="14 days ago" \
    --pretty=format:"%ad  %s" \
    --date=format:"%d %b %Y" \
    --no-merges \
    2>/dev/null | head -40 || echo "(no recent commits)")

  # Changed files summary (last 7 days)
  local CHANGED_FILES
  CHANGED_FILES=$(git -C "$REPO_DIR" log \
    --since="7 days ago" \
    --name-only \
    --pretty=format: \
    --no-merges \
    2>/dev/null | grep -v '^$' | sort | uniq -c | sort -rn | head -15 | awk '{print $2, "("$1" changes)"}' || echo "")

  # Last commit date
  local LAST_COMMIT
  LAST_COMMIT=$(git -C "$REPO_DIR" log -1 --format="%ad" --date=format:"%d %b %Y" 2>/dev/null || echo "unknown")

  # Ask Claude to summarise for Sophia
  local TMPFILE
  TMPFILE=$(mktemp /tmp/dev-status-XXXXXX)

  cat > "$TMPFILE" <<PROMPT
You are summarising recent development activity for Sophia, Amalfi AI's Client Success Manager.

Client: $SLUG
Last commit: $LAST_COMMIT

Recent commits (past 14 days):
$COMMITS

Most-changed files (past 7 days):
$CHANGED_FILES

Write a DEV_STATUS.md with:
1. A "## What shipped this week" section — specific features/fixes, plain English, no jargon
2. A "## In progress / coming next" section — infer from commit patterns what is being worked on
3. A "## Notable" section only if there is something worth flagging (breaking changes, blocked work, etc.) — omit if nothing notable

Rules:
- Plain English, no bullet-pointed walls of text, no hyphens or dashes anywhere
- 3 to 8 bullet points max per section, short and specific
- If the commit history shows no activity, say so clearly
- Output only the markdown content, no preamble
PROMPT

  local STATUS
  STATUS=$(/Users/henryburton/.openclaw/bin/claude-gated --print --model claude-haiku-4-5-20251001 --dangerously-skip-permissions < "$TMPFILE" 2>/dev/null || echo "")
  rm -f "$TMPFILE"

  if [[ -z "$STATUS" ]]; then
    log "  $SLUG: no response from Claude — skipping"
    return 0
  fi

  {
    echo "# Dev Status — $SLUG"
    echo "_Last updated: $(date '+%d %b %Y %H:%M SAST')_"
    echo ""
    echo "$STATUS"
  } > "$OUT"

  log "  $SLUG: written to $OUT"
}

log "update-dev-status starting"

write_status "chrome-auto-care"          "chrome-auto-care"
write_status "qms-guard"                 "qms-guard"
write_status "favorite-flow"             "favorite-flow-9637aff2"
write_status "vanta-studios"             "vanta-studios"
write_status "ambassadex"                "ambassadex"

log "update-dev-status complete"
