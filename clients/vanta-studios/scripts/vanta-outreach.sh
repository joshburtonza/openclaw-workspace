#!/usr/bin/env bash
# Kill switch check — bail early if Vanta OS is paused
_KS=$(curl -s \
  "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/kill_switch?id=eq.d2a6eb7c-014c-43e6-9a5e-e0d5876c21cc&select=status" \
  -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['status'] if d else 'running')" 2>/dev/null)
if [[ "$_KS" == "stopped" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Vanta OS kill switch active — skipping run"
  exit 0
fi

# vanta-outreach.sh
# Queues personalized Sophia emails to quality-verified Vanta leads (score >= 50).
# Uses Claude to generate a bespoke intro for each photographer based on their
# niche, bio, and location. Batches into email_queue for Sophia to send.
# Runs daily at 11:00 SAST via LaunchAgent (after verify at 10:00).
# CAP: max 10 outreach emails per day to maintain quality + avoid spam filters.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$ROOT/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
LOG="$ROOT/out/vanta-outreach.log"

# Max outreach emails per day — KEEP THIS LOW for quality
DAILY_CAP="${VANTA_DAILY_OUTREACH_CAP:-10}"

mkdir -p "$ROOT/out"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === vanta-outreach starting ===" | tee -a "$LOG"

export SUPABASE_URL SERVICE_KEY BOT_TOKEN CHAT_ID OPENAI_API_KEY DAILY_CAP

python3 - <<'PY'
import os, json, sys, re, datetime, urllib.request, urllib.parse

SUPABASE_URL    = os.environ['SUPABASE_URL']
SERVICE_KEY     = os.environ['SERVICE_KEY']
BOT_TOKEN       = os.environ['BOT_TOKEN']
CHAT_ID         = os.environ['CHAT_ID']
OPENAI_KEY      = os.environ.get('OPENAI_API_KEY', '')
DAILY_CAP       = int(os.environ.get('DAILY_CAP', '10'))

# ── Supabase helpers ──────────────────────────────────────────────────────────

def supa_get(path, params=None):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    if params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}', 'Accept': 'application/json',
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

def supa_post(table, row):
    url = f"{SUPABASE_URL}/rest/v1/{table}"
    data = json.dumps(row).encode()
    req = urllib.request.Request(url, data=data, method='POST', headers={
        'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json', 'Prefer': 'return=representation',
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            rows = json.loads(r.read())
            return rows[0] if rows else None
    except Exception as e:
        print(f'[outreach] DB insert error: {e}', file=sys.stderr)
        return None

def supa_patch(table, row_id, body):
    url = f"{SUPABASE_URL}/rest/v1/{table}?id=eq.{row_id}"
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method='PATCH', headers={
        'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json', 'Prefer': 'return=minimal',
    })
    try:
        with urllib.request.urlopen(req, timeout=15): return True
    except Exception as e:
        print(f'[outreach] PATCH failed: {e}', file=sys.stderr)
        return False

def tg_send(text):
    data = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        data=data, headers={'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(req, timeout=10): pass
    except Exception: pass

# ── Count today's outreach ────────────────────────────────────────────────────

today_start = datetime.datetime.utcnow().strftime('%Y-%m-%dT00:00:00Z')
try:
    sent_today = supa_get('leads', {
        'client_id': f'eq.{VANTA_CLIENT_ID}',
        'status': 'eq.sent',
        'last_contacted_at': f'gte.{today_start}',
        'select': 'id',
    })
    already_sent = len(sent_today)
except Exception:
    already_sent = 0

remaining_cap = DAILY_CAP - already_sent
if remaining_cap <= 0:
    print(f'[outreach] Daily cap of {DAILY_CAP} reached ({already_sent} sent today). Skipping.')
    sys.exit(0)

print(f'[outreach] {already_sent} sent today, cap={DAILY_CAP}, sending up to {remaining_cap} more.')

# ── Fetch queued leads ────────────────────────────────────────────────────────

try:
    leads = supa_get('leads', {
        'client_id': f'eq.{VANTA_CLIENT_ID}',
        'status': 'eq.queued',
        'order': 'quality_score.desc',
        'limit': str(remaining_cap),
        'select': 'id,twitter_url,first_name,last_name,company,email,website,location_city,industry,headline,company_description,quality_score,ai_analysis',
    })
except Exception as e:
    print(f'[outreach] Could not fetch leads: {e}', file=sys.stderr)
    sys.exit(0)

if not leads:
    print('[outreach] No leads in queue.')
    sys.exit(0)

print(f'[outreach] {len(leads)} leads to process.')

# ── Claude email generation ───────────────────────────────────────────────────

def generate_email(lead):
    """Use Claude Haiku to generate a personalized outreach email."""
    handle   = (lead.get('twitter_url') or '').rstrip('/').split('/')[-1] or lead.get('company','')
    name     = ' '.join(filter(None, [lead.get('first_name'), lead.get('last_name')])) or handle
    city     = lead.get('location_city') or 'South Africa'
    specs    = [s.strip() for s in (lead.get('industry') or 'photography').split(',')]
    bio      = (lead.get('headline') or '')[:200]
    website  = lead.get('website') or ''

    spec_str = ', '.join(specs) if specs else 'photography'

    prompt = f"""Write a short, warm, professional outreach email FROM Vanta Studios TO a {spec_str} photographer based in {city}, South Africa.

Photographer details:
- Name/handle: {name} (@{handle})
- Specialties: {spec_str}
- Bio snippet: {bio}
- Website: {website}

Vanta Studios is a professional photography studio in South Africa offering:
- Studio hire (natural light + strobe setups)
- Collaboration opportunities
- Equipment rental
- Creative space for editorial and commercial shoots

Requirements:
- Subject line: specific to their niche, not generic
- Body: 3-4 short paragraphs max
- Warm peer-to-peer tone — creative professional to creative professional
- ONE specific reference to their actual work or style (from bio/specialties)
- CTA: invite them to reply to explore studio hire or collaboration, not a hard sell
- Signed: "The Vanta Team"
- NO hyphens anywhere in the email
- Output ONLY: Subject: [line]\\n\\n[email body]. Nothing else."""

    data = json.dumps({
        'model': 'gpt-4o',
        'messages': [{'role': 'user', 'content': prompt}],
        'max_tokens': 400,
    }).encode()

    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=data,
        headers={
            'Authorization': f'Bearer {OPENAI_KEY}',
            'Content-Type': 'application/json',
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            resp = json.loads(r.read())
        return resp['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f'[outreach] Claude generation failed: {e}', file=sys.stderr)
        return None

# ── Queue emails ──────────────────────────────────────────────────────────────

queued = 0
names_sent = []

for lead in leads:
    if not lead.get('email'):
        print(f'[outreach] Skip {lead.get("instagram_handle")} — no email')
        continue

    email_content = generate_email(lead)
    if not email_content:
        continue

    # Parse subject + body from Claude output
    lines = email_content.strip().split('\n')
    subject = ''
    body_lines = []
    for i, line in enumerate(lines):
        if line.startswith('Subject:'):
            subject = line[8:].strip()
        elif subject and line.strip():
            body_lines = lines[i:]
            break

    if not subject:
        subject = f'Studio collaboration — {lead.get("full_name") or lead.get("instagram_handle", "")}'

    body_html = '<br>'.join(l if l.strip() else '<br>' for l in body_lines)

    # Insert into email_queue for Sophia
    name = lead.get('full_name') or lead.get('instagram_handle') or 'Photographer'
    eq_row = supa_post('email_queue', {
        'client': 'vanta_studios',
        'to_email': lead['email'],
        'to_name': name,
        'from_account': 'sophia@amalfiai.com',
        'subject': subject,
        'body_html': body_html,
        'status': 'awaiting_approval',   # Josh approves before sending
        'analysis': json.dumps({
            'ig_handle': (lead.get('twitter_url') or '').rstrip('/').split('/')[-1],
            'quality_score': lead.get('quality_score'),
            'city': lead.get('location_city'),
            'specialties': lead.get('industry'),
        }),
        'created_at': datetime.datetime.utcnow().isoformat() + 'Z',
    })

    eq_id = eq_row['id'] if eq_row and isinstance(eq_row, dict) else None
    now = datetime.datetime.utcnow().isoformat() + 'Z'

    supa_patch('leads', lead['id'], {
        'status': 'awaiting_approval',
        'notes': json.dumps({'email_queue_id': eq_id, 'ig_handle': (lead.get('twitter_url') or '').rstrip('/').split('/')[-1]}),
        'updated_at': now,
    })

    handle = (lead.get('twitter_url') or '').rstrip('/').split('/')[-1] or 'unknown'
    print(f'[outreach] Queued email for {handle} ({lead["email"]}) — "{subject}"')
    queued += 1
    names_sent.append(f'{name} (@{handle})')

print(f'[outreach] Done. {queued} emails queued for approval.')

if BOT_TOKEN and CHAT_ID and queued > 0:
    names_list = '\n'.join(f'  • {n}' for n in names_sent[:10])
    tg_send(
        f'📧 <b>Vanta Outreach Queued</b>\n'
        f'{queued} email(s) ready for your approval in Mission Control:\n\n'
        f'{names_list}\n\n'
        f'Approve in Mission Control → Email Queue, or tap to review.'
    )
PY

echo "[$(date '+%Y-%m-%d %H:%M:%S')] vanta-outreach complete" | tee -a "$LOG"
