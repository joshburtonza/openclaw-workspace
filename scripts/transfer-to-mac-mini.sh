#!/usr/bin/env bash
# transfer-to-mac-mini.sh
# Run this on the MacBook to push everything to the new Amalfi Mac Mini.
# Mac Mini must be on Tailscale and have SSH/Remote Login enabled first.
#
# Usage: bash scripts/transfer-to-mac-mini.sh

set -euo pipefail

MAC_MINI_IP="${1:-}"   # pass Tailscale IP as arg, or set below
MAC_MINI_USER="henryburton"

# Auto-detect from tailscale if not passed
if [[ -z "$MAC_MINI_IP" ]]; then
  MAC_MINI_IP=$(tailscale status 2>/dev/null | grep "amalfi-mac-mini" | awk '{print $1}' | head -1)
fi

if [[ -z "$MAC_MINI_IP" ]]; then
  echo "ERROR: Could not find amalfi-mac-mini on Tailscale."
  echo "Usage: bash transfer-to-mac-mini.sh <tailscale-ip>"
  echo "Or ensure Mac Mini is named 'amalfi-mac-mini' in System Settings > Sharing"
  exit 1
fi

REMOTE="${MAC_MINI_USER}@${MAC_MINI_IP}"
echo "Transferring to: $REMOTE"
echo ""

rsync_to() {
  local src="$1"
  local dst="$2"
  echo "  rsync: $src → $dst"
  rsync -avz --progress --exclude='node_modules' --exclude='.git' --exclude='*.log' \
    -e ssh "$src" "${REMOTE}:${dst}"
}

# ── 1. OpenClaw workspace (excluding node_modules and logs) ───────────────────
echo "▶ Transferring workspace..."
ssh "$REMOTE" "mkdir -p ~/.openclaw"
rsync -avz --progress \
  --exclude='node_modules' \
  --exclude='.git' \
  --exclude='out/*.log' \
  --exclude='.wwebjs_auth' \
  --exclude='tmp/' \
  -e ssh \
  ~/.openclaw/ "${REMOTE}:~/.openclaw/"

# ── 2. LaunchAgents ───────────────────────────────────────────────────────────
echo ""
echo "▶ Transferring LaunchAgents..."
ssh "$REMOTE" "mkdir -p ~/Library/LaunchAgents"
rsync -avz --progress \
  -e ssh \
  ~/Library/LaunchAgents/com.amalfiai.* "${REMOTE}:~/Library/LaunchAgents/"

# ── 3. Claude settings + plugins ─────────────────────────────────────────────
echo ""
echo "▶ Transferring Claude settings..."
ssh "$REMOTE" "mkdir -p ~/.claude"
rsync -avz --progress \
  --exclude='projects/' \
  --exclude='conversations-md/' \
  --exclude='history.jsonl' \
  --exclude='cache/' \
  --exclude='debug/' \
  -e ssh \
  ~/.claude/ "${REMOTE}:~/.claude/"

# ── 4. Shell config ───────────────────────────────────────────────────────────
echo ""
echo "▶ Transferring shell config..."
rsync -avz -e ssh ~/.zshrc "${REMOTE}:~/.zshrc" 2>/dev/null || true
rsync -avz -e ssh ~/.zprofile "${REMOTE}:~/.zprofile" 2>/dev/null || true

# ── 5. Confirm ────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Transfer complete."
echo ""
echo "Now SSH into the Mac Mini and run:"
echo "  ssh ${REMOTE}"
echo "  bash ~/.openclaw/workspace-anthropic/scripts/setup-mac-mini.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
