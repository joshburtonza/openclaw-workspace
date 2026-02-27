#!/usr/bin/env python3
"""
telegram-batch-dispatcher.py
Called as a background process each time a Telegram text message arrives.

Waits 3 seconds, then checks if it was the LAST message in the burst.
If so, collects all buffered messages and fires telegram-claude-gateway.sh once.
If a newer message arrived during the wait, exits silently (that dispatcher handles it).

Usage: python3 telegram-batch-dispatcher.py <chat_id> [group_history_file]
"""

import sys, time, os, subprocess

if len(sys.argv) < 2:
    sys.exit(1)

chat_id      = sys.argv[1]
group_hist   = sys.argv[2] if len(sys.argv) > 2 else ''
user_profile = sys.argv[3] if len(sys.argv) > 3 else 'josh'

WS = os.environ.get('AOS_ROOT', '/Users/henryburton/.openclaw/workspace-anthropic')
batch_file = f"{WS}/tmp/tg-batch-{chat_id}.txt"
last_file  = f"{WS}/tmp/tg-batch-{chat_id}.last"

# Wait for the burst to settle
time.sleep(3)

# Check if a newer message arrived after we woke up
try:
    last_t = float(open(last_file).read())
except Exception:
    last_t = 0

if time.time() - last_t < 2.8:
    # A newer message arrived — let that dispatcher handle the whole batch
    sys.exit(0)

# Atomically claim the batch (os.rename is atomic on same filesystem)
claimed = batch_file + '.claimed'
try:
    os.rename(batch_file, claimed)
except OSError:
    sys.exit(0)  # Another dispatcher claimed it first — we're done

try:
    combined = open(claimed).read().strip()
    os.remove(claimed)
    try:
        os.remove(last_file)
    except Exception:
        pass
except Exception:
    sys.exit(0)

if not combined:
    sys.exit(0)

# Fire the gateway with the full combined batch
subprocess.run([
    'bash',
    f'{WS}/scripts/telegram-claude-gateway.sh',
    chat_id,
    combined,
    group_hist,
    'text',
    user_profile,
])
