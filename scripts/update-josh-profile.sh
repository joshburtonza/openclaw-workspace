#!/bin/bash
# update-josh-profile.sh
# Runs in the background after each Telegram gateway exchange.
# Uses Claude Haiku to extract any new facts about Josh from the latest
# conversation and merge them into memory/josh-profile.md.
#
# Called by: telegram-claude-gateway.sh (background, non-blocking)
# Usage: bash update-josh-profile.sh "<josh_message>" "<claude_response>"

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
PROFILE="$WS/memory/josh-profile.md"
LOCK="$WS/tmp/josh-profile-update.lock"

JOSH_MSG="${1:-}"
CLAUDE_RESP="${2:-}"

# Skip trivial exchanges — pure commands, single-word replies, flight searches
if [[ ${#JOSH_MSG} -lt 15 ]]; then exit 0; fi
if echo "$JOSH_MSG" | grep -qiE '^\s*/(flight|remind|ooo|available|help|newlead|start)\b'; then exit 0; fi

# Simple lock — only one update at a time
if [[ -f "$LOCK" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if [[ $LOCK_AGE -lt 120 ]]; then exit 0; fi
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# Load env
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

CURRENT_PROFILE=$(cat "$PROFILE" 2>/dev/null || echo "")

# Build prompt
export _JOSH_MSG="$JOSH_MSG"
export _CLAUDE_RESP="$CLAUDE_RESP"
export _PROFILE="$CURRENT_PROFILE"

PROMPT_TMP=$(mktemp /tmp/josh-profile-XXXXXX)
python3 - > "$PROMPT_TMP" 2>/dev/null <<'PY'
import os

josh_msg    = os.environ.get('_JOSH_MSG', '')
claude_resp = os.environ.get('_CLAUDE_RESP', '')
profile     = os.environ.get('_PROFILE', '')

print(f"""You are maintaining a personal profile of Josh, founder of Amalfi AI.

CURRENT PROFILE:
{profile}

LATEST CONVERSATION:
Josh: {josh_msg}
Claude: {claude_resp}

Identify any NEW facts about Josh worth remembering that are NOT already in the profile:
- Personal context (family, location, plans, events, health, routines)
- Preferences or opinions he expressed
- Patterns in how he communicates or what he expects
- Something he wants the bot to always/never do
- Travel plans, upcoming events, or ongoing situations

Rules:
- ONLY update if there is genuinely NEW information
- Do NOT add operational/technical facts (those belong in MEMORY.md)
- Do NOT add one-off task details
- Keep the profile under 80 lines total
- If nothing new: output exactly the word NOUPDATE and nothing else
- If there IS new info: output ONLY the complete updated profile — no explanation, no code fences, no preamble, just the raw markdown profile content starting with # Josh""")

PY

unset CLAUDECODE
RESULT=$(claude --print --model claude-haiku-4-5-20251001 < "$PROMPT_TMP" 2>/dev/null)
rm -f "$PROMPT_TMP"

# Strip code fences and any preamble before the # heading
CLEANED=$(echo "$RESULT" | python3 -c "
import sys, re
text = sys.stdin.read()
# Remove code fences
text = re.sub(r'\`\`\`[^\`]*\`\`\`', lambda m: m.group(0).strip('\`').lstrip('markdown\n'), text, flags=re.DOTALL)
text = re.sub(r'^\`\`\`\w*\n?', '', text); text = re.sub(r'\n?\`\`\`$', '', text.strip())
# Find the start of the actual profile (first # heading)
m = re.search(r'^#\s+Josh', text, re.MULTILINE)
if m: text = text[m.start():]
print(text.strip())
" 2>/dev/null || echo "")

# Only write back if we got a real update (not NOUPDATE and at least 200 chars)
if [[ -n "$CLEANED" && "$CLEANED" != "NOUPDATE" && ${#CLEANED} -gt 200 ]]; then
  echo "$CLEANED" > "$PROFILE"
fi
