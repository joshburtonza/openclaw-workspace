#!/usr/bin/env bash
# sophia-calendar.sh — Google Calendar management for Sophia WhatsApp gateway
#
# Commands:
#   sophia-calendar.sh list [today|tomorrow|YYYY-MM-DD]
#   sophia-calendar.sh create --title "..." --date "YYYY-MM-DD" --start "HH:MM" [--end "HH:MM"] [--meet] [--attendees "a@b.com,..."] [--desc "..."]
#   sophia-calendar.sh delete --date "YYYY-MM-DD" --search "keyword"
#   sophia-calendar.sh update --date "YYYY-MM-DD" --search "keyword" [--new-start "HH:MM"] [--new-end "HH:MM"] [--new-date "YYYY-MM-DD"] [--new-title "..."]
#
# Always exits 0 and prints JSON: { "ok": bool, "result": "...", "error": "..." }

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

ACCOUNT="josh@amalfiai.com"
CALENDAR_ID="primary"
TZ_OFFSET="+02:00"

ok()  { python3 -c "import json,sys; print(json.dumps({'ok':True,'result':sys.argv[1]}))" "$1"; }
fail(){ python3 -c "import json,sys; print(json.dumps({'ok':False,'error':sys.argv[1]}))"  "$1"; }

CMD="${1:-list}"
shift || true

resolve_date() {
  local d="${1:-today}"
  case "$d" in
    today)    date '+%Y-%m-%d' ;;
    tomorrow) date -v+1d '+%Y-%m-%d' 2>/dev/null || date -d tomorrow '+%Y-%m-%d' ;;
    monday|tuesday|wednesday|thursday|friday|saturday|sunday)
      export _DAY="$d"
      python3 -c "
import datetime, os
today = datetime.date.today()
days = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday']
target = days.index(os.environ['_DAY'].lower())
diff = (target - today.weekday()) % 7 or 7
print((today + datetime.timedelta(days=diff)).isoformat())
" ;;
    *) echo "$d" ;;
  esac
}

# ── LIST ───────────────────────────────────────────────────────────────────────
if [[ "$CMD" == "list" ]]; then
  RAW_DATE="${1:-today}"
  TARGET_DATE=$(resolve_date "$RAW_DATE")

  export _EVENTS_JSON
  _EVENTS_JSON=$(gog calendar events \
    --account "$ACCOUNT" \
    --days 1 \
    --all \
    --json \
    --results-only \
    --no-input 2>/dev/null || echo "[]")

  export _TARGET_DATE="$TARGET_DATE"
  RESULT=$(python3 - <<'PYLIST'
import json, os

events_raw = json.loads(os.environ.get('_EVENTS_JSON', '[]'))
if not isinstance(events_raw, list):
    events_raw = events_raw.get('items', [])

target = os.environ.get('_TARGET_DATE', '')
lines = []
for e in events_raw:
    start = e.get('start', {})
    dt_str = start.get('dateTime', '')
    date_str = start.get('date', '')
    event_date = dt_str[:10] if dt_str else date_str
    if event_date != target:
        continue
    title = e.get('summary') or '(No title)'
    if dt_str:
        t = dt_str[11:16]
        end_dt = e.get('end', {}).get('dateTime', '')
        end_t = end_dt[11:16] if end_dt else ''
        time_str = t + ('-' + end_t if end_t else '')
    else:
        time_str = 'All day'
    meet = ''
    for ep in e.get('conferenceData', {}).get('entryPoints', []):
        if ep.get('entryPointType') == 'video':
            meet = ' [Meet: ' + ep.get('uri', '') + ']'
            break
    attendees = [a.get('email', '') for a in e.get('attendees', []) if not a.get('self')]
    att_str = ' (with: ' + ', '.join(attendees[:3]) + ')' if attendees else ''
    lines.append(time_str + ' — ' + title + att_str + meet)

if lines:
    print('Calendar for ' + target + ':\n' + '\n'.join(lines))
else:
    print('Nothing on the calendar for ' + target + '.')
PYLIST
)
  ok "$RESULT"
  exit 0
fi

