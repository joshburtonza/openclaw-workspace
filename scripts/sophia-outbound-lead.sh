#!/bin/bash
# sophia-outbound-lead.sh
# Sends Sophia's outbound intro email for a lead and books a Google Meet.
#
# Usage: bash sophia-outbound-lead.sh <lead_id> [task_queue_id]

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
API_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

LEAD_ID="${1:-}"
TASK_ID="${2:-}"

if [[ -z "$LEAD_ID" ]]; then
  echo "Usage: $0 <lead_id> [task_queue_id]" >&2
  exit 1
fi

echo "[sophia-outbound] Processing lead: $LEAD_ID"

# ── Fetch lead ────────────────────────────────────────────────────────────────

export LEAD_RAW=$(curl -s "${SUPABASE_URL}/rest/v1/leads?id=eq.${LEAD_ID}&select=*" \
  -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}")

eval $(python3 - <<'PY'
import json, os, sys
data = json.loads(os.environ['LEAD_RAW'])
if not data:
    print('echo "Lead not found" >&2; exit 1')
    sys.exit()
l = data[0]
first = l.get('first_name','').replace("'","")
last  = (l.get('last_name') or '').replace("'","")
email = l.get('email','')
co    = (l.get('company') or '').replace("'","")
print(f"FIRST_NAME='{first}'")
print(f"LAST_NAME='{last}'")
print(f"LEAD_EMAIL='{email}'")
print(f"COMPANY='{co}'")
PY
)

FULL_NAME="$FIRST_NAME"
if [[ -n "$LAST_NAME" ]]; then FULL_NAME="$FIRST_NAME $LAST_NAME"; fi

echo "[sophia-outbound] Lead: $FULL_NAME <$LEAD_EMAIL>"

# ── Calculate next business day at 10am SAST ──────────────────────────────────

export SLOT_RESULT=$(python3 - <<'PY'
from datetime import datetime, timedelta
import time

# SAST = UTC+2
utc_offset_sec = 2 * 3600
now_ts = time.time()
now_local = datetime.utcfromtimestamp(now_ts + utc_offset_sec)

candidate = now_local.replace(hour=10, minute=0, second=0, microsecond=0)

# If already past 9am today push to tomorrow
if now_local.hour >= 9:
    candidate += timedelta(days=1)

# Skip weekends
while candidate.weekday() >= 5:
    candidate += timedelta(days=1)

end = candidate + timedelta(hours=1)

def fmt(dt):
    return dt.strftime('%Y-%m-%dT%H:%M:%S+02:00')

days   = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday']
months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
display = f"{days[candidate.weekday()]} {candidate.day} {months[candidate.month - 1]}"

print(fmt(candidate))
print(fmt(end))
print(display)
PY
)

START_TIME=$(echo "$SLOT_RESULT" | sed -n '1p')
END_TIME=$(echo "$SLOT_RESULT"   | sed -n '2p')
DISPLAY_DATE=$(echo "$SLOT_RESULT" | sed -n '3p')

echo "[sophia-outbound] Slot: $DISPLAY_DATE at 10am SAST ($START_TIME)"

# ── Create Google Meet ────────────────────────────────────────────────────────

export MEET_JSON=$(gog calendar create "josh@amalfiai.com" \
  --summary "Discovery Call with ${FULL_NAME}" \
  --from "$START_TIME" \
  --to "$END_TIME" \
  --attendees "josh@amalfiai.com" \
  --with-meet \
  --json 2>/dev/null)

export MEET_LINK=$(python3 - <<'PY'
import json, os
data = json.loads(os.environ['MEET_JSON'])
eps = data.get('event', {}).get('conferenceData', {}).get('entryPoints', [])
for ep in eps:
    if ep.get('entryPointType') == 'video':
        print(ep['uri'])
        break
PY
)

if [[ -z "$MEET_LINK" ]]; then
  echo "[sophia-outbound] ERROR: failed to create Meet link" >&2
  exit 1
fi

echo "[sophia-outbound] Meet: $MEET_LINK"

# ── Build email ───────────────────────────────────────────────────────────────

SUBJECT="Your call with Amalfi AI"

export FIRST_NAME DISPLAY_DATE MEET_LINK

BODY_HTML=$(python3 - <<'PY'
import os
first      = os.environ['FIRST_NAME']
disp_date  = os.environ['DISPLAY_DATE']
meet_link  = os.environ['MEET_LINK']

print(
    '<div style="font-family:Arial,sans-serif;font-size:14px;line-height:1.75;color:#1a1a1a;max-width:580px">'
    + '<p style="margin:0 0 18px 0">Hi ' + first + ',</p>'
    + '<p style="margin:0 0 18px 0">I was asked to reach out and get a call in the diary with you. '
    + 'My name is Sophia and I look after appointments and client relationships at Amalfi AI.</p>'
    + '<p style="margin:0 0 18px 0">I have set up a 30 minute Google Meet for ' + disp_date + ' at 10am SAST. '
    + 'The link is below.</p>'
    + '<p style="margin:0 0 6px 0"><strong>' + disp_date + ' &nbsp; 10:00am SAST</strong></p>'
    + '<p style="margin:0 0 22px 0">'
    + '<a href="' + meet_link + '" style="display:inline-block;background:#1a1a2e;color:#4B9EFF;text-decoration:none;'
    + 'padding:10px 22px;border-radius:6px;font-weight:600;font-size:13px;border:1px solid rgba(75,158,255,0.2)">'
    + 'Join on Google Meet</a>'
    + '</p>'
    + '<p style="margin:0 0 18px 0">If that time does not work for you just reply and I will get something else sorted.</p>'
    + '<p style="margin:0 0 4px 0">Speak soon,</p>'
    + '<p style="margin:0"><strong>Sophia</strong></p>'
    + '<p style="margin:4px 0 0 0;color:#888;font-size:12px">Client Success Manager &nbsp; Amalfi AI</p>'
    + '</div>'
)
PY
)

