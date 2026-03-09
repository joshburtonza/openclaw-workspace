#!/usr/bin/env bash
# setup-mac-mini.sh
# ─────────────────────────────────────────────────────────────────────────────
# Run this on the NEW Mac Mini to bootstrap the full Amalfi AI agent system.
#
# STEP 0 (on MacBook, before running this):
#   1. Set Mac Mini hostname to "amalfi-mac-mini" in System Settings > Sharing
#   2. Enable Remote Login (SSH) on Mac Mini in System Settings > Sharing
#   3. Create user "henryburton" on Mac Mini (same username — critical for paths)
#   4. Join Mac Mini to Tailscale: install tailscale → tailscale up → approve in admin
#   5. From MacBook, run the transfer commands at the bottom of this file
#   THEN run this script on the Mac Mini.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

MACBOOK_TAILSCALE_IP="100.94.119.113"   # henrys-macbook-air
WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"

log() { echo ""; echo "▶ $*"; echo ""; }

log "=== Amalfi AI Mac Mini Bootstrap ==="

# ── 1. Homebrew ───────────────────────────────────────────────────────────────
log "Installing Homebrew..."
if ! command -v brew &>/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# ── 2. Core CLI tools ─────────────────────────────────────────────────────────
log "Installing brew packages..."
brew install \
  node \
  python@3.13 \
  git \
  gh \
  ffmpeg \
  yt-dlp \
  jq \
  curl \
  wget \
  rsync \
  tailscale \
  sshpass \
  supabase \
  claude-cmd \
  gogcli \
  uv \
  1password-cli \
  gnupg

brew install --cask \
  claude-code \
  visual-studio-code \
  localsend \
  blender

# ── 3. npm globals ────────────────────────────────────────────────────────────
log "Installing npm globals..."
npm install -g \
  @anthropic-ai/claude-code \
  @tobilu/qmd \
  openclaw \
  pinchtab \
  clawdbot \
  clawdhub \
  context-mode \
  mcporter \
  vercel \
  wrangler

# ── 4. Python packages ────────────────────────────────────────────────────────
log "Installing Python packages..."
pip3 install --upgrade pip
pip3 install \
  openai \
  anthropic \
  httpx \
  aiohttp \
  requests \
  discord.py \
  numpy \
  pillow \
  supabase \
  pg8000

# ── 5. Workspace node_modules ─────────────────────────────────────────────────
log "Installing workspace node dependencies..."
if [[ -f "$WORKSPACE/package.json" ]]; then
  cd "$WORKSPACE"
  npm install
else
  echo "Workspace not yet transferred — run transfer step first"
fi

# ── 6. Claude Code settings ───────────────────────────────────────────────────
log "Writing Claude Code settings..."
mkdir -p ~/.claude
cat > ~/.claude/settings.json << 'EOF'
{
  "dangerouslySkipPermissions": true,
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
EOF

cat > ~/.claude/settings.local.json << 'EOF'
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  }
}
EOF

# ── 7. LaunchAgents ───────────────────────────────────────────────────────────
log "Loading LaunchAgents..."
mkdir -p ~/Library/LaunchAgents

if ls ~/Library/LaunchAgents/com.amalfiai.*.plist &>/dev/null; then
  for plist in ~/Library/LaunchAgents/com.amalfiai.*.plist; do
    label=$(basename "$plist" .plist)
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist" 2>/dev/null && echo "  loaded: $label" || echo "  FAILED: $label"
  done
  echo "LaunchAgents loaded."
else
  echo "No LaunchAgents found — run transfer step first"
fi

# ── 8. qmd model download ─────────────────────────────────────────────────────
log "Downloading qmd embedding model (1.3GB — one-time)..."
qmd init 2>/dev/null || echo "Run 'qmd init' manually after auth"

# ── 9. PATH setup ─────────────────────────────────────────────────────────────
log "Configuring PATH in ~/.zshrc..."
grep -q 'openclaw' ~/.zshrc 2>/dev/null || cat >> ~/.zshrc << 'ZSHEOF'

# Amalfi AI
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH="$HOME/.openclaw/bin:$PATH"
ZSHEOF

# ── 10. openclaw bin scripts permissions ─────────────────────────────────────
if [[ -d "$HOME/.openclaw/bin" ]]; then
  chmod +x ~/.openclaw/bin/* 2>/dev/null || true
fi

if [[ -d "$WORKSPACE/scripts" ]]; then
  chmod +x "$WORKSPACE/scripts"/*.sh 2>/dev/null || true
fi

log "=== Bootstrap complete ==="
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "MANUAL STEPS REMAINING (do these in order):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. TAILSCALE"
echo "   sudo tailscale up"
echo "   Then approve device at https://login.tailscale.com/admin"
echo ""
echo "2. CLAUDE AUTH"
echo "   claude"
echo "   (follow OAuth flow — log in with Anthropic account)"
echo ""
echo "3. GOG — authenticate both accounts"
echo "   gog accounts add josh@amalfiai.com"
echo "   gog accounts add sophia@amalfiai.com"
echo ""
echo "4. GITHUB CLI"
echo "   gh auth login"
echo ""
echo "5. WHATSAPP BOT — rescan QR code"
echo "   cd $WORKSPACE"
echo "   node scripts/whatsapp-wjs-gateway.cjs"
echo "   (scan QR with the bot phone: +27645066729)"
echo "   (once connected, Ctrl+C and let LaunchAgent take over)"
echo ""
echo "6. VERIFY agents are running"
echo "   launchctl list | grep com.amalfiai | grep -v '^\-'"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
