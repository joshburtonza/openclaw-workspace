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
import json, os, subprocess, datetime, requests

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
    if isinstance(r, str):
        try:
            r = json.loads(r)
        except Exception:
            continue
    if not isinstance(r, dict):
        continue
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

        # ── Post-send: update client sentiment + notes ────────────────────────
        client_slug = analysis_out.get('client_slug') or analysis.get('client_slug') or ''
        sentiment   = analysis_out.get('sentiment') or analysis.get('sentiment') or ''
        if client_slug and client_slug not in ('unknown', 'new_contact', ''):
            try:
                # Build a brief dated note entry
                import datetime as _dt
                today = _dt.datetime.utcnow().strftime('%Y-%m-%d')
                note_entry = f"[{today}] Email sent: {subj}"

                # Fetch existing notes first
                notes_resp = requests.get(
                    f"{SUPABASE_URL}/rest/v1/clients?slug=eq.{client_slug}&select=notes,sentiment",
                    headers={'apikey': ANON_KEY, 'Authorization': f'Bearer {ANON_KEY}'},
                    timeout=10
                )
                existing = notes_resp.json()[0] if notes_resp.status_code == 200 and notes_resp.json() else {}
                old_notes = existing.get('notes') or ''

                # Prepend new entry, keep under 1000 chars
                combined = (note_entry + '\n' + old_notes).strip()[:1000]

                update_payload = {'notes': combined, 'updated_at': sent_ts}
                if sentiment in ('positive', 'neutral', 'at_risk'):
                    update_payload['sentiment'] = sentiment

                requests.patch(
                    f"{SUPABASE_URL}/rest/v1/clients?slug=eq.{client_slug}",
                    headers={'apikey': ANON_KEY, 'Authorization': f'Bearer {ANON_KEY}',
                             'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                    json=update_payload, timeout=10
                )
            except Exception:
                pass  # non-fatal — email is already sent

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

# ── Retainer conversion check (runs once per day) ─────────────────────────────
WS="/Users/henryburton/.openclaw/workspace-anthropic"
GATE_FILE="$WS/tmp/retainer-pitch-checked-$(date '+%Y-%m-%d').flag"
mkdir -p "$WS/tmp"

if [[ -f "$GATE_FILE" ]]; then
  echo "Retainer conversion check already ran today — skipping."
  exit 0
fi

touch "$GATE_FILE"
# Clean up gate files older than 2 days to avoid accumulation
find "$WS/tmp" -name "retainer-pitch-checked-*.flag" -mtime +2 -delete 2>/dev/null || true

CLIENT_PROJECTS_FILE="$WS/data/client-projects.json"
if [[ ! -f "$CLIENT_PROJECTS_FILE" ]]; then
  echo "No client-projects.json found — skipping retainer check."
  exit 0
fi

export SUPABASE_URL API_KEY CLIENT_PROJECTS_FILE WS
export BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"

python3 - <<'RETAINER_PY'
import json, os, requests, datetime, subprocess, sys

URL     = os.environ['SUPABASE_URL']
KEY     = os.environ['API_KEY']
BOT     = os.environ.get('BOT_TOKEN', '')
CHAT    = os.environ.get('CHAT_ID', '')
WS      = os.environ['WS']
DATA_FILE = os.environ['CLIENT_PROJECTS_FILE']

def supa_get(path):
    r = requests.get(f"{URL}/rest/v1/{path}",
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'},
        timeout=15)
    r.raise_for_status()
    return r.json()

def supa_post(path, body, prefer='return=representation'):
    r = requests.post(f"{URL}/rest/v1/{path}",
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                 'Content-Type': 'application/json', 'Prefer': prefer},
        json=body, timeout=15)
    r.raise_for_status()
    return r.json() if prefer != 'return=minimal' else None

def tg(text):
    if not BOT or not CHAT:
        return
    try:
        requests.post(
            f"https://api.telegram.org/bot{BOT}/sendMessage",
            json={'chat_id': CHAT, 'text': text, 'parse_mode': 'HTML'},
            timeout=10)
    except Exception:
        pass

today = datetime.date.today()
data = json.loads(open(DATA_FILE).read())
clients = data.get('clients', [])

candidates = []
for c in clients:
    if c.get('retainer_status') != 'project_only':
        continue
    # Never pitch retainer conversion to bd_partner contacts — peer relationship, not vendor/client
    if c.get('relationship_type') == 'bd_partner':
        print(f"  {c['slug']}: bd_partner — skipping retainer pitch")
        continue
    start_str = c.get('project_start_date')
    if not start_str:
        print(f"  {c['slug']}: project_only but no project_start_date — skipping")
        continue
    try:
        start = datetime.date.fromisoformat(start_str)
    except ValueError:
        print(f"  {c['slug']}: invalid project_start_date '{start_str}' — skipping")
        continue
    days_since = (today - start).days
    print(f"  {c['slug']}: {days_since} days since project start (status={c['retainer_status']})")
    if days_since >= 60:
        candidates.append({**c, 'days_since_start': days_since})

