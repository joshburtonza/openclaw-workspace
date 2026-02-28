#!/usr/bin/env bash
# git-backup.sh — auto-commit and push all workspace changes every 6hrs

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
LOG="$WS/out/git-backup.log"
mkdir -p "$WS/out"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

cd "$WS" || exit 1

log "=== Git backup ==="

# Check for anything to commit
git add \
  scripts/ \
  launchagents/ \
  prompts/ \
  data/ \
  supabase/functions/ \
  mission-control-hub/src/ \
  CURRENT_STATE.md \
  *.md \
  *.sh \
  *.json \
  *.ts \
  *.py \
  2>/dev/null || true

# Exclude things we never want committed
git reset HEAD \
  .env.scheduler \
  .env \
  "*.env" \
  "node_modules/" \
  "supabase/.temp/" \
  "tmp/" \
  "out/*.log" \
  2>/dev/null || true

# Only commit if there are staged changes
if git diff --cached --quiet; then
  log "Nothing new to commit"
  exit 0
fi

CHANGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M SAST')

git commit -m "Auto backup: $CHANGED file(s) changed — $TIMESTAMP

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>" 2>&1 | tee -a "$LOG"

git push origin main 2>&1 | tee -a "$LOG"

log "Done — pushed $CHANGED changed file(s)"