# ── CREATE ─────────────────────────────────────────────────────────────────────
if [[ "$CMD" == "create" ]]; then
  TITLE="" DATE="" START_T="" END_T="" WITH_MEET=0 ATTENDEES="" DESC=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)     TITLE="$2";     shift 2 ;;
      --date)      DATE="$2";      shift 2 ;;
      --start)     START_T="$2";   shift 2 ;;
      --end)       END_T="$2";     shift 2 ;;
      --meet)      WITH_MEET=1;    shift ;;
      --attendees) ATTENDEES="$2"; shift 2 ;;
      --desc)      DESC="$2";      shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -z "$TITLE" || -z "$DATE" || -z "$START_T" ]] && { fail "title, date and start time required"; exit 0; }

  DATE=$(resolve_date "$DATE")

  if [[ -z "$END_T" ]]; then
    export _START_T="$START_T"
    END_T=$(python3 -c "
import os
h,m=map(int,os.environ['_START_T'].split(':'))
m+=60; h+=m//60; m%=60
print(f'{h:02d}:{m:02d}')")
  fi

  FROM_RFC="${DATE}T${START_T}:00${TZ_OFFSET}"
  TO_RFC="${DATE}T${END_T}:00${TZ_OFFSET}"

  ARGS=(gog calendar create "$CALENDAR_ID"
    --account "$ACCOUNT"
    --summary "$TITLE"
    --from "$FROM_RFC"
    --to "$TO_RFC"
    --json --results-only --no-input --force)
  [[ -n "$DESC" ]]         && ARGS+=(--description "$DESC")
  [[ -n "$ATTENDEES" ]]    && ARGS+=(--attendees "$ATTENDEES")
  [[ "$WITH_MEET" == "1" ]] && ARGS+=(--with-meet)

  CREATE_RESULT=$("${ARGS[@]}" 2>/dev/null || echo "{}")

  export _CREATE_JSON="$CREATE_RESULT"
  export _TITLE="$TITLE" _DATE="$DATE" _START_T="$START_T" _END_T="$END_T"
  MSG=$(python3 - <<'PYCREATE'
import json, os
d = json.loads(os.environ.get('_CREATE_JSON', '{}'))
eid = d.get('id', '')
title = os.environ.get('_TITLE', '')
date  = os.environ.get('_DATE', '')
st    = os.environ.get('_START_T', '')
et    = os.environ.get('_END_T', '')
if not eid:
    print('FAILED:' + os.environ.get('_CREATE_JSON','')[:100])
else:
    meet = ''
    for ep in d.get('conferenceData', {}).get('entryPoints', []):
        if ep.get('entryPointType') == 'video':
            meet = ' | Meet: ' + ep.get('uri', '')
            break
    print('Created: "' + title + '" on ' + date + ' ' + st + '-' + et + meet)
PYCREATE
)

  if [[ "$MSG" == FAILED* ]]; then
    fail "${MSG#FAILED:}"
  else
    ok "$MSG"
  fi
  exit 0
fi

# ── DELETE ─────────────────────────────────────────────────────────────────────
if [[ "$CMD" == "delete" ]]; then
  DATE="" SEARCH=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date)   DATE="$2";   shift 2 ;;
      --search) SEARCH="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -z "$SEARCH" ]] && { fail "search keyword required"; exit 0; }
  [[ -n "$DATE" ]] && DATE=$(resolve_date "$DATE")

  export _EVENTS_JSON
  _EVENTS_JSON=$(gog calendar events \
    --account "$ACCOUNT" \
    --days 14 \
    --all \
    --json --results-only --no-input 2>/dev/null || echo "[]")

  export _SEARCH="$SEARCH" _DATE="$DATE" _ACCOUNT="$ACCOUNT" _CAL="$CALENDAR_ID"
  RESULT=$(python3 - <<'PYDEL'
import json, os, subprocess

events_raw = json.loads(os.environ.get('_EVENTS_JSON', '[]'))
if not isinstance(events_raw, list):
    events_raw = events_raw.get('items', [])

search = os.environ.get('_SEARCH', '').lower()
target_date = os.environ.get('_DATE', '')
matches = []
for e in events_raw:
    title = (e.get('summary') or '').lower()
    start = e.get('start', {})
    event_date = start.get('dateTime', '')[:10] or start.get('date', '')
    if search in title:
        if not target_date or event_date == target_date:
            matches.append(e)

if not matches:
    print('No matching event found.')
elif len(matches) > 1:
    names = ', '.join([(e.get('summary') or 'Untitled') + ' (' + (e.get('start',{}).get('dateTime','')[:10] or '') + ')' for e in matches[:3]])
    print('Multiple matches: ' + names + '. Be more specific.')
else:
    e = matches[0]
    eid = e.get('id', '')
    title = e.get('summary', 'Untitled')
    r = subprocess.run(
        ['gog', 'calendar', 'delete', os.environ['_CAL'], eid,
         '--account', os.environ['_ACCOUNT'], '--force', '--no-input'],
        capture_output=True, text=True)
    if r.returncode == 0:
        print('Deleted: "' + title + '"')
    else:
        print('Delete failed: ' + r.stderr[:100])
PYDEL
)
  ok "$RESULT"
  exit 0
