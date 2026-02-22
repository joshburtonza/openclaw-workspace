#!/bin/bash
# unload-launchagents.sh — unload all Amalfi AI LaunchAgents (safe, non-destructive)

AGENTS=(
  com.amalfiai.sophia-cron
  com.amalfiai.telegram-poller
  com.amalfiai.morning-brief
  com.amalfiai.heartbeat
  com.amalfiai.silence-detection
  com.amalfiai.alex-outreach
  com.amalfiai.alex-reply-detection
  com.amalfiai.activity-tracker
  com.amalfiai.nightly-flush
  com.amalfiai.weekly-memory
  com.amalfiai.sophia-followup
)

for AGENT in "${AGENTS[@]}"; do
  launchctl unload "$HOME/Library/LaunchAgents/${AGENT}.plist" 2>/dev/null && echo "Unloaded: $AGENT" || true
done
echo "Done."
