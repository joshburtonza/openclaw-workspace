#!/usr/bin/env bash
# =============================================================================
# Amalfi AI Autonomous Stack — Race Technik Mac Mini Setup
# =============================================================================
# Run this script once on the Race Technik Mac Mini to bootstrap the full
# autonomous agent stack.
#
# Usage:
#   bash setup.sh
#
# What it does:
#   1. Creates the ~/.amalfiai/workspace directory tree
#   2. Checks required dependencies (homebrew, git, node, ffmpeg, claude)
#   3. Clones the chrome-auto-care client repo
#   4. Writes a .env.scheduler template (fill in real values before starting)
#   5. Copies LaunchAgents from this deploy package and loads them
#   6. Prints a setup summary
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — adjust MACHINE_HOME if the primary user is not "farhaan"
# ---------------------------------------------------------------------------
MACHINE_HOME="${HOME}"              # Override: MACHINE_HOME=/Users/raceai bash setup.sh
WORKSPACE="${MACHINE_HOME}/.amalfiai/workspace"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHAGENTS_SRC="${DEPLOY_DIR}/launchagents"
LAUNCHAGENTS_DST="${MACHINE_HOME}/Library/LaunchAgents"
ENV_FILE="${WORKSPACE}/.env.scheduler"
CLIENTS_DIR="${WORKSPACE}/clients"
CHROME_AUTO_CARE_REPO="git@github.com:amalfiai/chrome-auto-care.git"

