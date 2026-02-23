#!/bin/bash
# One-shot: merges pre-f2f-fixes into main at 1am, then self-destructs
REPO="/Users/henryburton/.openclaw/workspace-anthropic/clients/qms-guard"
PLIST="$HOME/Library/LaunchAgents/com.amalfiai.qms-merge-1am.plist"
LOG="/Users/henryburton/.openclaw/workspace-anthropic/out/qms-merge-1am.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
log "=== QMS pre-f2f merge ==="

cd "$REPO" || { log "ERROR: repo not found"; exit 1; }

# Safety check — only merge if pre-f2f-fixes branch exists and hasn't already been merged
if ! git branch -r | grep -q 'origin/pre-f2f-fixes'; then
  log "Branch origin/pre-f2f-fixes not found — skipping"
else
  git fetch origin 2>>"$LOG"
  git checkout main 2>>"$LOG" && git pull origin main 2>>"$LOG"

  if git branch --merged main | grep -q 'pre-f2f-fixes'; then
    log "pre-f2f-fixes already merged into main — nothing to do"
  else
    git merge origin/pre-f2f-fixes --no-edit 2>>"$LOG"
    git push origin main 2>>"$LOG"
    log "Merged and pushed. Lovable will deploy automatically."
  fi
fi

# Self-destruct
launchctl unload "$PLIST" 2>/dev/null
rm -f "$PLIST"
log "Plist removed. Job done."