if not candidates:
    print("Retainer check: no project_only clients at 60+ days.")
    sys.exit(0)

print(f"Retainer check: {len(candidates)} candidate(s) for conversion pitch.")

for client in candidates:
    slug = client['slug']
    name = client['name']
    email = client.get('email', '')
    project_type = client.get('project_type', 'the project')
    days = client['days_since_start']

    if not email:
        print(f"  {slug}: no email on file — skipping")
        tg(f"⚠️ <b>Retainer pitch: {name}</b>\nNo email on file. {days} days in, no retainer. Add email to data/client-projects.json.")
        continue

    # Dedup: skip if a retainer_pitch email already exists in the queue
    # (awaiting_approval, approved, sending, or sent in the last 30 days)
    try:
        cutoff = (today - datetime.timedelta(days=30)).isoformat() + 'T00:00:00Z'
        existing = supa_get(
            f"email_queue?client=eq.{slug}"
            f"&created_at=gte.{cutoff}"
            f"&select=id,status,analysis"
        )
        already_queued = False
        for row in (existing or []):
            analysis = row.get('analysis') or {}
            if isinstance(analysis, str):
                try:
                    analysis = json.loads(analysis)
                except Exception:
                    analysis = {}
            if analysis.get('intent') == 'retainer_pitch':
                status = row.get('status', '')
                if status not in ('rejected', 'skipped', 'error_send_failed'):
                    already_queued = True
                    print(f"  {slug}: retainer pitch already queued (status={status}) — skipping")
                    break
        if already_queued:
            continue
    except Exception as e:
        print(f"  {slug}: dedup check failed ({e}) — proceeding cautiously, skipping")
        continue

    # Build the loss-aversion email body
    weeks = round(days / 7)
    subject = f"Before {project_type.split('(')[0].strip()} wraps — what stays vs. what stops"

    body = (
        f"Hi — just a note worth reading before the project phase closes.\n\n"
        f"{project_type} has been running for {weeks} weeks. "
        f"Here is what is currently live for your team:\n\n"
        f"- The core automations built during the project\n"
        f"- Any integrations and data flows we set up\n"
        f"- The logic that replaces manual steps in your workflow\n\n"
        f"Here is what stops when the project engagement ends and there is no ongoing support:\n\n"
        f"- The automations need maintenance — without it, edge cases accumulate and the system drifts\n"
        f"- Integrations break when vendors update their APIs (this is not a matter of if, but when)\n"
        f"- Any new requirements that come up have no one to implement them\n"
        f"- The institutional knowledge built during the project walks out the door\n\n"
        f"A monthly retainer means we stay in the system — monitoring, fixing, and handling the "
        f"inevitable edge cases before they become your problem. The system keeps running the way "
        f"it does now.\n\n"
        f"Worth a 30-minute call to talk through what that would look like? "
        f"Reply here and I will get something in the diary.\n\n"
        f"Warm regards\nSophia\nAmalfi AI"
    )

    analysis_payload = {
        'intent': 'retainer_pitch',
        'client_slug': slug,
        'sentiment': 'neutral',
        'escalation_reason': '60-day project-to-retainer conversion check',
        'days_since_start': days,
        'project_type': project_type,
        'auto_generated': True,
        'draft_subject': subject,
        'draft_body': body,
    }

    try:
        supa_post('email_queue', {
            'from_email': 'sophia@amalfiai.com',
            'to_email': email,
            'subject': subject,
            'body': body,
            'client': slug,
            'status': 'awaiting_approval',
            'requires_approval': True,
            'priority': 7,
            'analysis': analysis_payload,
        })
        print(f"  {slug}: retainer pitch queued for approval")

        tg(
            f"🔁 <b>Retainer pitch: {name}</b>\n"
            f"Project has been running for {days} days with no retainer conversion.\n\n"
            f"Loss-aversion draft queued in Mission Control → Approvals.\n"
            f"Approve to send the pitch to <code>{email}</code>.\n\n"
            f"<i>Framing: what breaks when the project ends — not upsell language.</i>"
        )
    except Exception as e:
        print(f"  {slug}: failed to queue retainer pitch — {e}")

print("Retainer conversion check complete.")
RETAINER_PY
