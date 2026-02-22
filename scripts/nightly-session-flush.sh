#!/usr/bin/env bash
# nightly-session-flush.sh
# Converts today's anthropic:main session → daily chat log (memory/YYYY-MM-DD-chat.md)
# then resets the session clean for tomorrow.
# Memory extraction is handled by the calling agent (not this script).

set -euo pipefail

SESSIONS_DIR="/Users/henryburton/.openclaw/agents/anthropic/sessions"
SESSIONS_JSON="$SESSIONS_DIR/sessions.json"
WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
MEMORY_DIR="$WORKSPACE/memory"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/session-to-daily-log.py"

# Date in SAST
DATE=$(TZ=Africa/Johannesburg date '+%Y-%m-%d')
OUT_FILE="$MEMORY_DIR/$DATE-chat.md"

echo "[session-flush] Starting nightly flush: $DATE"

# ─────────────────────────────────────────────
# STEP 1: Find the current anthropic:main session
# ─────────────────────────────────────────────
SESSION_ID=$(python3 -c "
import json
with open('$SESSIONS_JSON') as f:
    d = json.load(f)
entry = d.get('agent:anthropic:main', {})
print(entry.get('sessionId', ''))
" 2>/dev/null || echo "")

if [ -z "$SESSION_ID" ]; then
    echo "[session-flush] No active session found."
    echo "FLUSH_STATUS=no_session"
    exit 0
fi

SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.jsonl"

if [ ! -f "$SESSION_FILE" ]; then
    echo "[session-flush] Session file missing — cleaning index."
    python3 -c "
import json
with open('$SESSIONS_JSON') as f: d = json.load(f)
d.pop('agent:anthropic:main', None)
with open('$SESSIONS_JSON', 'w') as f: json.dump(d, f, indent=2)
"
    echo "FLUSH_STATUS=no_session"
    exit 0
fi

echo "[session-flush] Found session: $SESSION_ID"

# ─────────────────────────────────────────────
# STEP 2: Convert session → daily chat markdown
# ─────────────────────────────────────────────
mkdir -p "$MEMORY_DIR"

if [ -f "$OUT_FILE" ]; then
    SUFFIX=$(TZ=Africa/Johannesburg date '+%H%M')
    OUT_FILE="$MEMORY_DIR/${DATE}-chat-${SUFFIX}.md"
fi

python3 "$PARSER" "$SESSION_FILE" --out "$OUT_FILE" --date "$DATE"
echo "[session-flush] Chat log: $OUT_FILE"

# ─────────────────────────────────────────────
# STEP 3: Archive session file
# ─────────────────────────────────────────────
ARCHIVE="${SESSION_ID}.jsonl.deleted.$(date -u '+%Y-%m-%dT%H-%M-%S').000Z"
mv "$SESSION_FILE" "$SESSIONS_DIR/$ARCHIVE"
echo "[session-flush] Archived: $ARCHIVE"

# ─────────────────────────────────────────────
# STEP 4: Clear session index
# ─────────────────────────────────────────────
python3 -c "
import json
with open('$SESSIONS_JSON') as f: d = json.load(f)
d.pop('agent:anthropic:main', None)
with open('$SESSIONS_JSON', 'w') as f: json.dump(d, f, indent=2)
print('[session-flush] Session index cleared.')
"

# ─────────────────────────────────────────────
# STEP 5: Prune archives older than 30 days
# ─────────────────────────────────────────────
find "$SESSIONS_DIR" -name "*.jsonl.deleted.*" -mtime +30 -delete 2>/dev/null && \
    echo "[session-flush] Pruned old archives."

# Print the output path so the calling agent can read it
echo "FLUSH_CHAT_LOG=$OUT_FILE"
echo "[session-flush] Done."
