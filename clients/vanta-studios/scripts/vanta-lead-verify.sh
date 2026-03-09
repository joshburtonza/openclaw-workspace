#!/usr/bin/env bash
# Kill switch check — bail early if Vanta OS is paused
_KS=$(curl -s \
  "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/kill_switch?id=eq.d2a6eb7c-014c-43e6-9a5e-e0d5876c21cc&select=status" \
  -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['status'] if d else 'running')" 2>/dev/null)
if [[ "$_KS" == "stopped" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Vanta OS kill switch active — skipping run"
  exit 0
fi

# vanta-lead-verify.sh
# Quality-scores all unverified Vanta leads.
# Checks: email deliverability (MX + SMTP probe), Instagram activity, website liveness.
# Only leads scoring >= 50 proceed to outreach queue.
# Runs daily at 10:00 SAST via LaunchAgent (after discovery at 09:00).

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$ROOT/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
LOG="$ROOT/out/vanta-lead-verify.log"

# Max leads to verify per run (to control API costs + time)
MAX_PER_RUN="${VANTA_VERIFY_BATCH:-50}"

mkdir -p "$ROOT/out"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === vanta-lead-verify starting ===" | tee -a "$LOG"

export SUPABASE_URL SERVICE_KEY BOT_TOKEN CHAT_ID MAX_PER_RUN

python3 - <<'PY'
import os, json, sys, re, time, datetime, socket, smtplib, urllib.request, urllib.parse
import dns.resolver  # dnspython — install via: pip3 install dnspython

SUPABASE_URL = os.environ['SUPABASE_URL']
VANTA_CLIENT_ID = 'd2a6eb7c-014c-43e6-9a5e-e0d5876c21cc'
SERVICE_KEY  = os.environ['SERVICE_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
MAX_PER_RUN  = int(os.environ.get('MAX_PER_RUN', '50'))

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

def supa_patch(table, row_id, body):
    url = f"{SUPABASE_URL}/rest/v1/{table}?id=eq.{row_id}"
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method='PATCH', headers={
        'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json', 'Prefer': 'return=minimal',
    })
    try:
        with urllib.request.urlopen(req, timeout=15):
            return True
    except Exception as e:
        print(f'[verify] PATCH failed: {e}', file=sys.stderr)
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

# ── Verification functions ────────────────────────────────────────────────────

PERSONAL_DOMAINS = {
    'gmail.com', 'yahoo.com', 'hotmail.com', 'outlook.com', 'icloud.com',
    'live.com', 'me.com', 'mail.com', 'protonmail.com', 'web.de',
}

def classify_email_domain(email):
    if not email:
        return 'none'
    domain = email.split('@')[-1].lower()
    return 'personal' if domain in PERSONAL_DOMAINS else 'business'

def verify_email_mx(email):
    """Check if email domain has valid MX records."""
    if not email or '@' not in email:
        return False
    domain = email.split('@')[-1]
    try:
        answers = dns.resolver.resolve(domain, 'MX')
        return len(answers) > 0
    except Exception:
        return False

def smtp_probe_email(email, timeout=5):
    """
    Attempt SMTP VRFY/RCPT check without sending.
    Returns: 'valid' | 'invalid' | 'unknown' (many servers block this)
    """
    if not email or '@' not in email:
        return 'unknown'
    domain = email.split('@')[-1]
    try:
        # Get MX record
        answers = dns.resolver.resolve(domain, 'MX')
        mx_host = str(min(answers, key=lambda r: r.preference).exchange).rstrip('.')
        # Connect and check
        with smtplib.SMTP(timeout=timeout) as smtp:
            smtp.connect(mx_host, 25)
            smtp.helo('amalfiai.com')
            smtp.mail('verify@amalfiai.com')
            code, _ = smtp.rcpt(email)
            return 'valid' if code == 250 else ('invalid' if code == 550 else 'unknown')
    except Exception:
        return 'unknown'  # Many servers block SMTP probing — treat as unknown, not invalid

def check_website_live(url):
    """Check if website returns 200."""
    if not url:
        return False
    if not url.startswith('http'):
        url = 'https://' + url
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status < 400
    except Exception:
        # Try http fallback
        try:
            http_url = url.replace('https://', 'http://')
            req = urllib.request.Request(http_url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=8) as r:
                return r.status < 400
        except Exception:
            return False

def check_ig_active(last_post_at):
    """Is last post within 30 days?"""
    if not last_post_at:
        return False
    try:
        ts = datetime.datetime.fromisoformat(last_post_at.replace('Z', '+00:00'))
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=30)
        return ts > cutoff
    except Exception:
        return False

def calculate_quality_score(lead, email_mx_ok, email_deliverable, website_live, ig_active):
    """
    Score 0-100. Only outreach leads >= 50.
    """
    score = 0
    breakdown = {}

    # Email verified (MX check) — most important factor
    if email_mx_ok and lead.get('email'):
        score += 30
        breakdown['email_mx'] = 30
    elif lead.get('email'):
        # Email found but MX failed — probably dead domain
        score -= 5
        breakdown['email_mx'] = -5

    # Email deliverability (SMTP probe — if we got a definitive result)
    if email_deliverable == 'valid':
        score += 5
        breakdown['email_smtp'] = 5
    elif email_deliverable == 'invalid':
        score -= 20
        breakdown['email_smtp'] = -20

    # Instagram active
    if ig_active:
        score += 20
        breakdown['ig_active'] = 20

    # Business email (not gmail/yahoo)
    domain_type = classify_email_domain(lead.get('email'))
    if domain_type == 'business':
        score += 15
        breakdown['business_email'] = 15

    # SA location confirmed
    if lead.get('in_south_africa'):
        score += 10
        breakdown['sa_location'] = 10

    # Website live
    if website_live:
        score += 10
        breakdown['website_live'] = 10

    # Follower count (sweet spot: 500-50k)
    fc = lead.get('follower_count') or 0
    if 500 <= fc <= 50000:
        score += 10
        breakdown['follower_count'] = 10
    elif fc > 50000:
        # Big account — harder to convert, outreach less personal
        score += 3
        breakdown['follower_count'] = 3

    # Engagement rate > 3%
    er = lead.get('engagement_rate') or 0
    if er >= 3:
        score += 5
        breakdown['engagement'] = 5

    return max(0, min(100, score)), breakdown

# ── Main verify loop ──────────────────────────────────────────────────────────

# Fetch unverified leads (quality_scored_at is null, status='new')
try:
    leads = supa_get('leads', {
        'client_id': f'eq.{VANTA_CLIENT_ID}',
        'quality_score': 'eq.0',
        'status': 'eq.new',
        'order': 'created_at.asc',
        'limit': str(MAX_PER_RUN),
        'select': 'id,twitter_url,first_name,last_name,email,website,company_description,notes,headline,location_city,location_country,industry',
    })
except Exception as e:
    print(f'[verify] Could not fetch leads: {e}', file=sys.stderr)
    sys.exit(0)

print(f'[verify] Processing {len(leads)} leads...')

verified = 0
qualified = 0   # score >= 50
rejected  = 0   # score < 30 — immediately mark rejected

for lead in leads:
    lid   = lead['id']
    email = lead.get('email')
    url   = lead.get('website')
    lp    = lead.get('last_contacted_at')  # used as proxy for IG last post

    # Email checks
    email_mx_ok      = verify_email_mx(email) if email else False
    email_deliverable = 'unknown'
    if email_mx_ok:
        time.sleep(0.5)
        email_deliverable = smtp_probe_email(email)

    # Website check
    website_live = check_website_live(url) if url else False

    # Instagram activity
    ig_active = check_ig_active(lp)

    # Score
    score, breakdown = calculate_quality_score(
        lead, email_mx_ok, email_deliverable, website_live, ig_active
    )

    # Determine new status
    if score >= 50:
        new_status = 'queued'   # ready for outreach
        qualified += 1
    elif score < 25:
        new_status = 'rejected'  # not worth contacting
        rejected += 1
    else:
        new_status = 'new'       # borderline — keep but don't outreach yet

    now = datetime.datetime.utcnow().isoformat() + 'Z'

    # Store verification details in ai_analysis jsonb
    verification_data = {
        'email_mx_ok': email_mx_ok,
        'email_deliverable': email_deliverable,
        'website_live': website_live,
        'ig_active': ig_active,
        'score_breakdown': breakdown,
    }
    supa_patch('leads', lid, {
        'quality_score': score,
        'ai_score':      score,
        'ai_analysis':   verification_data,
        'status':        new_status,
        'updated_at':    now,
    })

    handle = (lead.get('twitter_url') or '').rstrip('/').split('/')[-1] or lead.get('company','unknown')
    print(f'[verify] {handle}: score={score} status={new_status} (email_mx={email_mx_ok}, ig_active={ig_active}, website={website_live})')
    verified += 1
    time.sleep(0.3)

print(f'[verify] Done. {verified} verified, {qualified} qualified for outreach, {rejected} rejected.')

if BOT_TOKEN and CHAT_ID and verified > 0:
    tg_send(
        f'✅ <b>Vanta Lead Verification</b>\n'
        f'{verified} leads scored.\n'
        f'<b>{qualified}</b> qualified (score ≥50) — ready for outreach.\n'
        f'{rejected} rejected (low quality).'
    )
PY

echo "[$(date '+%Y-%m-%d %H:%M:%S')] vanta-lead-verify complete" | tee -a "$LOG"
