#!/usr/bin/env bash
# claude-session-logger.sh
# Claude Code Stop hook — fires after every response.
# Logs the last user message to interaction_log for adaptive memory.
# Must exit 0 to avoid blocking Claude.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

# Read hook JSON from stdin into a bash var FIRST — heredoc wins stdin so we can't read in Python
HOOK_JSON=$(cat)
export HOOK_JSON

python3 - <<'PY'
import sys, json, os, urllib.request, datetime

KEY          = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
SUPABASE_URL = 'https://afmpbtynucpbglwtbfuz.supabase.co'

if not KEY:
    sys.exit(0)

try:
    hook_data = json.loads(os.environ.get('HOOK_JSON', '{}'))
except Exception:
    sys.exit(0)

# Don't recurse if already in a stop hook
if hook_data.get('stop_hook_active'):
    sys.exit(0)

session_id      = hook_data.get('session_id', '')
transcript_path = hook_data.get('transcript_path', '')

if not transcript_path or not os.path.exists(transcript_path):
    sys.exit(0)

# Find the last human text message in the JSONL transcript
# User entries can be: string content, list of text blocks, or list of tool_results (skip those)
user_text = ''
try:
    with open(transcript_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                if entry.get('type') != 'user':
                    continue
                content = entry.get('message', {}).get('content', '')
                # String content — direct human message
                if isinstance(content, str) and content.strip():
                    user_text = content.strip()
                # List content — find text blocks, skip tool_results
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get('type') == 'text':
                            candidate = block.get('text', '').strip()
                            if candidate:
                                user_text = candidate
                            break
            except Exception:
                continue
except Exception:
    sys.exit(0)

if not user_text:
    sys.exit(0)

now = datetime.datetime.now(datetime.timezone.utc)
payload = json.dumps({
    'actor':       'josh',
    'user_id':     'josh',
    'signal_type': 'claude_session',
    'signal_data': {
        'text':       user_text[:600],
        'length':     len(user_text),
        'session_id': session_id,
        'hour_utc':   now.hour,
        'weekday':    now.strftime('%A'),
    },
}).encode()

try:
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/interaction_log",
        data=payload,
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
        method='POST',
    )
    urllib.request.urlopen(req, timeout=5)
except Exception:
    pass

sys.exit(0)
PY
