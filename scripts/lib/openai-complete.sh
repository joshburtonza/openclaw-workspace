#!/bin/bash
# openai-complete.sh — OpenAI chat completions, drop-in replacement for: claude --print
#
# Usage:
#   echo "user message" | openai-complete.sh [--model gpt-4o] [--system "text"] [--system-file /path]
#
# Reads OPENAI_API_KEY from environment. Returns completion text on stdout.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

MODEL="gpt-4o-mini"
SYSTEM_PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)       MODEL="$2";              shift 2 ;;
    --system)      SYSTEM_PROMPT="$2";      shift 2 ;;
    --system-file) SYSTEM_PROMPT=$(cat "$2" 2>/dev/null || echo ""); shift 2 ;;
    *)             shift ;;
  esac
done

USER_CONTENT=$(cat)

if [[ -z "$USER_CONTENT" ]]; then
  exit 0
fi

export _OAI_KEY="$OPENAI_API_KEY"
export _OAI_MODEL="$MODEL"
export _OAI_SYSTEM="$SYSTEM_PROMPT"
export _OAI_USER="$USER_CONTENT"

python3 - <<'PY'
import json, urllib.request, os, sys

api_key = os.environ.get('_OAI_KEY', '')
model   = os.environ.get('_OAI_MODEL', 'gpt-4o-mini')
system  = os.environ.get('_OAI_SYSTEM', '')
user    = os.environ.get('_OAI_USER', '')

if not api_key:
    print("[openai-complete] OPENAI_API_KEY not set", file=sys.stderr)
    sys.exit(1)

messages = []
if system:
    messages.append({'role': 'system', 'content': system})
messages.append({'role': 'user', 'content': user})

payload = json.dumps({
    'model': model,
    'messages': messages,
    'temperature': 0.7,
}).encode()

req = urllib.request.Request(
    'https://api.openai.com/v1/chat/completions',
    data=payload,
    headers={
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json',
    }
)

try:
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
        text = data['choices'][0]['message']['content']
        print(text, end='')
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f"[openai-complete] HTTP {e.code}: {body}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"[openai-complete] error: {e}", file=sys.stderr)
    sys.exit(1)
PY
