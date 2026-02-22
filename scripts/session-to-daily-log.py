#!/usr/bin/env python3
"""
session-to-daily-log.py
Converts an OpenClaw JSONL session file into a readable daily chat MD.

Usage:
  python3 session-to-daily-log.py <session.jsonl> [--out <output.md>]

If --out not specified, outputs to stdout.
"""

import sys
import json
import re
import argparse
from datetime import datetime, timezone


def clean_user_text(text: str) -> str:
    """Strip OpenClaw system injections from user messages."""
    # Remove <relevant-memories> blocks
    text = re.sub(r'<relevant-memories>.*?</relevant-memories>', '', text, flags=re.DOTALL)
    # Remove [System Message] blocks
    text = re.sub(r'\[System Message\].*?(?=\n\n|\Z)', '', text, flags=re.DOTALL)
    # Remove Conversation info JSON blocks
    text = re.sub(r'Conversation info \(untrusted metadata\):.*?```\n', '', text, flags=re.DOTALL)
    # Remove timestamp prefixes like [Fri 2026-02-20 09:24 GMT+2]
    text = re.sub(r'^\[.*?GMT[+-]\d+\]\s*', '', text.strip())
    return text.strip()


def extract_text(content) -> str:
    """Extract plain text from message content (str or list of blocks)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                if block.get('type') == 'text':
                    parts.append(block.get('text', ''))
                elif block.get('type') == 'tool_use':
                    name = block.get('name', 'tool')
                    parts.append(f'[tool: {name}]')
                elif block.get('type') == 'tool_result':
                    parts.append('[tool result]')
        return '\n'.join(parts)
    return str(content)


def format_ts(ts_str: str) -> str:
    try:
        dt = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
        # Convert to SAST (UTC+2)
        from datetime import timedelta
        dt_sast = dt.astimezone(timezone(timedelta(hours=2)))
        return dt_sast.strftime('%H:%M')
    except Exception:
        return ts_str


def parse_session(path: str) -> list:
    entries = []
    compaction_summary = None

    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            t = obj.get('type', '')

            if t == 'compaction':
                compaction_summary = obj.get('summary', '')

            elif t == 'message':
                msg = obj.get('message', {})
                role = msg.get('role', '')
                content = msg.get('content', '')
                ts = obj.get('timestamp', '')

                raw_text = extract_text(content)

                if role == 'user':
                    text = clean_user_text(raw_text)
                    if not text:
                        continue
                    entries.append({'role': 'user', 'ts': ts, 'text': text})
                elif role == 'assistant':
                    # Skip pure tool-use-only messages (no readable text)
                    text = extract_text(content)
                    # Filter out messages that are only tool calls
                    visible = re.sub(r'\[tool: \w+\]', '', text).strip()
                    if not visible:
                        continue
                    entries.append({'role': 'assistant', 'ts': ts, 'text': visible})

    return entries, compaction_summary


def build_md(entries: list, compaction_summary: str, date_str: str) -> str:
    lines = [f'# Chat Log — {date_str}', '']

    if compaction_summary:
        lines.append('## Prior context (compaction summary)')
        lines.append('')
        lines.append(compaction_summary.strip())
        lines.append('')
        lines.append('---')
        lines.append('')

    if not entries:
        lines.append('_(no messages)_')
        return '\n'.join(lines)

    for entry in entries:
        role = entry['role']
        ts = format_ts(entry['ts'])
        text = entry['text']

        if role == 'user':
            lines.append(f'**Josh** `{ts}`')
        else:
            lines.append(f'**Alex** `{ts}`')

        lines.append('')
        lines.append(text)
        lines.append('')
        lines.append('---')
        lines.append('')

    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description='Convert OpenClaw session JSONL to daily chat MD')
    parser.add_argument('session', help='Path to session .jsonl file')
    parser.add_argument('--out', help='Output markdown file path', default=None)
    parser.add_argument('--date', help='Date label (default: today SAST)', default=None)
    args = parser.parse_args()

    if args.date:
        date_str = args.date
    else:
        from datetime import timedelta
        now_sast = datetime.now(timezone(timedelta(hours=2)))
        date_str = now_sast.strftime('%Y-%m-%d')

    entries, compaction_summary = parse_session(args.session)
    md = build_md(entries, compaction_summary, date_str)

    if args.out:
        with open(args.out, 'w') as f:
            f.write(md)
        print(f'Written to {args.out} ({len(entries)} messages)')
    else:
        print(md)


if __name__ == '__main__':
    main()
