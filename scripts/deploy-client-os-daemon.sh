#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy-client-os-daemon.sh
# Deploys client-os-daemon.sh and its LaunchAgent plist to a client Mac Mini.
# Run from Josh's machine — assumes SSH access via Tailscale.
#
# Usage:
#   ./deploy-client-os-daemon.sh race_technik
#   ./deploy-client-os-daemon.sh vanta_studios
#
# Requirements on client Mac Mini:
#   - .amalfiai/workspace/.env.scheduler must have:
#       AOS_CLIENT_SLUG=<slug>
#       AOS_MASTER_SUPABASE_URL=https://afmpbtynucpbglwtbfuz.supabase.co
#       AOS_MASTER_SERVICE_KEY=<master_service_key>
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

CLIENT_SLUG="${1:-}"
if [[ -z "$CLIENT_SLUG" ]]; then
  echo "Usage: $0 <client_slug>"
  echo "  e.g. $0 race_technik"
  exit 1
fi

WS="$(cd "$(dirname "$0")/.." && pwd)"

# ── SSH target ────────────────────────────────────────────────────────────────
case "$CLIENT_SLUG" in
  race_technik)
    SSH_HOST="rt-macmini"                   # ~/.ssh/config alias
    REMOTE_USER="raceai"
    REMOTE_WS="/Users/raceai/.amalfiai/workspace"
    PLIST_LABEL="com.raceai.client-os-daemon"
    ;;
  vanta_studios)
    SSH_HOST="vanta-macmini"
    REMOTE_USER="${VANTA_USER:-vanta}"
    REMOTE_WS="/Users/${REMOTE_USER}/.amalfiai/workspace"
    PLIST_LABEL="com.amalfiai.client-os-daemon"
    ;;
  *)
    echo "Unknown client slug: $CLIENT_SLUG"
    echo "Add SSH config + case to this script."
    exit 1
    ;;
esac

PLIST_FILE="${PLIST_LABEL}.plist"
LOCAL_PLIST="$WS/launchagents/${PLIST_FILE}"

echo "=== Deploying client-os-daemon to ${CLIENT_SLUG} (${SSH_HOST}) ==="

# 1. Copy daemon script
echo "Copying client-os-daemon.sh..."
ssh "$SSH_HOST" "mkdir -p ${REMOTE_WS}/scripts"
scp "$WS/scripts/client-os-daemon.sh" "${SSH_HOST}:${REMOTE_WS}/scripts/client-os-daemon.sh"
ssh "$SSH_HOST" "chmod +x ${REMOTE_WS}/scripts/client-os-daemon.sh"

# 2. Copy plist
echo "Copying plist..."
if [[ -f "$LOCAL_PLIST" ]]; then
  scp "$LOCAL_PLIST" "${SSH_HOST}:${REMOTE_WS}/launchagents/${PLIST_FILE}"
  ssh "$SSH_HOST" "mkdir -p ~/Library/LaunchAgents && cp ${REMOTE_WS}/launchagents/${PLIST_FILE} ~/Library/LaunchAgents/${PLIST_FILE}"
else
  echo "  WARNING: local plist not found at $LOCAL_PLIST — skipping"
fi

# 3. Load the LaunchAgent
echo "Loading LaunchAgent on ${SSH_HOST}..."
ssh "$SSH_HOST" "launchctl unload ~/Library/LaunchAgents/${PLIST_FILE} 2>/dev/null || true"
ssh "$SSH_HOST" "launchctl load ~/Library/LaunchAgents/${PLIST_FILE}"

# 4. Verify
echo "Verifying..."
ssh "$SSH_HOST" "launchctl list | grep client-os-daemon && echo '  OK' || echo '  NOT running'"

echo ""
echo "=== Done ==="
echo "The daemon will phone home to Amalfi AI's Supabase every 5 min."
echo "Set status via: /os pause|stop|resume ${CLIENT_SLUG}"
echo ""
echo "Ensure these are set in ${REMOTE_WS}/.env.scheduler on ${SSH_HOST}:"
echo "  AOS_CLIENT_SLUG=${CLIENT_SLUG}"
echo "  AOS_MASTER_SUPABASE_URL=https://afmpbtynucpbglwtbfuz.supabase.co"
echo "  AOS_MASTER_SERVICE_KEY=<your_master_service_key>"
