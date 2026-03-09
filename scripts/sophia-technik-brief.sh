#!/usr/bin/env bash
# sophia-technik-brief.sh
# One-time voice note to Josh — Monday 09 March 2026 08:30 SAST
# Briefs Josh on Race Technik's TECHNIK social media project before the regular morning brief.
# Self-unloads the LaunchAgent after running.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

WA_API="http://127.0.0.1:3001"
JOSH_NUMBER="${WA_OWNER_NUMBER:-+27812705358}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
BRIEF_FILE="$WS/clients/chrome-auto-care/TECHNIK-BRIEF.md"
LOG="$WS/out/sophia-technik-brief.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
mkdir -p "$WS/out"

log "TECHNIK brief voice note starting"

export _BRIEF; _BRIEF=$(cat "$BRIEF_FILE" 2>/dev/null || echo "No brief file found")
export _OPENAI_KEY="$OPENAI_KEY"
export _WA_API="$WA_API"
export _JOSH_NUMBER="$JOSH_NUMBER"

python3 - <<'PYBRIEF'
import json, os, urllib.request

openai_key  = os.environ.get('_OPENAI_KEY', '')
wa_api      = os.environ.get('_WA_API', '')
josh_number = os.environ.get('_JOSH_NUMBER', '')
brief       = os.environ.get('_BRIEF', '')

def call_gpt(system, user, model='gpt-4o', max_tokens=500):
    payload = json.dumps({
        'model': model,
        'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user',   'content': user},
        ],
        'max_tokens': max_tokens,
        'temperature': 0.7,
    }).encode()
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=payload,
        headers={'Authorization': f'Bearer {openai_key}', 'Content-Type': 'application/json'},
        method='POST')
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f'GPT error: {e}')
        return None

def send_wa_voice(text):
    payload = json.dumps({'to': josh_number, 'text': text}).encode()
    req = urllib.request.Request(f'{wa_api}/send-voice', data=payload,
        headers={'Content-Type': 'application/json'}, method='POST')
    try:
        urllib.request.urlopen(req, timeout=30)
        print('Voice note sent')
    except Exception as e:
        print(f'WA voice error: {e}')

script = call_gpt(
    'You are Sophia from Amalfi AI. Write a natural spoken voice note for Josh, the founder. '
    'This is a separate brief from the regular Monday morning client update. '
    'You are briefing him on a brand new project that Race Technik wants to build. '
    'Tone: excited, sharp, conversational. Like a colleague who has just read through a detailed brief and is giving Josh the quick version before he starts his day. '
    'No lists, no markdown, no hyphens. Sound like natural speech. Max 160 words. '
    'End with a line about sitting down to brainstorm it properly.',
    f'Morning Josh — brief him on this new Race Technik project before his regular morning update.\n\n{brief[:3000]}'
)

if script:
    print(f'Script: {script}')
    send_wa_voice(script)
else:
    print('GPT returned nothing')

PYBRIEF

log "TECHNIK brief voice note complete"

# Self-unload — this is a one-time run
launchctl unload ~/Library/LaunchAgents/com.amalfiai.sophia-technik-brief.plist 2>/dev/null || true
