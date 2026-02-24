#!/usr/bin/env python3
"""
openai-call.py
Calls OpenAI with a prompt file (stdin or file path) and returns the response.

Usage:
  python3 openai-call.py < prompt.txt
  python3 openai-call.py prompt.txt
  echo "prompt" | python3 openai-call.py

Model: configured via OPENAI_MODEL env var (default: gpt-4o)
Key:   configured via OPENAI_API_KEY env var
"""

import sys
import os

def main():
    api_key = os.environ.get('OPENAI_API_KEY', '')
    if not api_key:
        print("[openai-call] ERROR: OPENAI_API_KEY not set", file=sys.stderr)
        sys.exit(1)

    model = os.environ.get('OPENAI_MODEL', 'gpt-4o')

    # Read prompt from file arg or stdin
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        with open(sys.argv[1], 'r') as f:
            prompt = f.read()
    else:
        prompt = sys.stdin.read()

    if not prompt.strip():
        print("[openai-call] ERROR: empty prompt", file=sys.stderr)
        sys.exit(1)

    try:
        from openai import OpenAI
        client = OpenAI(api_key=api_key)

        response = client.chat.completions.create(
            model=model,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are a highly capable AI assistant. "
                        "Follow all instructions in the user message exactly. "
                        "Be concise, accurate, and grounded in the context provided."
                    )
                },
                {
                    "role": "user",
                    "content": prompt
                }
            ],
            temperature=0.4,
            max_tokens=4096,
        )

        content = response.choices[0].message.content or ''
        print(content)

    except Exception as e:
        print(f"[openai-call] ERROR: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
