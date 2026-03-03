#!/usr/bin/env bash
# claude-session-logger.sh
# Claude Code Stop hook — fires after every response.
# 1. Logs the last user message to interaction_log (adaptive memory signal)
# 2. Appends full terminal session to memory/YYYY-MM-DD.md (same as Telegram)
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
import sys, json, os, urllib.request, datetime, pathlib

KEY          = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
SUPABASE_URL = 'https://afmpbtynucpbglwtbfuz.supabase.co'
WS           = os.environ.get('AOS_ROOT', os.path.expanduser('~/.openclaw/workspace-anthropic'))

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

# ── Parse transcript: collect all human messages + assistant text ─────────────
messages = []
user_text = ''
try:
    with open(transcript_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                role = entry.get('type', '')
                content = entry.get('message', {}).get('content', '')

                if role == 'user':
                    text = ''
                    if isinstance(content, str) and content.strip():
                        text = content.strip()
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                t = block.get('text', '').strip()
                                if t:
                                    text = t
                                    break
                    if text:
                        user_text = text  # keep last for interaction_log
                        messages.append(('Josh', text))

                elif role == 'assistant':
                    text = ''
                    if isinstance(content, str) and content.strip():
                        text = content.strip()
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                t = block.get('text', '').strip()
                                if t:
                                    text = t
                                    break
                    if text:
                        messages.append(('Claude', text))
            except Exception:
                continue
except Exception:
    sys.exit(0)

# ── Write session to daily memory file ───────────────────────────────────────
if messages and KEY:
    tz_offset = datetime.timezone(datetime.timedelta(hours=2))  # SAST
    now_sast  = datetime.datetime.now(tz_offset)
    date_str  = now_sast.strftime('%Y-%m-%d')
    time_str  = now_sast.strftime('%H:%M')
    mem_file  = pathlib.Path(WS) / 'memory' / f'{date_str}.md'

    # Build session block — cap each message at 1000 chars to keep file sane
    lines = [f'\n### {time_str} SAST — Claude Code Terminal (session {session_id[:8]})\n']
    for speaker, text in messages:
        short = text[:1000] + ('...' if len(text) > 1000 else '')
        lines.append(f'**{speaker}:** {short}\n')

    session_block = '\n'.join(lines) + '\n'

    # Only append if this session_id isn't already in the file
    existing = mem_file.read_text() if mem_file.exists() else ''
    if session_id[:8] not in existing:
        with open(mem_file, 'a') as f:
            f.write(session_block)

# ── Log last user message to interaction_log (adaptive memory signal) ─────────
if not user_text or not KEY:
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
