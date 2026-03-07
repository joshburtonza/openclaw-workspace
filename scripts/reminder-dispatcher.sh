#!/usr/bin/env bash
# reminder-dispatcher.sh — fires due reminders via the WA gateway /send API
# Runs every 5 minutes via LaunchAgent

WS="/Users/henryburton/.openclaw/workspace-anthropic"
REMINDERS="$WS/tmp/reminders.json"
LOG="$WS/out/reminder-dispatcher.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

[[ ! -f "$REMINDERS" ]] && exit 0

python3 << 'PYEOF'
import json, os, urllib.request, datetime

reminders_path = '/Users/henryburton/.openclaw/workspace-anthropic/tmp/reminders.json'
log_path       = '/Users/henryburton/.openclaw/workspace-anthropic/out/reminder-dispatcher.log'
api_url        = 'http://localhost:3001/send'

def log(msg):
    with open(log_path, 'a') as f:
        import datetime
        f.write(f"[{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")

try:
    with open(reminders_path) as f:
        reminders = json.load(f)
except:
    exit()

now = datetime.datetime.now(datetime.timezone.utc)
changed = False

for r in reminders:
    if r.get('fired'):
        continue
    fire_at = datetime.datetime.fromisoformat(r['fireAt'].replace('Z', '+00:00'))
    if now < fire_at:
        continue

    # Fire it
    name = r.get('name', 'there')
    message = r.get('message', '')
    to = r.get('to', '')

    # Sophia delivers it warmly
    wa_message = f"Hey {name}! Just a reminder: {message}"

    try:
        payload = json.dumps({"to": to, "message": wa_message}).encode()
        req = urllib.request.Request(api_url, data=payload,
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10)
        r['fired'] = True
        r['firedAt'] = now.isoformat()
        changed = True
        log(f"Fired reminder to {name} ({to}): {message}")
    except Exception as e:
        log(f"Failed to fire reminder to {name}: {e}")

if changed:
    with open(reminders_path, 'w') as f:
        json.dump(reminders, f, indent=2)

# Clean up reminders fired more than 7 days ago
cutoff = now - datetime.timedelta(days=7)
before = len(reminders)
reminders = [r for r in reminders if not r.get('fired') or
             datetime.datetime.fromisoformat(r.get('firedAt', now.isoformat()).replace('Z', '+00:00')) > cutoff]
if len(reminders) < before:
    with open(reminders_path, 'w') as f:
        json.dump(reminders, f, indent=2)
    log(f"Cleaned {before - len(reminders)} old fired reminders")
PYEOF