# Colours
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_step()  { echo -e "\n${CYAN}${BOLD}==> $*${RESET}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${RESET} $*"; }
log_warn()  { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
log_error() { echo -e "  ${RED}[ERROR]${RESET} $*"; }
log_info()  { echo -e "       $*"; }

WARNINGS=()
record_warn() { WARNINGS+=("$1"); log_warn "$1"; }

# ---------------------------------------------------------------------------
# 0. Confirm the machine home directory
# ---------------------------------------------------------------------------
log_step "Confirming machine home directory"
echo -e "  Detected home: ${BOLD}${MACHINE_HOME}${RESET}"
read -rp "  Is this correct? [Y/n]: " confirm
confirm="${confirm:-Y}"
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo ""
    read -rp "  Enter the correct home directory (e.g. /Users/raceai): " MACHINE_HOME
    WORKSPACE="${MACHINE_HOME}/.amalfiai/workspace"
    ENV_FILE="${WORKSPACE}/.env.scheduler"
    CLIENTS_DIR="${WORKSPACE}/clients"
    LAUNCHAGENTS_DST="${MACHINE_HOME}/Library/LaunchAgents"
    log_info "Using home: ${MACHINE_HOME}"
fi

# ---------------------------------------------------------------------------
# 1. Create directory structure
# ---------------------------------------------------------------------------
log_step "Creating workspace directory structure"

DIRS=(
    "${WORKSPACE}"
    "${WORKSPACE}/scripts"
    "${WORKSPACE}/scripts/weekly-reports"
    "${WORKSPACE}/launchagents"
    "${WORKSPACE}/out"
    "${WORKSPACE}/tmp"
    "${WORKSPACE}/data"
    "${WORKSPACE}/prompts"
    "${WORKSPACE}/memory"
    "${WORKSPACE}/clients"
)

for dir in "${DIRS[@]}"; do
    if mkdir -p "${dir}"; then
        log_ok "Created: ${dir}"
    fi
done

# ---------------------------------------------------------------------------
# 2. Dependency checks
# ---------------------------------------------------------------------------
log_step "Checking required dependencies"

check_cmd() {
    local cmd="$1"
    local install_hint="${2:-}"
    if command -v "${cmd}" &>/dev/null; then
        log_ok "${cmd} found at $(command -v "${cmd}")"
        return 0
    else
        record_warn "${cmd} not found.${install_hint:+ Install hint: ${install_hint}}"
        return 1
    fi
}

check_cmd "brew"   "See https://brew.sh"
check_cmd "git"    "brew install git"
check_cmd "node"   "brew install node"
check_cmd "ffmpeg" "brew install ffmpeg"
check_cmd "python3" "brew install python3"
check_cmd "jq"     "brew install jq"

# Claude CLI check — look in both homebrew and npm global locations
if command -v claude &>/dev/null; then
    log_ok "claude CLI found at $(command -v claude)"
elif [ -f "/opt/homebrew/bin/claude" ]; then
    log_ok "claude CLI found at /opt/homebrew/bin/claude"
elif [ -f "/usr/local/bin/claude" ]; then
    log_ok "claude CLI found at /usr/local/bin/claude"
else
    record_warn "claude CLI not found. Install via: npm install -g @anthropic-ai/claude-code  OR follow https://claude.ai/code"
fi

# ---------------------------------------------------------------------------
# 3. Clone chrome-auto-care repo
# ---------------------------------------------------------------------------
log_step "Setting up chrome-auto-care client repo"

if [ -d "${CLIENTS_DIR}/chrome-auto-care/.git" ]; then
    log_ok "chrome-auto-care already cloned — skipping"
    log_info "To update: cd ${CLIENTS_DIR}/chrome-auto-care && git pull"
else
    log_info "Cloning ${CHROME_AUTO_CARE_REPO} ..."
    # Try SSH first; fall back to HTTPS if SSH keys are not configured
    if git clone "${CHROME_AUTO_CARE_REPO}" "${CLIENTS_DIR}/chrome-auto-care" 2>/dev/null; then
        log_ok "Cloned via SSH"
    else
        HTTPS_URL="https://github.com/amalfiai/chrome-auto-care.git"
        log_info "SSH clone failed — trying HTTPS (${HTTPS_URL}) ..."
        if git clone "${HTTPS_URL}" "${CLIENTS_DIR}/chrome-auto-care"; then
            log_ok "Cloned via HTTPS"
        else
            record_warn "Could not clone chrome-auto-care. Clone manually after setup."
            log_info "  git clone ${CHROME_AUTO_CARE_REPO} ${CLIENTS_DIR}/chrome-auto-care"
        fi
    fi
fi

# Write a CONTEXT.md stub if one does not exist
CONTEXT_FILE="${CLIENTS_DIR}/chrome-auto-care/CONTEXT.md"
if [ ! -f "${CONTEXT_FILE}" ]; then
    cat > "${CONTEXT_FILE}" << 'CONTEXT_STUB'
# chrome-auto-care — Race Technik Context

## Client
- **Company**: Race Technik
- **Primary contact**: Farhaan
- **Machine**: Race Technik Mac Mini

## Stack
- Auto service booking platform
- Yoco payment integration
- PWA

## Current focus
<!-- Update this section with current sprint focus -->
- TBD

## Notes
<!-- Add any relevant client notes here -->
CONTEXT_STUB
    log_ok "Created CONTEXT.md stub at ${CONTEXT_FILE}"
fi

# ---------------------------------------------------------------------------
# 4. Write .env.scheduler template (only if it does not exist)
# ---------------------------------------------------------------------------
log_step "Creating .env.scheduler template"

if [ -f "${ENV_FILE}" ]; then
    log_warn ".env.scheduler already exists — will NOT overwrite"
    log_info "Existing file: ${ENV_FILE}"
else
    cp "${DEPLOY_DIR}/.env.template" "${ENV_FILE}"
    # Patch MACHINE_HOME if it differs from /Users/raceai
    if [ "${MACHINE_HOME}" != "/Users/raceai" ]; then
        sed -i '' "s|/Users/raceai|${MACHINE_HOME}|g" "${ENV_FILE}" 2>/dev/null || true
    fi
    chmod 600 "${ENV_FILE}"
    log_ok "Written: ${ENV_FILE}"
    log_warn "IMPORTANT: Fill in all REPLACE_WITH_* values in ${ENV_FILE} before starting agents."
fi

# ---------------------------------------------------------------------------
# 5. Copy LaunchAgent plists
# ---------------------------------------------------------------------------
log_step "Installing LaunchAgent plists"

mkdir -p "${LAUNCHAGENTS_DST}"

PLIST_COUNT=0
for plist in "${LAUNCHAGENTS_SRC}"/*.plist; do
    [ -f "${plist}" ] || continue
    basename_plist="$(basename "${plist}")"
    dest="${LAUNCHAGENTS_DST}/${basename_plist}"

    # Patch HOME path inside plist if MACHINE_HOME differs from /Users/raceai
    if [ "${MACHINE_HOME}" != "/Users/raceai" ]; then
        sed "s|/Users/raceai|${MACHINE_HOME}|g" "${plist}" > "${dest}"
    else
        cp "${plist}" "${dest}"
    fi

    log_ok "Copied: ${basename_plist}"
    PLIST_COUNT=$((PLIST_COUNT + 1))
done

if [ "${PLIST_COUNT}" -eq 0 ]; then
    log_warn "No plists found in ${LAUNCHAGENTS_SRC}"
fi

# ---------------------------------------------------------------------------
# 6. Load LaunchAgents
# ---------------------------------------------------------------------------
log_step "Loading LaunchAgents with launchctl"

LOADED=()
FAILED=()

for plist in "${LAUNCHAGENTS_SRC}"/*.plist; do
    [ -f "${plist}" ] || continue
    basename_plist="$(basename "${plist}")"
    dest="${LAUNCHAGENTS_DST}/${basename_plist}"
    label="${basename_plist%.plist}"

    # Unload first in case it was previously loaded (ignore errors)
    launchctl unload "${dest}" 2>/dev/null || true

    if launchctl load "${dest}" 2>/dev/null; then
        log_ok "Loaded: ${label}"
        LOADED+=("${label}")
    else
        record_warn "Failed to load: ${label} — check plist syntax"
        FAILED+=("${label}")
    fi
done

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${CYAN}============================================================${RESET}"
echo -e "${BOLD}${CYAN}  Amalfi AI — Race Technik Stack Setup Summary${RESET}"
echo -e "${BOLD}${CYAN}============================================================${RESET}"
echo ""
echo -e "  ${BOLD}Workspace:${RESET}   ${WORKSPACE}"
echo -e "  ${BOLD}Clients:${RESET}     ${CLIENTS_DIR}"
echo -e "  ${BOLD}Env file:${RESET}    ${ENV_FILE}"
echo ""
echo -e "  ${BOLD}LaunchAgents loaded (${#LOADED[@]}):${RESET}"
for label in "${LOADED[@]}"; do
    echo -e "    ${GREEN}+${RESET} ${label}"
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}LaunchAgents failed to load (${#FAILED[@]}):${RESET}"
    for label in "${FAILED[@]}"; do
        echo -e "    ${RED}x${RESET} ${label}"
    done
fi

if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo ""
    echo -e "  ${BOLD}${YELLOW}Warnings to address:${RESET}"
    for w in "${WARNINGS[@]}"; do
        echo -e "    ${YELLOW}!${RESET} ${w}"
    done
fi

echo ""
echo -e "  ${BOLD}Next steps:${RESET}"
echo -e "    1. Fill in all secrets in: ${ENV_FILE}"
echo -e "    2. Ensure claude CLI is authenticated: claude auth login"
echo -e "    3. Copy all scripts from the Amalfi main workspace into:"
echo -e "       ${WORKSPACE}/scripts/"
echo -e "    4. Verify agents are running:"
echo -e "       launchctl list | grep com.racetechnik"
echo -e "    5. Tail a log to confirm activity:"
echo -e "       tail -f ${WORKSPACE}/out/telegram-poller.err.log"
echo ""
echo -e "${BOLD}${GREEN}Setup complete.${RESET}"
