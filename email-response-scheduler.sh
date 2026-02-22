#!/bin/bash
# email-response-scheduler.sh
# Deterministic sender: send immediately for email_queue rows with status=approved.
# Updates status + sent_at on success; writes last_error + status=error_send_failed on failure.

set -euo pipefail

# Ensure Homebrew bin is in PATH (LaunchAgent runs with minimal environment)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"
ACCOUNT="sophia@amalfiai.com"
CC="josh@amalfiai.com,salah@amalfiai.com"

# Load service role key from secrets file (bypasses RLS so scheduler can read status=approved rows)
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
# Use service role key if available, otherwise fall back to anon key
API_KEY="${SUPABASE_SERVICE_ROLE_KEY:-$ANON_KEY}"

export SUPABASE_URL API_KEY ACCOUNT CC

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# Pull approved rows + auto_pending rows (filter by schedule in Python to avoid PostgREST nested-and quirks)
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
APPROVED=$(curl -s -G "${SUPABASE_URL}/rest/v1/email_queue" \
  --data-urlencode "status=eq.approved" \
  --data-urlencode "select=id,from_email,subject,analysis,gmail_thread_id,status,scheduled_send_at" \
  --data-urlencode "order=created_at.asc" \
  --data-urlencode "limit=10" \
  -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}")

AUTO=$(curl -s -G "${SUPABASE_URL}/rest/v1/email_queue" \
  --data-urlencode "status=eq.auto_pending" \
  --data-urlencode "scheduled_send_at=lte.${NOW_ISO}" \
  --data-urlencode "select=id,from_email,subject,analysis,gmail_thread_id,status,scheduled_send_at" \
  --data-urlencode "order=created_at.asc" \
  --data-urlencode "limit=10" \
  -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}")

export APPROVED AUTO
ROWS=$(python3 -c "
import json, os, sys
a = json.loads(os.environ.get('APPROVED','[]'))
b = json.loads(os.environ.get('AUTO','[]'))
if not isinstance(a, list): a = []
if not isinstance(b, list): b = []
print(json.dumps(a + b))
")

COUNT=$(echo "$ROWS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
if [[ "$COUNT" == "0" ]]; then
  echo "No approved emails."
  exit 0
fi

export ROWS
python3 - <<'PY'
import json, os, subprocess, datetime

SUPABASE_URL=os.environ['SUPABASE_URL']
ANON_KEY=os.environ['API_KEY']
ACCOUNT=os.environ['ACCOUNT']
CC=os.environ['CC']

rows=json.loads(os.environ['ROWS'])

def patch(email_id, payload):
    subprocess.run([
        'curl','-s','-X','PATCH',f"{SUPABASE_URL}/rest/v1/email_queue?id=eq.{email_id}",
        '-H','Content-Type: application/json',
        '-H',f"apikey: {ANON_KEY}",
        '-H',f"Authorization: Bearer {ANON_KEY}",
        '-d',json.dumps(payload)
    ], check=False, stdout=subprocess.DEVNULL)

for r in rows:
    email_id=r.get('id')
    to=r.get('from_email') or ''
    subj=(r.get('subject') or '').strip()
    analysis=r.get('analysis') or {}
    if isinstance(analysis, str):
        try:
            analysis=json.loads(analysis)
        except Exception:
            analysis={}

    body=(analysis.get('draft_body') or analysis.get('draft_response') or '').strip()
    draft_subject=(analysis.get('draft_subject') or analysis.get('draft_title') or '').strip()
    if draft_subject:
        subj=draft_subject
    if subj and not subj.lower().startswith('re:'):
        subj='Re: ' + subj

    if not to or not body:
        patch(email_id, {'status':'error_send_failed','last_error':'missing to_email/from_email or draft body'})
        continue

    # Per-email CC override (set in analysis.cc) takes precedence over default CC
    email_cc = analysis.get('cc') or CC

    # Convert plain text to HTML — preserves paragraphs and avoids gog line-wrap mangling
    import html as _html
    def text_to_html(txt):
        paragraphs = txt.split('\n\n')
        html_parts = []
        for p in paragraphs:
            escaped = _html.escape(p).replace('\n', '<br>')
            html_parts.append(f'<p style="margin:0 0 12px 0">{escaped}</p>')
        return (
            '<div style="font-family:Arial,sans-serif;font-size:14px;line-height:1.6;color:#000">'
            + ''.join(html_parts) +
            '</div>'
        )
    body_html = text_to_html(body)

    # Thread ID for proper reply threading
    thread_id = r.get('gmail_thread_id') or ''

    # Mark as sending first (source-of-truth must reflect reality)
    patch(email_id, {
        'status':'sending',
        'last_error': None,
    })

    try:
        # Build send command
        cmd = [
            'gog','gmail','send',
            '--account',ACCOUNT,
            '--to',to,
            '--subject',subj,
            '--body-html',body_html,
            '--cc',email_cc,
        ]
        if thread_id:
            cmd += ['--thread-id', thread_id]

        # Send immediately and capture message_id
        out = subprocess.check_output(cmd, text=True)

        msg_id = None
        for line in out.splitlines():
            if line.lower().startswith('message_id'):
                # format: message_id\t<id>
                parts = line.split()  # handles tab
                if len(parts) >= 2:
                    msg_id = parts[-1].strip()

        if not msg_id:
            raise RuntimeError('Missing message_id from gog output')

        sent_ts = datetime.datetime.utcnow().replace(microsecond=0).isoformat()+'Z'

        # Store gmail message id inside analysis so we never claim 'sent' without proof
        try:
            analysis_out = dict(analysis)
        except Exception:
            analysis_out = {}
        analysis_out['gmail_message_id'] = msg_id

        patch(email_id, {
            'status':'sent',
            'sent_at': sent_ts,
            'last_error': None,
            'analysis': analysis_out,
        })

    except subprocess.CalledProcessError as e:
        patch(email_id, {
            'status':'error_send_failed',
            'last_error': f"send failed: exit {e.returncode}",
        })
    except Exception as e:
        patch(email_id, {
            'status':'error_send_failed',
            'last_error': f"send failed: {type(e).__name__}: {e}",
        })
PY
