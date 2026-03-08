#!/usr/bin/env bash
# sophia-mark-monitor.sh
# Runs every 30 min. Reads Mark's WhatsApp history, analyses Sophia's performance,
# patches sophia-personal-assistant.md with learnings, and logs issues.

set -euo pipefail

WS="/Users/henryburton/.openclaw/workspace-anthropic"
HISTORY="$WS/tmp/whatsapp-history-27845670913.jsonl"
PROMPT_FILE="$WS/prompts/sophia-personal-assistant.md"
NOTES_FILE="$WS/memory/mark-notes.md"
LOG="$WS/out/sophia-mark-monitor.log"
ISSUES_LOG="$WS/out/sophia-mark-issues.log"

set -a
source "$WS/.env.scheduler"
set +a

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

[[ ! -f "$HISTORY" ]] && { log "No history yet — skipping"; exit 0; }

HISTORY_CONTENT=$(cat "$HISTORY")
TURN_COUNT=$(wc -l < "$HISTORY" | tr -d ' ')
[[ "$TURN_COUNT" -lt 2 ]] && { log "Only $TURN_COUNT turns — skipping analysis"; exit 0; }

PROMPT_CONTENT=$(cat "$PROMPT_FILE")
NOTES_CONTENT=""
[[ -f "$NOTES_FILE" ]] && NOTES_CONTENT=$(cat "$NOTES_FILE")

export _HISTORY="$HISTORY_CONTENT"
export _PROMPT="$PROMPT_CONTENT"
export _NOTES="$NOTES_CONTENT"

ANALYSIS=$(python3 << 'PYEOF'
import os, json, urllib.request

history_raw = os.environ['_HISTORY']
prompt = os.environ['_PROMPT']
notes = os.environ.get('_NOTES', '')
api_key = os.environ.get('OPENAI_API_KEY', '')

if not api_key:
    import subprocess
    api_key = subprocess.check_output(
        ['security', 'find-generic-password', '-s', 'openai-api-key', '-w'],
        text=True
    ).strip()

turns = []
for line in history_raw.strip().split('\n'):
    if line.strip():
        try:
            turns.append(json.loads(line))
        except:
            pass

conv_text = '\n'.join(f"{t['role']}: {t['message']}" for t in turns)

system = """You are a quality analyst for Sophia, an AI personal assistant on WhatsApp.
Analyse Sophia's responses and identify specific issues. Be concise and actionable.

Look for:
- Responses that sound robotic, corporate, or like a helpdesk
- Responses that reveal internal technical details (Supabase, Vercel, APIs, databases, client management)
- Responses that are too long or bullet-pointed when conversational would be better
- Use of hyphens or dashes
- Wrapping responses in quotation marks
- Failure to sound warm and personal
- Missed opportunities to ask a follow-up question or deepen the relationship
- Anything that would make Mark feel he is talking to a bot rather than a smart friend

Output JSON with this structure:
{
  "issues": ["specific issue 1", "specific issue 2"],
  "prompt_additions": ["specific rule or instruction to add to the system prompt to prevent recurrence"],
  "overall_quality": "good|needs_work|poor",
  "summary": "one sentence on how Sophia is performing"
}"""

user = f"Current system prompt:\n{prompt}\n\nConversation so far:\n{conv_text}"

payload = json.dumps({
    "model": "gpt-4o",
    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    "temperature": 0.3,
    "max_tokens": 800,
    "response_format": {"type": "json_object"}
}).encode()

req = urllib.request.Request(
    'https://api.openai.com/v1/chat/completions',
    data=payload,
    headers={'Authorization': f'Bearer {api_key}', 'Content-Type': 'application/json'}
)
resp = urllib.request.urlopen(req)
result = json.loads(resp.read())
print(result['choices'][0]['message']['content'])
PYEOF
)

log "Analysis: $ANALYSIS"

# Log issues separately
ISSUES=$(echo "$ANALYSIS" | python3 -c "import json,sys; d=json.load(sys.stdin); [print(i) for i in d.get('issues',[])]" 2>/dev/null || true)
QUALITY=$(echo "$ANALYSIS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('overall_quality','?'))" 2>/dev/null || echo "?")
SUMMARY=$(echo "$ANALYSIS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('summary',''))" 2>/dev/null || true)

log "Quality: $QUALITY — $SUMMARY"
if [[ -n "$ISSUES" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ISSUES:" >> "$ISSUES_LOG"
    echo "$ISSUES" >> "$ISSUES_LOG"
    echo "---" >> "$ISSUES_LOG"
fi

# Apply prompt additions if quality is not good
ADDITIONS=$(echo "$ANALYSIS" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d.get('prompt_additions',[])))" 2>/dev/null || true)

if [[ -n "$ADDITIONS" ]] && [[ "$QUALITY" != "good" ]]; then
    log "Applying prompt improvements..."
    export _ADDITIONS="$ADDITIONS"
    export _PROMPT_FILE="$PROMPT_FILE"
    python3 << 'PYEOF'
import os, urllib.request, json

additions = os.environ['_ADDITIONS']
prompt_file = os.environ['_PROMPT_FILE']
api_key = os.environ.get('OPENAI_API_KEY', '')

if not api_key:
    import subprocess
    api_key = subprocess.check_output(
        ['security', 'find-generic-password', '-s', 'openai-api-key', '-w'],
        text=True
    ).strip()

with open(prompt_file) as f:
    current = f.read()

system = "You are a system prompt editor. You receive a system prompt and a list of improvements. Integrate the improvements cleanly into the prompt without making it longer than necessary. Output only the full updated prompt, no commentary."
user = f"Current prompt:\n{current}\n\nImprovements to integrate:\n{additions}"

payload = json.dumps({
    "model": "gpt-4o",
    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    "temperature": 0.2,
    "max_tokens": 1200,
}).encode()

req = urllib.request.Request(
    'https://api.openai.com/v1/chat/completions',
    data=payload,
    headers={'Authorization': f'Bearer {api_key}', 'Content-Type': 'application/json'}
)
resp = urllib.request.urlopen(req)
result = json.loads(resp.read())
new_prompt = result['choices'][0]['message']['content'].strip()

with open(prompt_file, 'w') as f:
    f.write(new_prompt)
print("Prompt updated")
PYEOF
    log "Prompt improvements applied"
fi

log "Monitor run complete"
