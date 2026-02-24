#!/usr/bin/env python3
"""
ai-supervisor.py
Given an original prompt + two AI responses (Claude and GPT), picks the better one.
Uses a fast/cheap model (gpt-4o-mini) to keep latency and cost low.

Usage:
  python3 ai-supervisor.py <prompt_file> <response_a_file> <response_b_file>

Outputs the better response to stdout.
Writes a brief reasoning log to stderr.
"""

import sys
import os

def main():
    if len(sys.argv) < 4:
        print("Usage: ai-supervisor.py <prompt_file> <response_a> <response_b>", file=sys.stderr)
        sys.exit(1)

    api_key = os.environ.get('OPENAI_API_KEY', '')
    if not api_key:
        # No key — fall back to response_a (Claude) by default
        print("[supervisor] No OPENAI_API_KEY — defaulting to response A", file=sys.stderr)
        with open(sys.argv[2], 'r') as f:
            print(f.read())
        return

    try:
        with open(sys.argv[1], 'r') as f:
            original_prompt = f.read()[:3000]  # Truncate for supervisor context
        with open(sys.argv[2], 'r') as f:
            response_a = f.read()
        with open(sys.argv[3], 'r') as f:
            response_b = f.read()
    except Exception as e:
        print(f"[supervisor] ERROR reading files: {e}", file=sys.stderr)
        sys.exit(1)

    if not response_a.strip() and not response_b.strip():
        print("[supervisor] Both responses empty", file=sys.stderr)
        sys.exit(1)

    # If one is empty, use the other
    if not response_a.strip():
        print("[supervisor] Response A empty — using B", file=sys.stderr)
        print(response_b)
        return
    if not response_b.strip():
        print("[supervisor] Response B empty — using A", file=sys.stderr)
        print(response_a)
        return

    supervisor_prompt = f"""You are a quality supervisor comparing two AI responses to the same task.

ORIGINAL TASK (truncated):
{original_prompt}

---

RESPONSE A (Claude):
{response_a}

---

RESPONSE B (GPT-4o):
{response_b}

---

Evaluate both responses on these criteria:
1. Accuracy — is it grounded in the context provided, or does it invent/assume?
2. Completeness — does it address everything asked?
3. Tone — is it appropriate for the relationship and context?
4. Specificity — does it reference real details, or is it generic?
5. Conciseness — does it say what needs to be said without padding?

Reply in this exact format:
WINNER: A or B
REASON: One sentence explaining why.
RESPONSE:
[paste the full winning response verbatim here]"""

    try:
        from openai import OpenAI
        client = OpenAI(api_key=api_key)

        result = client.chat.completions.create(
            model='gpt-4o-mini',
            messages=[{"role": "user", "content": supervisor_prompt}],
            temperature=0.1,
            max_tokens=5000,
        )

        output = result.choices[0].message.content or ''

        # Parse winner and response
        lines = output.strip().split('\n')
        winner = 'A'
        reason = ''
        response_start = None

        for i, line in enumerate(lines):
            if line.startswith('WINNER:'):
                winner = line.replace('WINNER:', '').strip()
            elif line.startswith('REASON:'):
                reason = line.replace('REASON:', '').strip()
            elif line.startswith('RESPONSE:'):
                response_start = i + 1
                break

        if response_start is not None and response_start < len(lines):
            final = '\n'.join(lines[response_start:]).strip()
        else:
            # Parsing failed — use stated winner
            final = response_a if winner == 'A' else response_b

        print(f"[supervisor] Winner: {winner} — {reason}", file=sys.stderr)
        print(final)

    except Exception as e:
        print(f"[supervisor] ERROR: {e} — defaulting to response A", file=sys.stderr)
        print(response_a)

if __name__ == '__main__':
    main()
