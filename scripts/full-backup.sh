#!/usr/bin/env bash
# full-backup.sh
# Daily backup of everything not in git: secrets, auth tokens, LaunchAgents, Claude settings.
# Keeps last 7 archives. Git workspace pushed to GitHub separately by nightly-github-sync.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

BACKUP_DIR="/Users/henryburton/.openclaw/backups"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M')
ARCHIVE="$BACKUP_DIR/amalfi-full-backup-$TIMESTAMP"
LOG="/Users/henryburton/.openclaw/workspace-anthropic/out/full-backup.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

mkdir -p "$BACKUP_DIR" "$ARCHIVE"
log "Full backup starting — $TIMESTAMP"

# Secrets
cp /Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler "$ARCHIVE/.env.scheduler" && log ".env.scheduler done"

# LaunchAgents
cp -r ~/Library/LaunchAgents/ "$ARCHIVE/LaunchAgents/" && log "LaunchAgents done"

# Claude settings + plugins (skip cache, conversations, history)
rsync -a --quiet \
  --exclude='cache/' \
  --exclude='debug/' \
  --exclude='history.jsonl' \
  --exclude='conversations-md/' \
  --exclude='projects/' \
  --exclude='shell-snapshots/' \
  ~/.claude/ "$ARCHIVE/claude/" && log "Claude settings done"

# gog OAuth + config
rsync -a --quiet ~/.config/ "$ARCHIVE/config/" && log "Config done"

# openclaw bin + config
cp -r ~/.openclaw/bin "$ARCHIVE/openclaw-bin" 2>/dev/null && log "openclaw bin done"
[[ -d ~/.openclaw/config ]] && cp -r ~/.openclaw/config "$ARCHIVE/openclaw-config" 2>/dev/null || true

# Shell config
cp ~/.zshrc "$ARCHIVE/.zshrc" 2>/dev/null || true
cp ~/.zprofile "$ARCHIVE/.zprofile" 2>/dev/null || true
log "Shell config done"

# Archive and clean up staging dir
cd "$BACKUP_DIR"
tar -czf "amalfi-full-backup-$TIMESTAMP.tar.gz" "amalfi-full-backup-$TIMESTAMP/"
rm -rf "$ARCHIVE"

ARCHIVE_FILE="$BACKUP_DIR/amalfi-full-backup-$TIMESTAMP.tar.gz"
SIZE=$(du -sh "$ARCHIVE_FILE" 2>/dev/null | cut -f1)
log "Archive created: $ARCHIVE_FILE ($SIZE)"

# Also push workspace to GitHub
cd /Users/henryburton/.openclaw/workspace-anthropic
CHANGED=$(git status --short 2>/dev/null | grep -v "^?" | wc -l | tr -d ' ')
if [[ "$CHANGED" -gt 0 ]]; then
  git add -A 2>/dev/null
  git commit -m "Auto backup: ${CHANGED} file(s) changed — $(date '+%Y-%m-%d %H:%M SAST')" 2>/dev/null || true
  git push origin main 2>/dev/null && log "GitHub push done" || log "GitHub push failed (will retry nightly)"
else
  log "No workspace changes to push"
fi

# Keep only last 7 backups
cd "$BACKUP_DIR"
ls -t amalfi-full-backup-*.tar.gz 2>/dev/null | tail -n +8 | while read -r old; do
  rm -f "$old"
  log "Removed old backup: $old"
done

log "Backup complete"
