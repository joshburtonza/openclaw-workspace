#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Amalfi OS — install.sh
# Full bootstrap for a fresh AOS deployment on any Mac.
#
# Usage:
#   bash install.sh              # interactive setup
#   bash install.sh --check      # health check only (no install)
#   bash install.sh --reload     # reload all LaunchAgents (no prompts)
#
# Requirements: macOS, internet connection
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✓${RESET} $1"; }
warn() { echo -e "${YELLOW}⚠${RESET}  $1"; }
err()  { echo -e "${RED}✗${RESET} $1"; }
info() { echo -e "${BLUE}→${RESET} $1"; }
hdr()  { echo -e "\n${BOLD}$1${RESET}"; echo "$(printf '─%.0s' {1..60})"; }

# ── Args ──────────────────────────────────────────────────────────────────────
MODE="install"
[[ "${1:-}" == "--check"  ]] && MODE="check"
[[ "${1:-}" == "--reload" ]] && MODE="reload"

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOS_ROOT="$SCRIPT_DIR"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
PLIST_DIR="$AOS_ROOT/launchagents"
ENV_FILE="$AOS_ROOT/.env.scheduler"
AOS_ENV="$AOS_ROOT/aos.env"
OUT_DIR="$AOS_ROOT/out"
TMP_DIR="$AOS_ROOT/tmp"

