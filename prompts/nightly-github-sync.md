NIGHTLY GITHUB SYNC

1. Commit and push all workspace changes:
   cd /Users/henryburton/.openclaw/workspace-anthropic
   git add -A
   git diff --staged --quiet || git commit -m "Auto-sync: $(date '+%Y-%m-%d %H:%M') SAST"
   git push origin main

2. Also push mission-control-hub if any changes:
   cd /Users/henryburton/.openclaw/workspace-anthropic/mission-control-hub
   git add -A
   git diff --staged --quiet || git commit -m "Auto-sync: $(date '+%Y-%m-%d %H:%M') SAST"
   git push origin main

3. Log: /Users/henryburton/.openclaw/workspace-anthropic/notifications-bridge.sh "system" "Nightly GitHub sync complete" "Workspace committed and pushed to GitHub" "Alex Claww" "low"

This runs every night at 11pm SAST. All memory files, scripts, and config are backed up to GitHub.