fi

# ── UPDATE ─────────────────────────────────────────────────────────────────────
if [[ "$CMD" == "update" ]]; then
  DATE="" SEARCH="" NEW_START="" NEW_END="" NEW_DATE="" NEW_TITLE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date)      DATE="$2";      shift 2 ;;
      --search)    SEARCH="$2";    shift 2 ;;
      --new-start) NEW_START="$2"; shift 2 ;;
      --new-end)   NEW_END="$2";   shift 2 ;;
      --new-date)  NEW_DATE="$2";  shift 2 ;;
      --new-title) NEW_TITLE="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -z "$SEARCH" ]] && { fail "search keyword required"; exit 0; }
  [[ -n "$DATE" ]]     && DATE=$(resolve_date "$DATE")
  [[ -n "$NEW_DATE" ]] && NEW_DATE=$(resolve_date "$NEW_DATE")

  export _EVENTS_JSON
  _EVENTS_JSON=$(gog calendar events \
    --account "$ACCOUNT" \
    --days 14 \
    --all \
    --json --results-only --no-input 2>/dev/null || echo "[]")

  export _SEARCH="$SEARCH" _DATE="$DATE" _ACCOUNT="$ACCOUNT" _CAL="$CALENDAR_ID"
  export _NEW_START="$NEW_START" _NEW_END="$NEW_END" _NEW_DATE="$NEW_DATE" _NEW_TITLE="$NEW_TITLE"
  export _TZ="$TZ_OFFSET"

  RESULT=$(python3 - <<'PYUPD'
import json, os, subprocess

events_raw = json.loads(os.environ.get('_EVENTS_JSON', '[]'))
if not isinstance(events_raw, list):
    events_raw = events_raw.get('items', [])

search      = os.environ.get('_SEARCH', '').lower()
target_date = os.environ.get('_DATE', '')
matches = []
for e in events_raw:
    title = (e.get('summary') or '').lower()
    start = e.get('start', {})
    event_date = start.get('dateTime', '')[:10] or start.get('date', '')
    if search in title:
        if not target_date or event_date == target_date:
            matches.append(e)

if not matches:
    print('No matching event found.')
elif len(matches) > 1:
    names = ', '.join([(e.get('summary') or 'Untitled') + ' (' + (e.get('start',{}).get('dateTime','')[:10] or '') + ')' for e in matches[:3]])
    print('Multiple matches: ' + names + '. Be more specific.')
else:
    e = matches[0]
    eid   = e.get('id', '')
    title = e.get('summary', 'Untitled')
    orig_start = e.get('start', {}).get('dateTime', '')
    orig_end   = e.get('end',   {}).get('dateTime', '')
    orig_date  = orig_start[:10] if orig_start else ''
    tz = os.environ.get('_TZ', '+02:00')

    new_start = os.environ.get('_NEW_START', '')
    new_end   = os.environ.get('_NEW_END', '')
    new_date  = os.environ.get('_NEW_DATE', '') or orig_date
    new_title = os.environ.get('_NEW_TITLE', '')

    args = ['gog', 'calendar', 'update', os.environ['_CAL'], eid,
            '--account', os.environ['_ACCOUNT'], '--no-input', '--force']
    changed = []

    if new_start:
        args += ['--from', new_date + 'T' + new_start + ':00' + tz]
        changed.append('start: ' + new_start)
    if new_end:
        args += ['--to', new_date + 'T' + new_end + ':00' + tz]
        changed.append('end: ' + new_end)
    if os.environ.get('_NEW_DATE') and not new_start:
        old_t  = orig_start[11:16] if orig_start else '09:00'
        old_et = orig_end[11:16]   if orig_end   else '10:00'
        args += ['--from', new_date + 'T' + old_t  + ':00' + tz]
        args += ['--to',   new_date + 'T' + old_et + ':00' + tz]
        changed.append('date: ' + new_date)
    if new_title:
        args += ['--summary', new_title]
        changed.append('title: ' + new_title)

    if not changed:
        print('No changes specified.')
    else:
        r = subprocess.run(args, capture_output=True, text=True)
        if r.returncode == 0:
            print('Updated "' + title + '": ' + ', '.join(changed))
        else:
            print('Update failed: ' + r.stderr[:100])
PYUPD
)
  ok "$RESULT"
  exit 0
fi

fail "Unknown command: $CMD. Use: list, create, delete, update"
