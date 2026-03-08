#!/usr/bin/env bash
# sophia-calendar-alerts.sh
# Runs every 15 min. Checks Josh's calendar for events in the next 75 min.
# Pushes proactive WA alerts into proactive-queue.json for the gateway to fire.
# Avoids duplicate alerts via tmp/calendar-alerted.txt (event ID tracking).

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

OWNER_NUMBER="${WA_OWNER_NUMBER:-+27812705358}"
QUEUE_FILE="$WS/tmp/proactive-queue.json"
ALERTED_FILE="$WS/tmp/calendar-alerted.txt"
LOG="$WS/out/sophia-calendar-alerts.log"
OPENAI_KEY="${OPENAI_API_KEY:-}"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
mkdir -p "$WS/tmp" "$WS/out"
touch "$ALERTED_FILE" 2>/dev/null || true

log "Calendar alert check"

# Fetch today's events
export _EVENTS_JSON
_EVENTS_JSON=$(gog calendar events \
  --account josh@amalfiai.com \
  --json --results-only --no-input \
  today 2>/dev/null || echo "[]")

if [[ "$_EVENTS_JSON" == "[]" || -z "$_EVENTS_JSON" ]]; then
  log "No events today"
  exit 0
fi

export _OWNER_NUMBER="$OWNER_NUMBER"
export _QUEUE_FILE="$QUEUE_FILE"
export _ALERTED_FILE="$ALERTED_FILE"
export _OPENAI_KEY="$OPENAI_KEY"
export _NOW_ISO
_NOW_ISO=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
export _NOW_ISO

python3 - <<'PYALERT'
import json, os, sys, datetime, urllib.request

events_raw = json.loads(os.environ.get('_EVENTS_JSON', '[]'))
if not isinstance(events_raw, list):
    events_raw = events_raw.get('items', events_raw.get('events', []))

queue_file   = os.environ['_QUEUE_FILE']
alerted_file = os.environ['_ALERTED_FILE']
owner_number = os.environ['_OWNER_NUMBER']
openai_key   = os.environ.get('_OPENAI_KEY', '')
now_str      = os.environ['_NOW_ISO']

now = datetime.datetime.fromisoformat(now_str.replace('Z', '+00:00'))

# Load already-alerted event IDs
alerted = set()
if os.path.exists(alerted_file):
    alerted = set(open(alerted_file).read().split())

# Load existing queue
queue = []
if os.path.exists(queue_file):
    try: queue = json.loads(open(queue_file).read())
    except: queue = []

ALERT_WINDOWS = [
    (60, "1 hour"),
    (30, "30 minutes"),
    (15, "15 minutes"),
    (5,  "5 minutes"),
]

new_alerted = []
added = 0

for ev in events_raw:
    eid   = ev.get('id', '') or ev.get('eventId', '')
    title = ev.get('summary', ev.get('title', '')) or '(untitled)'
    start = ev.get('start', {})
    # Support dateTime or date-only
    start_str = start.get('dateTime', '') if isinstance(start, dict) else str(start)
    if not start_str:
        continue

    try:
        start_dt = datetime.datetime.fromisoformat(start_str.replace('Z', '+00:00'))
    except Exception:
        continue

    # Skip all-day or past events
    if start_dt < now:
        continue

    minutes_away = (start_dt - now).total_seconds() / 60

    # Find the best alert window
    for window_min, window_label in ALERT_WINDOWS:
        alert_key = f"{eid}:{window_min}"
        if alert_key in alerted:
            continue
        # Fire if event is within window_min + 10 min buffer (so we don't miss due to timing jitter)
        if minutes_away <= window_min + 10:
            # Generate Sophia-style alert message
            attendees = ev.get('attendees', [])
            attendee_names = [a.get('displayName', a.get('email', '')) for a in attendees
                              if a.get('email', '') != 'josh@amalfiai.com']
            meet_link = ev.get('hangoutLink', ev.get('conferenceData', {}).get('entryPoints', [{}])[0].get('uri', '') if isinstance(ev.get('conferenceData'), dict) else '')

            location = ev.get('location', '') or ''
            context_bits = []
            if attendee_names:
                context_bits.append('with ' + ', '.join(attendee_names[:3]))
            if location:
                context_bits.append('at ' + location)
            if meet_link:
                context_bits.append(f'Meet: {meet_link}')

            time_str = start_dt.astimezone(datetime.timezone(datetime.timedelta(hours=2))).strftime('%H:%M')
            context = ' — ' + ' | '.join(context_bits) if context_bits else ''
            msg = f"📅 *{title}* in {window_label} ({time_str} SAST){context}"

            queue.append({
                'to': owner_number,
                'message': msg,
                'sendAt': None,  # immediate
            })
            new_alerted.append(alert_key)
            added += 1
            print(f"Alert queued: {title} in {window_label}")
            break  # only send one alert window per event per run

if added:
    with open(queue_file, 'w') as f:
        json.dump(queue, f, indent=2)
    with open(alerted_file, 'a') as f:
        f.write('\n'.join(new_alerted) + '\n')

# Prune alerted file to last 500 lines
lines = open(alerted_file).readlines() if os.path.exists(alerted_file) else []
if len(lines) > 500:
    open(alerted_file, 'w').writelines(lines[-500:])

print(f"Done: {added} alert(s) queued")
PYALERT

log "Done"
