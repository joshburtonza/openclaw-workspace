#!/usr/bin/env bash
# calendar-sync.sh — syncs Google Calendar events to Supabase calendar_events table
# Runs every 30 minutes via LaunchAgent
# Requires: Google Calendar API enabled at console.cloud.google.com
#   → APIs & Services → Enable APIs → Google Calendar API → Enable
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

export SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
export SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY}"
export BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
_CHAT_ID_FILE="$WORKSPACE/tmp/josh_private_chat_id"
export CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-$(cat "$_CHAT_ID_FILE" 2>/dev/null || echo "1140320036")}"
ACCOUNT="josh@amalfiai.com"

# State file: tracks which events we've already alerted about
ALERTED_FILE="$WORKSPACE/tmp/calendar-alerted"
touch "$ALERTED_FILE" 2>/dev/null || true
export ALERTED_FILE

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Calendar sync starting"

# ── 1. Fetch next 7 days from Google Calendar (all calendars) ─────────────────
EVENTS_JSON=$(gog calendar events \
  --account "$ACCOUNT" \
  --days 7 \
  --all \
  --max 50 \
  --json \
  --results-only 2>/dev/null || echo "[]")

if [[ "$EVENTS_JSON" == "[]" || -z "$EVENTS_JSON" ]]; then
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") No events in next 7 days"
  # Still run alerting section in case of upcoming events already in DB
else

# ── 2. Upsert events to Supabase ──────────────────────────────────────────────
UPSERTED=$(echo "$EVENTS_JSON" | python3 -c "
import json, sys, requests, os

events_raw = json.loads(sys.stdin.read())
if isinstance(events_raw, list):
    events = events_raw
elif isinstance(events_raw, dict):
    events = events_raw.get('items', events_raw.get('events', []))
else:
    events = []

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_KEY']

upserted = 0
for e in events:
    eid = e.get('id','')
    if not eid:
        continue
    start = e.get('start',{})
    end = e.get('end',{})
    start_at = start.get('dateTime') or start.get('date','') + 'T00:00:00Z'
    end_at = end.get('dateTime') or end.get('date','') + 'T00:00:00Z'
    all_day = 'date' in start and 'dateTime' not in start

    attendees = [a.get('email','') for a in e.get('attendees',[]) if a.get('email')]
    meet_link = ''
    for ep in e.get('conferenceData',{}).get('entryPoints',[]):
        if ep.get('entryPointType') == 'video':
            meet_link = ep.get('uri','')
            break

    row = {
        'id': eid,
        'title': e.get('summary') or e.get('title') or '(No title)',
        'description': e.get('description') or '',
        'start_at': start_at,
        'end_at': end_at,
        'all_day': all_day,
        'calendar_id': e.get('calendarId') or e.get('organizer',{}).get('email',''),
        'location': e.get('location') or '',
        'attendees': attendees,
        'status': e.get('status','confirmed'),
        'meet_link': meet_link,
        'synced_at': 'now()',
    }

    r = requests.post(
        URL + '/rest/v1/calendar_events',
        headers={
            'apikey': KEY,
            'Authorization': 'Bearer ' + KEY,
            'Content-Type': 'application/json',
            'Prefer': 'resolution=merge-duplicates,return=minimal',
        },
        json=row,
        timeout=10
    )
    if r.status_code in (200, 201):
        upserted += 1

print(upserted)
" 2>/dev/null || echo "0")

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Upserted $UPSERTED events"
fi

# ── 3. Alert for events starting in next 60 minutes ──────────────────────────
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PLUS60=$(date -u -v +60M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+60 minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

UPCOMING=$(curl -s "${SUPABASE_URL}/rest/v1/calendar_events?start_at=gte.${NOW_ISO}&start_at=lte.${PLUS60}&status=eq.confirmed&select=id,title,start_at,meet_link,location&order=start_at.asc" \
  -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $SUPABASE_KEY" 2>/dev/null || echo "[]")

echo "$UPCOMING" | python3 -c "
import json, sys, os, requests, time, calendar
from datetime import datetime

events = json.loads(sys.stdin.read()) or []
alerted_file = os.environ.get('ALERTED_FILE','')
bot = os.environ.get('BOT_TOKEN','')
chat = os.environ.get('CHAT_ID','')

# Load already-alerted IDs
alerted = set()
if alerted_file and os.path.exists(alerted_file):
    alerted = set(open(alerted_file).read().split())

new_alerted = []
for e in events:
    eid = e['id']
    if eid in alerted:
        continue

    # Parse start time
    start_raw = e.get('start_at','')[:19]
    try:
        ts = datetime.strptime(start_raw, '%Y-%m-%dT%H:%M:%S')
        mins = int((calendar.timegm(ts.timetuple()) - time.time()) / 60)
    except:
        mins = 0

    title = e.get('title','(No title)')
    meet = e.get('meet_link','')
    location = e.get('location','')

    msg = '📅 <b>Starting in ~' + str(max(0,mins)) + ' min:</b> ' + title
    if meet:
        msg += '\n🔗 ' + meet
    elif location:
        msg += '\n📍 ' + location

    requests.post(
        'https://api.telegram.org/bot' + bot + '/sendMessage',
        json={'chat_id': chat, 'text': msg, 'parse_mode': 'HTML'},
        timeout=10
    )
    new_alerted.append(eid)

if new_alerted and alerted_file:
    with open(alerted_file, 'a') as f:
        f.write('\n'.join(new_alerted) + '\n')

# Prune alerted file (keep last 200 lines)
if alerted_file and os.path.exists(alerted_file):
    lines = open(alerted_file).readlines()
    if len(lines) > 200:
        open(alerted_file, 'w').writelines(lines[-200:])
" 2>/dev/null

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Calendar sync complete"
