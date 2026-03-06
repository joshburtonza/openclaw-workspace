#!/usr/bin/env bash
# session-backup.sh — Extracts Desktop App + CLI session transcripts into daily memory files
# Runs every 12 hours via LaunchAgent. Catches sessions the Stop hook missed.
# Processes ALL .jsonl transcript files modified since last run.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
MEMORY_DIR="$AOS_ROOT/memory"
MARKER_FILE="$AOS_ROOT/.last-session-backup"
CLAUDE_PROJECTS="$HOME/.claude/projects"

# Create marker file if first run — default to 24h ago
if [[ ! -f "$MARKER_FILE" ]]; then
    touch -t "$(date -v-24H '+%Y%m%d%H%M.%S')" "$MARKER_FILE"
fi

# Find all session .jsonl files modified since last backup (skip subagents)
# Search both project dirs and top-level sessions
find "$CLAUDE_PROJECTS" -maxdepth 3 -name "*.jsonl" -newer "$MARKER_FILE" -not -path "*/subagents/*" 2>/dev/null | while read -r transcript; do
    python3 - "$transcript" "$MEMORY_DIR" <<'PY'
import sys, json, datetime, pathlib, os

transcript_path = sys.argv[1]
memory_dir = sys.argv[2]

session_id = pathlib.Path(transcript_path).stem[:8]

# Parse transcript
messages = []
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

                if not text:
                    continue

                if role == 'user':
                    # Skip system prompts and continuations
                    if text.startswith('You are Claude Code') or text.startswith('This session is being continued'):
                        continue
                    messages.append(('Josh', text))
                elif role == 'assistant':
                    messages.append(('Claude', text))
            except Exception:
                continue
except Exception as e:
    print(f"Error reading {transcript_path}: {e}", file=sys.stderr)
    sys.exit(0)

if not messages:
    sys.exit(0)

# Determine date from file mtime
mtime = os.path.getmtime(transcript_path)
tz_offset = datetime.timezone(datetime.timedelta(hours=2))  # SAST
file_dt = datetime.datetime.fromtimestamp(mtime, tz=tz_offset)
date_str = file_dt.strftime('%Y-%m-%d')
time_str = file_dt.strftime('%H:%M')

mem_file = pathlib.Path(memory_dir) / f'{date_str}.md'

# Check if already logged
existing = mem_file.read_text() if mem_file.exists() else ''
if session_id in existing:
    sys.exit(0)

# Determine source (Desktop App vs CLI)
if '-Users-henryburton-claude' in transcript_path:
    source = 'Claude Desktop App'
elif 'workspace-anthropic' in transcript_path:
    source = 'Claude Code Terminal'
else:
    source = 'Claude Code'

# Build session block — cap each message at 1500 chars
lines = [f'\n### {time_str} SAST — {source} (session {session_id})\n']
for speaker, text in messages:
    short = text[:1500] + ('...' if len(text) > 1500 else '')
    # Clean up common noise
    short = short.replace('\x00', '')
    lines.append(f'**{speaker}:** {short}\n')

session_block = '\n'.join(lines) + '\n'

with open(mem_file, 'a') as f:
    f.write(session_block)

print(f"Logged session {session_id} ({len(messages)} msgs) to {date_str}.md")
PY
done

# Update marker
touch "$MARKER_FILE"

echo "Session backup complete: $(date '+%Y-%m-%d %H:%M:%S')"
