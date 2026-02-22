#!/bin/bash
# setup-launchagents.sh
# Install all Amalfi AI LaunchAgents from launchagents/ directory.
# Run once: bash setup-launchagents.sh
# Run again after editing any plist to reload it.

set -euo pipefail

PLIST_DIR="$(dirname "$0")/launchagents"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_DIR"

echo ""
echo "=== Amalfi AI LaunchAgent Setup ==="
echo ""

# Agents to install
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
  PLIST="$PLIST_DIR/${AGENT}.plist"
  DEST="$LAUNCH_DIR/${AGENT}.plist"

  if [[ ! -f "$PLIST" ]]; then
    echo "  ⚠️  Missing: $PLIST — skipping"
    continue
  fi

  # Unload if already loaded (to apply plist changes)
  launchctl unload "$DEST" 2>/dev/null || true

  # Copy plist to LaunchAgents
  cp "$PLIST" "$DEST"

  # Load agent
  if launchctl load "$DEST" 2>/dev/null; then
    echo "  ✅ Loaded: $AGENT"
  else
    echo "  ❌ Failed: $AGENT"
  fi
done

echo ""
echo "=== All agents installed ==="
echo ""
echo "Check status:   launchctl list | grep amalfiai"
echo "View logs:      ls ~/.openclaw/workspace-anthropic/out/"
echo "Unload all:     bash unload-launchagents.sh"
echo ""