BODY_TEXT="Hi ${FIRST_NAME},

I was asked to reach out and get a call in the diary with you. My name is Sophia and I look after appointments and client relationships at Amalfi AI.

I have set up a 30 minute Google Meet for ${DISPLAY_DATE} at 10am SAST. The link is below.

${DISPLAY_DATE}   10:00am SAST
Join the call: ${MEET_LINK}

If that time does not work for you just reply and I will get something else sorted.

Speak soon,
Sophia
Client Success Manager   Amalfi AI"

# ── Send email ────────────────────────────────────────────────────────────────

export BODY_HTML LEAD_EMAIL SUBJECT

SEND_OUT=$(python3 - <<'PY'
import subprocess, os, json
result = subprocess.run([
    'gog', 'gmail', 'send',
    '--account', 'sophia@amalfiai.com',
    '--to',      os.environ['LEAD_EMAIL'],
    '--subject', os.environ['SUBJECT'],
    '--body-html', os.environ['BODY_HTML'],
    '--json'
], capture_output=True, text=True)
if result.returncode != 0:
    import sys
    print(result.stderr, file=sys.stderr)
    sys.exit(1)
print(result.stdout)
PY
)

export SEND_OUT
GMAIL_MSG_ID=$(python3 - <<'PY'
import json, os
print(json.loads(os.environ['SEND_OUT']).get('messageId',''))
PY
)

if [[ -z "$GMAIL_MSG_ID" ]]; then
  echo "[sophia-outbound] ERROR: send failed" >&2
  exit 1
fi

echo "[sophia-outbound] Sent: $GMAIL_MSG_ID"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Log to outreach_log ───────────────────────────────────────────────────────

export BODY_TEXT NOW LEAD_ID GMAIL_MSG_ID SUBJECT SUPABASE_URL API_KEY

python3 - <<'PY'
import subprocess, json, os

url     = os.environ['SUPABASE_URL']
key     = os.environ['API_KEY']
payload = {
    'lead_id':          os.environ['LEAD_ID'],
    'step':             1,
    'subject':          os.environ['SUBJECT'],
    'body':             os.environ['BODY_TEXT'],
    'sent_at':          os.environ['NOW'],
    'gmail_message_id': os.environ['GMAIL_MSG_ID'],
}
subprocess.run([
    'curl', '-s', '-X', 'POST', f"{url}/rest/v1/outreach_log",
    '-H', 'Content-Type: application/json',
    '-H', f"apikey: {key}",
    '-H', f"Authorization: Bearer {key}",
    '-d', json.dumps(payload)
], check=False, stdout=subprocess.DEVNULL)
PY

# ── Update lead ───────────────────────────────────────────────────────────────

curl -s -X PATCH "${SUPABASE_URL}/rest/v1/leads?id=eq.${LEAD_ID}" \
  -H "apikey: ${API_KEY}" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"status\":\"contacted\",\"last_contacted_at\":\"${NOW}\",\"updated_at\":\"${NOW}\"}" \
  > /dev/null

# ── Log to email_queue for dashboard ─────────────────────────────────────────

export MEET_LINK NOW LEAD_ID GMAIL_MSG_ID SUBJECT LEAD_EMAIL SUPABASE_URL API_KEY

python3 - <<'PY'
import subprocess, json, os

url  = os.environ['SUPABASE_URL']
key  = os.environ['API_KEY']
payload = {
    'from_email': os.environ['LEAD_EMAIL'],
    'to_email':   os.environ['LEAD_EMAIL'],
    'subject':    os.environ['SUBJECT'],
    'status':     'sent',
    'sent_at':    os.environ['NOW'],
    'client':     'new_contact',
    'analysis': {
        'client_slug':      'new_contact',
        'sentiment':        'positive',
        'gmail_message_id': os.environ['GMAIL_MSG_ID'],
        'lead_id':          os.environ['LEAD_ID'],
        'meet_link':        os.environ['MEET_LINK'],
        'direction':        'outbound',
    },
}
subprocess.run([
    'curl', '-s', '-X', 'POST', f"{url}/rest/v1/email_queue",
    '-H', 'Content-Type: application/json',
    '-H', f"apikey: {key}",
    '-H', f"Authorization: Bearer {key}",
    '-d', json.dumps(payload)
], check=False, stdout=subprocess.DEVNULL)
PY

# ── Mark task done ────────────────────────────────────────────────────────────

if [[ -n "$TASK_ID" ]]; then
  export TASK_ID GMAIL_MSG_ID MEET_LINK NOW SUPABASE_URL API_KEY
  python3 - <<'PY'
import subprocess, json, os
url = os.environ['SUPABASE_URL']
key = os.environ['API_KEY']
payload = {
    'status':       'done',
    'completed_at': os.environ['NOW'],
    'result': {
        'gmail_message_id': os.environ['GMAIL_MSG_ID'],
        'meet_link':        os.environ['MEET_LINK'],
    },
}
subprocess.run([
    'curl', '-s', '-X', 'PATCH', f"{url}/rest/v1/task_queue?id=eq.{os.environ['TASK_ID']}",
    '-H', 'Content-Type: application/json',
    '-H', f"apikey: {key}",
    '-H', f"Authorization: Bearer {key}",
    '-d', json.dumps(payload)
], check=False, stdout=subprocess.DEVNULL)
PY
fi

echo "[sophia-outbound] Done. Lead ${LEAD_ID} contacted. Meet: ${MEET_LINK}"