# ── Health check function (used in both check + install modes) ────────────────
run_health_check() {
  hdr "Health Check"

  local pass=0 fail=0

  # 1. aos.env loads correctly
  if source "$AOS_ENV" 2>/dev/null && [[ -n "${AOS_OWNER_NAME:-}" ]]; then
    ok "aos.env loads — owner: $AOS_OWNER_NAME ($AOS_OWNER_EMAIL)"
    ((pass++))
  else
    err "aos.env failed to load or AOS_OWNER_NAME missing"; ((fail++))
  fi

  # 2. .env.scheduler has secrets
  source "$ENV_FILE" 2>/dev/null || true
  if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" && "${SUPABASE_SERVICE_ROLE_KEY}" != "REPLACE_"* ]]; then
    ok "Supabase service role key present"
    ((pass++))
  else
    err "SUPABASE_SERVICE_ROLE_KEY missing or placeholder"; ((fail++))
  fi

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && "${TELEGRAM_BOT_TOKEN}" != "REPLACE_"* ]]; then
    ok "Telegram bot token present"
    ((pass++))
  else
    err "TELEGRAM_BOT_TOKEN missing or placeholder"; ((fail++))
  fi

  # 3. Dependencies
  for dep in brew node python3 gog; do
    if command -v "$dep" &>/dev/null; then
      ok "Dependency: $dep ($(command -v $dep))"
      ((pass++))
    else
      err "Missing dependency: $dep"; ((fail++))
    fi
  done

  if command -v claude &>/dev/null; then
    ok "Claude CLI: $(command -v claude)"
    ((pass++))
  else
    err "Claude CLI not found — run: npm install -g @anthropic-ai/claude-code"; ((fail++))
  fi

  # 4. LaunchAgents loaded
  local loaded=$(launchctl list 2>/dev/null | grep -c "com.amalfiai" || echo 0)
  if [[ "$loaded" -ge 10 ]]; then
    ok "LaunchAgents loaded: $loaded active"
    ((pass++))
  else
    warn "LaunchAgents loaded: $loaded (expected 30+)"; ((fail++))
  fi

  # 5. Supabase reachable
  if source "$ENV_FILE" 2>/dev/null && curl -s --max-time 5 \
    "${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}/rest/v1/" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY:-x}" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY:-x}" | grep -q "definitions" 2>/dev/null; then
    ok "Supabase reachable"
    ((pass++))
  else
    warn "Supabase unreachable (check network or key)"
  fi

  # 6. Telegram bot reachable
  if source "$ENV_FILE" 2>/dev/null && [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    BOT_RESP=$(curl -s --max-time 5 \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null || echo "{}")
    BOT_NAME=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('result',{}).get('username','?'))" 2>/dev/null <<< "$BOT_RESP" || echo "?")
    if [[ "$BOT_NAME" != "?" && -n "$BOT_NAME" ]]; then
      ok "Telegram bot: @$BOT_NAME"
      ((pass++))
    else
      err "Telegram bot unreachable (check TELEGRAM_BOT_TOKEN)"; ((fail++))
    fi
  fi

  # 7. Syntax check critical scripts
  local scripts=(
    "$AOS_ROOT/scripts/telegram-claude-gateway.sh"
    "$AOS_ROOT/email-response-scheduler.sh"
    "$AOS_ROOT/telegram-callback-poller.sh"
    "$AOS_ROOT/scripts/morning-brief.sh"
  )
  local syntax_ok=true
  for s in "${scripts[@]}"; do
    if [[ -f "$s" ]] && ! bash -n "$s" 2>/dev/null; then
      err "Syntax error: $(basename $s)"; syntax_ok=false; ((fail++))
    fi
  done
  [[ "$syntax_ok" == true ]] && ok "Critical script syntax: all clean" && ((pass++))

  echo ""
  if [[ "$fail" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All checks passed ($pass/$((pass+fail)))${RESET}"
  else
    echo -e "${YELLOW}${BOLD}$pass passed, $fail failed${RESET}"
  fi
}

# ── Check mode ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "check" ]]; then
  echo -e "${BOLD}Amalfi OS — Health Check${RESET}"
  source "$AOS_ENV" 2>/dev/null || true
  run_health_check
  exit 0
fi

# ── Reload mode ───────────────────────────────────────────────────────────────
if [[ "$MODE" == "reload" ]]; then
  hdr "Reloading all LaunchAgents"
  source "$AOS_ENV" 2>/dev/null || true
  for plist in "$PLIST_DIR"/com.amalfiai.*.plist; do
    name=$(basename "$plist" .plist)
    dest="$LAUNCH_DIR/$name.plist"
    # Generate plist with correct AOS_ROOT
    sed "s|/Users/henryburton/.openclaw/workspace-anthropic|${AOS_ROOT}|g; \
         s|/Users/henryburton|${HOME}|g" "$plist" > "$dest"
    launchctl unload "$dest" 2>/dev/null || true
    if launchctl load "$dest" 2>/dev/null; then
      ok "Reloaded: $name"
    else
      warn "Could not reload: $name"
    fi
  done
  echo ""
  ok "Done. $(launchctl list | grep -c com.amalfiai) agents active."
  exit 0
fi

# ── Full install ──────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}"
cat << 'BANNER'
   _____                .__  _____.__              ________    _________
  /  _  \   _____ _____|  |/ ____\__|             \_____  \  /   _____/
 /  /_\  \ /     \\__  \  \   __\|  |    ______    /   |   \ \_____  \
/    |    \  Y Y  \/ __ \  ||  |  |  |   /_____/  /    |    \/        \
\____|__  /__|_|  (____  /__||__|  |__|           \_______  /_______  /
        \/      \/     \/                                 \/        \/
BANNER
echo -e "${RESET}"
echo -e "${BOLD}Amalfi OS — Setup Wizard${RESET}"
echo "This will install AOS on this machine and configure it for your client."
echo ""
echo -e "Install path: ${BLUE}$AOS_ROOT${RESET}"
echo -e "Running as:   ${BLUE}$USER${RESET} on $(hostname)"
echo ""
read -rp "Continue? [y/N] " confirm
[[ "${confirm,,}" != "y" ]] && echo "Aborted." && exit 0

# ── Step 1: Dependencies ──────────────────────────────────────────────────────
hdr "Step 1 — Checking Dependencies"

install_if_missing() {
  local cmd="$1" install_cmd="$2" name="${3:-$1}"
  if command -v "$cmd" &>/dev/null; then
    ok "$name already installed"
  else
    info "Installing $name..."
    eval "$install_cmd"
    ok "$name installed"
  fi
}

# Homebrew
if ! command -v brew &>/dev/null; then
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ok "Homebrew installed"
else
  ok "Homebrew: $(brew --version | head -1)"
fi

install_if_missing node "brew install node" "Node.js"
install_if_missing python3 "brew install python3" "Python 3"

# Claude CLI
if ! command -v claude &>/dev/null; then
  info "Installing Claude CLI..."
  npm install -g @anthropic-ai/claude-code
  ok "Claude CLI installed"
else
  ok "Claude CLI: $(claude --version 2>/dev/null | head -1 || echo 'present')"
fi

# gog (Google OAuth CLI)
if ! command -v gog &>/dev/null; then
  warn "gog not found — you'll need to install it manually."
  warn "See: https://github.com/amalfiai/gog (or provide the binary path)"
  warn "Continuing without gog — some Gmail features won't work until it's installed."
else
  ok "gog: $(command -v gog)"
fi

# Python packages
info "Checking Python packages..."
python3 -c "import requests" 2>/dev/null || pip3 install requests -q
ok "Python requests available"

# ── Step 2: Create directories ────────────────────────────────────────────────
hdr "Step 2 — Creating Directories"

for dir in "$OUT_DIR" "$TMP_DIR" "$AOS_ROOT/memory" "$AOS_ROOT/data" \
           "$AOS_ROOT/clients" "$AOS_ROOT/prompts"; do
  mkdir -p "$dir"
  ok "Directory: $dir"
done

# ── Step 3: Client configuration ─────────────────────────────────────────────
hdr "Step 3 — Client Configuration"

echo "Enter the details for this AOS deployment."
echo ""

prompt_val() {
  local var="$1" label="$2" default="$3"
  local current="${!var:-$default}"
  read -rp "  $label [$current]: " input
  echo "${input:-$current}"
}

OWNER_NAME=$(prompt_val AOS_OWNER_NAME "Owner first name" "Josh")
OWNER_DISPLAY=$(prompt_val AOS_OWNER_DISPLAY "Owner full name" "$OWNER_NAME")
OWNER_EMAIL=$(prompt_val AOS_OWNER_EMAIL "Owner email (Gmail/Google Workspace)" "")
COMPANY=$(prompt_val AOS_COMPANY "Company name" "")
INDUSTRY=$(prompt_val AOS_INDUSTRY "Industry (e.g. AI Consulting, Legal, Property)" "")
TELEGRAM_CHAT_ID=$(prompt_val AOS_TELEGRAM_OWNER_CHAT_ID \
  "Owner Telegram chat ID (message @userinfobot to get it)" "")
BOT_USERNAME=$(prompt_val AOS_BOT_USERNAME "Telegram bot username (without @)" "")
SOPHIA_EMAIL=$(prompt_val AOS_SOPHIA_EMAIL \
  "Sophia's sending email (e.g. sophia@yourcompany.com)" "sophia@${COMPANY,,}.com")
EMAIL_CC=$(prompt_val AOS_EMAIL_CC \
  "CC on all Sophia emails (comma-separated, or leave blank)" "$OWNER_EMAIL")
TIMEZONE_DISPLAY=$(prompt_val AOS_TIMEZONE_DISPLAY "Timezone label (e.g. SAST, WAT, CAT)" "SAST")
TIMEZONE_UTC_HOURS=$(prompt_val AOS_TIMEZONE_UTC_HOURS "UTC offset hours (e.g. 2 for SAST)" "2")

# Write aos.env
cat > "$AOS_ENV" << AOSENV
# ─────────────────────────────────────────────────────────────────────────────
# Amalfi OS — Identity & Config
# Generated by install.sh on $(date '+%Y-%m-%d')
# ─────────────────────────────────────────────────────────────────────────────

AOS_ROOT="\${AOS_ROOT:-${AOS_ROOT}}"

AOS_OWNER_NAME="\${AOS_OWNER_NAME:-${OWNER_NAME}}"
AOS_OWNER_DISPLAY="\${AOS_OWNER_DISPLAY:-${OWNER_DISPLAY}}"
AOS_OWNER_EMAIL="\${AOS_OWNER_EMAIL:-${OWNER_EMAIL}}"
AOS_COMPANY="\${AOS_COMPANY:-${COMPANY}}"
AOS_INDUSTRY="\${AOS_INDUSTRY:-${INDUSTRY}}"

AOS_TELEGRAM_OWNER_CHAT_ID="\${AOS_TELEGRAM_OWNER_CHAT_ID:-${TELEGRAM_CHAT_ID}}"
AOS_BOT_USERNAME="\${AOS_BOT_USERNAME:-${BOT_USERNAME}}"

AOS_SOPHIA_EMAIL="\${AOS_SOPHIA_EMAIL:-${SOPHIA_EMAIL}}"
AOS_ALEX_EMAIL="\${AOS_ALEX_EMAIL:-alex@${OWNER_EMAIL#*@}}"
AOS_EMAIL_CC="\${AOS_EMAIL_CC:-${EMAIL_CC}}"

AOS_CALENDAR_ACCOUNT="\${AOS_CALENDAR_ACCOUNT:-${OWNER_EMAIL}}"
AOS_GMAIL_WATCH_ACCOUNT="\${AOS_GMAIL_WATCH_ACCOUNT:-${OWNER_EMAIL}}"

AOS_TIMEZONE_DISPLAY="\${AOS_TIMEZONE_DISPLAY:-${TIMEZONE_DISPLAY}}"
AOS_TIMEZONE_UTC_HOURS="\${AOS_TIMEZONE_UTC_HOURS:-${TIMEZONE_UTC_HOURS}}"
AOS_TIMEZONE_OFFSET="\${AOS_TIMEZONE_OFFSET:-+0${TIMEZONE_UTC_HOURS}:00}"
AOS_TIMEZONE="\${AOS_TIMEZONE:-Africa/Johannesburg}"

AOS_SUPABASE_URL="\${AOS_SUPABASE_URL:-https://REPLACE_WITH_SUPABASE_URL}"
AOSENV

ok "aos.env written"

# ── Step 4: Secrets ──────────────────────────────────────────────────────────
hdr "Step 4 — API Keys & Secrets"

echo "Enter API keys. Press Enter to skip any (edit .env.scheduler later)."
echo ""

read_secret() {
  local label="$1" default="${2:-}"
  read -rsp "  $label: " val
  echo ""
  echo "${val:-$default}"
}

SUPA_URL=$(prompt_val "" "Supabase project URL (https://xxx.supabase.co)" "")
SUPA_SERVICE_KEY=$(read_secret "Supabase service role key" "REPLACE_WITH_SUPABASE_SERVICE_ROLE_KEY")
SUPA_ANON_KEY=$(read_secret "Supabase anon key" "REPLACE_WITH_SUPABASE_ANON_KEY")
BOT_TOKEN=$(read_secret "Telegram bot token (from @BotFather)" "REPLACE_WITH_BOT_TOKEN")
OPENAI_KEY=$(read_secret "OpenAI API key" "REPLACE_WITH_OPENAI_KEY")
ANTHROPIC_KEY=$(read_secret "Anthropic API key (for Claude)" "REPLACE_WITH_ANTHROPIC_KEY")
DEEPGRAM_KEY=$(read_secret "Deepgram API key (voice transcription)" "REPLACE_WITH_DEEPGRAM_KEY")
BRAVE_KEY=$(read_secret "Brave Search API key" "REPLACE_WITH_BRAVE_KEY")

# Update AOS_SUPABASE_URL in aos.env with actual value
if [[ -n "$SUPA_URL" ]]; then
  sed -i '' "s|REPLACE_WITH_SUPABASE_URL|${SUPA_URL}|g" "$AOS_ENV"
fi

# Write .env.scheduler
cat > "$ENV_FILE" << ENVFILE
# Amalfi OS — Secrets
# Generated by install.sh on $(date '+%Y-%m-%d')
# DO NOT commit this file.

# Load identity config (non-secret)
_AOS_ENV="\$(dirname "\${BASH_SOURCE[0]:-\$0}")/aos.env"
if [[ -f "\$_AOS_ENV" ]]; then source "\$_AOS_ENV"; fi
unset _AOS_ENV

SUPABASE_SERVICE_ROLE_KEY=${SUPA_SERVICE_KEY}
SUPABASE_ANON_KEY=${SUPA_ANON_KEY}

TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_JOSH_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_SALAH_CHAT_ID=

OPENAI_API_KEY=${OPENAI_KEY}
DEEPGRAM_API_KEY=${DEEPGRAM_KEY}
BRAVE_API_KEY=${BRAVE_KEY}

# Gmail OAuth (set after running: gog gmail auth)
GMAIL_REFRESH_TOKEN=REPLACE_WITH_GMAIL_REFRESH_TOKEN
GMAIL_CLIENT_ID=REPLACE_WITH_GMAIL_CLIENT_ID
GMAIL_CLIENT_SECRET=REPLACE_WITH_GMAIL_CLIENT_SECRET

# Optional integrations
DISCORD_BOT_TOKEN=REPLACE_WITH_DISCORD_BOT_TOKEN
DISCORD_CHANNEL_ID=REPLACE_WITH_DISCORD_CHANNEL_ID
WHATSAPP_TOKEN=REPLACE_WITH_WHATSAPP_ACCESS_TOKEN
WHATSAPP_PHONE_ID=REPLACE_WITH_PHONE_NUMBER_ID
MINIMAX_API_KEY=REPLACE_WITH_MINIMAX_KEY
MINIMAX_GROUP_ID=REPLACE_WITH_MINIMAX_GROUP_ID
ENVFILE

ok ".env.scheduler written"

# ── Step 5: Generate LaunchAgent plists ──────────────────────────────────────
hdr "Step 5 — Generating LaunchAgents"

mkdir -p "$LAUNCH_DIR"
loaded=0
failed=0

for plist in "$PLIST_DIR"/com.amalfiai.*.plist; do
  [[ -f "$plist" ]] || continue
  name=$(basename "$plist" .plist)
  dest="$LAUNCH_DIR/$name.plist"

  # Replace hardcoded paths with actual AOS_ROOT and HOME
  sed "s|/Users/henryburton/.openclaw/workspace-anthropic|${AOS_ROOT}|g; \
       s|/Users/henryburton|${HOME}|g" "$plist" > "$dest"

  launchctl unload "$dest" 2>/dev/null || true
  if launchctl load "$dest" 2>/dev/null; then
    ok "Loaded: $name"
    ((loaded++))
  else
    warn "Could not load: $name (may require system restart)"
    ((failed++))
  fi
done

echo ""
info "$loaded agents loaded, $failed skipped"

# ── Step 6: Health check ─────────────────────────────────────────────────────
hdr "Step 6 — Health Check"
source "$AOS_ENV" 2>/dev/null || true
source "$ENV_FILE" 2>/dev/null || true
run_health_check

# ── Done ─────────────────────────────────────────────────────────────────────
hdr "Installation Complete"
echo ""
echo -e "${GREEN}${BOLD}Amalfi OS is installed for: $OWNER_NAME ($COMPANY)${RESET}"
echo ""
echo "Next steps:"
echo "  1. Authenticate Gmail:       gog gmail auth --account $OWNER_EMAIL"
echo "  2. Authenticate Calendar:    gog calendar auth --account $OWNER_EMAIL"
echo "  3. Log into Claude:          claude /login"
echo "  4. Send a test message to:   @$BOT_USERNAME on Telegram"
echo "  5. Health check anytime:     bash $AOS_ROOT/install.sh --check"
echo ""
echo "Logs:     $OUT_DIR/"
echo "Config:   $AOS_ENV"
echo "Secrets:  $ENV_FILE"
echo ""
