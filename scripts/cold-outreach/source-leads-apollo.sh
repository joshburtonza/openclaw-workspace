#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# source-leads-apollo.sh
#
# Pulls qualified leads from Apollo.io, enriches with full profile data,
# and inserts into Supabase leads table for the Hunter waterfall + Alex outreach.
#
# Strategy:
#   1. Apollo api_search (FREE) — filter by ICP: title, location, employees
#   2. people/match per result (uses credits only when reveal_email=true)
#      — With reveal_email=false: gets full name, LinkedIn, org domain (FREE-ish)
#      — With reveal_email=true:  gets verified email (costs 1 export credit)
#   3. Dedup by apollo_id + email against existing leads table
#   4. Insert new leads → queued for enrich-leads.sh waterfall
#   5. Telegram summary
#
# Usage:
#   bash source-leads-apollo.sh                    → run all ICP segments, 25 each
#   bash source-leads-apollo.sh --segment za_sme   → specific segment only
#   bash source-leads-apollo.sh --reveal            → also reveal emails (costs credits)
#   bash source-leads-apollo.sh --limit 50          → max per segment
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
APOLLO_KEY="${APOLLO_API_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
LOG="$WS/out/source-leads-apollo.log"
mkdir -p "$WS/out"

ARG_SEGMENT="all"; ARG_REVEAL="false"; ARG_LIMIT=25
while [[ $# -gt 0 ]]; do
    case "$1" in
        --segment) ARG_SEGMENT="$2"; shift 2 ;;
        --reveal)  ARG_REVEAL="true"; shift ;;
        --limit)   ARG_LIMIT="$2";   shift 2 ;;
        *) shift ;;
    esac
done

export SUPABASE_URL KEY APOLLO_KEY BOT_TOKEN CHAT_ID LOG ARG_SEGMENT ARG_REVEAL ARG_LIMIT

python3 << 'PY'
import json, os, sys, re, urllib.request, urllib.parse, datetime, time, random

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['KEY']
APOLLO_KEY   = os.environ['APOLLO_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
LOG_PATH     = os.environ['LOG']
ARG_SEGMENT  = os.environ['ARG_SEGMENT']
ARG_REVEAL   = os.environ['ARG_REVEAL'] == 'true'
ARG_LIMIT    = int(os.environ['ARG_LIMIT'])

# ─────────────────────────────────────────────────────────────────────────────
# ICP Segments
# Each segment defines who we want and what we say they need.
# ─────────────────────────────────────────────────────────────────────────────
ICP_SEGMENTS = {

    # ── South Africa: SME owners in high-touch service sectors ───────────────
    'za_sme': {
        'label': 'ZA SME Founders & MDs',
        'region': 'South Africa',
        'params': {
            'person_titles': [
                'CEO', 'Managing Director', 'Founder', 'Owner', 'Director',
                'Co-Founder', 'General Manager',
            ],
            'person_locations': ['South Africa'],
            'organization_num_employees_ranges': ['11,50', '51,200'],
            'organization_not_tags': ['education', 'non-profit', 'government'],
            'per_page': 25,
        },
        'tags': ['south-africa', 'sme', 'founder'],
        'assigned_to': 'Alex',
    },

    # ── South Africa: Tech & Digital ──────────────────────────────────────────
    'za_tech': {
        'label': 'ZA Tech & SaaS Leaders',
        'region': 'South Africa',
        'params': {
            'person_titles': [
                'CEO', 'CTO', 'Founder', 'Managing Director', 'Head of Technology',
                'Director of Engineering', 'Co-Founder',
            ],
            'person_locations': ['South Africa'],
            'organization_industries': [
                'information technology and services',
                'computer software',
                'internet',
                'telecommunications',
            ],
            'organization_num_employees_ranges': ['6,200'],
            'per_page': 25,
        },
        'tags': ['south-africa', 'tech', 'saas'],
        'assigned_to': 'Alex',
    },

    # ── South Africa: Professional Services (law, accounting, consulting) ────
    'za_professional': {
        'label': 'ZA Professional Services',
        'region': 'South Africa',
        'params': {
            'person_titles': [
                'Managing Director', 'Partner', 'Director', 'Founder', 'CEO',
                'Head of Operations', 'Practice Manager',
            ],
            'person_locations': ['South Africa'],
            'organization_industries': [
                'accounting',
                'law practice',
                'management consulting',
                'financial services',
                'insurance',
                'marketing and advertising',
            ],
            'organization_num_employees_ranges': ['6,150'],
            'per_page': 25,
        },
        'tags': ['south-africa', 'professional-services'],
        'assigned_to': 'Alex',
    },

    # ── South Africa: Motor, Auto & Transport ────────────────────────────────
    'za_motor': {
        'label': 'ZA Motor & Automotive',
        'region': 'South Africa',
        'params': {
            'person_titles': [
                'Owner', 'Managing Director', 'CEO', 'Director', 'General Manager', 'Dealer Principal',
            ],
            'person_locations': ['South Africa'],
            'organization_industries': [
                'automotive',
                'transportation/trucking/railroad',
                'mechanical or industrial engineering',
            ],
            'organization_num_employees_ranges': ['6,500'],
            'per_page': 25,
        },
        'tags': ['south-africa', 'automotive'],
        'assigned_to': 'Alex',
    },

    # ── South Africa: Healthcare & Medical ───────────────────────────────────
    'za_health': {
        'label': 'ZA Healthcare & Medical',
        'region': 'South Africa',
        'params': {
            'person_titles': [
                'Practice Owner', 'Medical Director', 'CEO', 'Managing Director',
                'Operations Manager', 'Founder', 'Director',
            ],
            'person_locations': ['South Africa'],
            'organization_industries': [
                'hospital & health care',
                'health, wellness and fitness',
                'medical practice',
            ],
            'organization_num_employees_ranges': ['6,200'],
            'per_page': 25,
        },
        'tags': ['south-africa', 'healthcare'],
        'assigned_to': 'Alex',
    },

    # ── United Kingdom: Digital Agencies & Consultancies ─────────────────────
    'uk_digital': {
        'label': 'UK Digital Agencies & Consultancies',
        'region': 'United Kingdom',
        'params': {
            'person_titles': [
                'CEO', 'Founder', 'Managing Director', 'Co-Founder', 'Director',
                'Head of Operations', 'Operations Director',
            ],
            'person_locations': ['United Kingdom'],
            'organization_industries': [
                'marketing and advertising',
                'information technology and services',
                'management consulting',
                'internet',
                'computer software',
            ],
            'organization_num_employees_ranges': ['6,100'],
            'per_page': 25,
        },
        'tags': ['uk', 'digital', 'agency'],
        'assigned_to': 'Alex',
    },

    # ── Australia: SME Service Businesses ────────────────────────────────────
    'au_sme': {
        'label': 'AU SME Founders & Directors',
        'region': 'Australia',
        'params': {
            'person_titles': [
                'CEO', 'Founder', 'Managing Director', 'Director', 'Owner', 'Co-Founder',
            ],
            'person_locations': ['Australia'],
            'organization_num_employees_ranges': ['11,200'],
            'organization_not_tags': ['education', 'non-profit', 'government'],
            'per_page': 25,
        },
        'tags': ['australia', 'sme', 'founder'],
        'assigned_to': 'Alex',
    },

    # ── United States: SMB Operations & Ops Directors ─────────────────────────
    'us_ops': {
        'label': 'US SMB Ops & Founders',
        'region': 'United States',
        'params': {
            'person_titles': [
                'CEO', 'Founder', 'COO', 'Head of Operations', 'Operations Director',
                'VP Operations', 'Managing Director',
            ],
            'person_locations': ['United States'],
            'organization_industries': [
                'marketing and advertising',
                'information technology and services',
                'management consulting',
                'financial services',
                'professional training & coaching',
            ],
            'organization_num_employees_ranges': ['11,150'],
            'per_page': 25,
        },
        'tags': ['usa', 'ops', 'sme'],
        'assigned_to': 'Alex',
    },
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def log(msg):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    line = f'[{ts}] {msg}'
    print(line, flush=True)
    with open(LOG_PATH, 'a') as f:
        f.write(line + '\n')

def tg(text):
    payload = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        data=payload, headers={'Content-Type': 'application/json'}
    )
    try: urllib.request.urlopen(req, timeout=10)
    except Exception as e: log(f'tg error: {e}')

def supa_req(method, path, data=None, headers_extra=None):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    payload = json.dumps(data).encode() if data else None
    headers = {
        'apikey': KEY,
        'Authorization': f'Bearer {KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
    }
    if headers_extra:
        headers.update(headers_extra)
    req = urllib.request.Request(url, data=payload, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        log(f'  Supabase {method} {path[:60]} → {e.code}: {e.read()[:200]}')
        return None
    except Exception as e:
        log(f'  Supabase error: {e}')
        return None

def supa_get(path):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    req = urllib.request.Request(url, headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except Exception as e:
        log(f'  supa_get error ({path[:60]}): {e}')
        return []

APOLLO_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36'

def apollo_post(endpoint, payload, retries=2):
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f'https://api.apollo.io/v1/{endpoint}',
        data=body,
        headers={
            'X-Api-Key': APOLLO_KEY,
            'Content-Type': 'application/json',
            'User-Agent': APOLLO_UA,
            'Accept': 'application/json',
        }
    )
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=25) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            body_err = e.read()[:200]
            log(f'  Apollo {endpoint} HTTP {e.code}: {body_err}')
            if e.code == 429:
                time.sleep(3 * (attempt + 1))
            else:
                return None
        except Exception as e:
            log(f'  Apollo {endpoint} error: {e}')
            time.sleep(1)
    return None

# ─────────────────────────────────────────────────────────────────────────────
# Load existing Apollo IDs and emails to dedup
# ─────────────────────────────────────────────────────────────────────────────
def load_existing_ids():
    """Fetch all apollo_ids and emails already in Supabase leads."""
    log('Loading existing lead IDs for dedup...')
    # Load in pages to get all leads
    apollo_ids = set()
    emails = set()
    page_size = 1000
    offset = 0
    while True:
        batch = supa_get(f'leads?select=email,notes&limit={page_size}&offset={offset}')
        if not batch:
            break
        for l in batch:
            if l.get('email'):
                emails.add(l['email'].lower().strip())
            notes = l.get('notes') or ''
            m = re.search(r'Apollo ID: ([a-f0-9]+)', notes)
            if m:
                apollo_ids.add(m.group(1))
        if len(batch) < page_size:
            break
        offset += page_size
    log(f'  Existing: {len(emails)} emails, {len(apollo_ids)} Apollo IDs')
    return apollo_ids, emails

# ─────────────────────────────────────────────────────────────────────────────
# Apollo search + profile reveal
# ─────────────────────────────────────────────────────────────────────────────
def search_segment(seg_key, seg, limit, existing_apollo_ids, existing_emails):
    """Run Apollo search for a segment, reveal profiles, return lead dicts."""
    label  = seg['label']
    params = dict(seg['params'])
    tags   = seg.get('tags', [])
    assigned = seg.get('assigned_to', 'Alex')

    log(f'\n=== {label} (limit={limit}) ===')

    # Randomize page to avoid always getting the same top results
    max_page = 5
    start_page = random.randint(1, max_page)

    all_results = []
    for page in range(start_page, start_page + 3):
        params['page'] = page
        r = apollo_post('mixed_people/api_search', params)
        if not r:
            break
        people = r.get('people', [])
        total  = r.get('total_entries', 0)
        if page == start_page:
            log(f'  Total available: {total:,}  | Page {page}: {len(people)} results')
        all_results.extend(people)
        if len(all_results) >= limit * 2:
            break
        time.sleep(0.5)

    leads_to_insert = []
    credits_used = 0

    for raw in all_results:
        if len(leads_to_insert) >= limit:
            break

        apollo_id  = raw.get('id', '') or ''
        first_name = (raw.get('first_name') or '').strip()
        has_email  = raw.get('has_email', False)
        org_raw    = raw.get('organization', {}) or {}
        org_name   = (org_raw.get('name') or '').strip()

        if not first_name or not org_name:
            continue
        if apollo_id in existing_apollo_ids:
            continue

        # ── Reveal full profile via people/match (gets name, LinkedIn, domain) ─
        will_reveal = ARG_REVEAL and has_email and apollo_id not in existing_apollo_ids
        log(f'  Profiling: {first_name} @ {org_name}  (email={has_email}, reveal={will_reveal})')
        reveal_payload = {
            'id': apollo_id,
            'reveal_personal_emails': will_reveal,
        }
        match_r = apollo_post('people/match', reveal_payload)
        time.sleep(0.8)  # respect rate limits

        if not match_r:
            continue

        person = match_r.get('person', {}) or {}
        if not person:
            continue

        last_name  = (person.get('last_name') or '').strip()
        full_name  = (person.get('name') or '').strip() or f'{first_name} {last_name}'.strip()
        linkedin   = person.get('linkedin_url') or ''
        title      = person.get('title') or raw.get('title') or ''
        city       = person.get('city') or ''
        country    = person.get('country') or ''
        headline   = person.get('headline') or ''
        email_val  = person.get('email') or ''
        email_status = person.get('email_status') or ''

        # Org enrichment
        org = person.get('organization') or {}
        domain   = org.get('primary_domain') or ''
        industry = org.get('industry') or ''
        emp_count = org.get('num_employees') or org.get('estimated_num_employees')
        website  = f'https://{domain}' if domain and not domain.startswith('http') else domain

        if not last_name and not email_val and not linkedin:
            log(f'    → Skipped (no usable data)')
            continue

        if email_val and email_val.lower() in existing_emails:
            log(f'    → Duplicate email: {email_val}')
            existing_apollo_ids.add(apollo_id)
            continue

        if ARG_REVEAL and has_email:
            credits_used += 1

        # Build notes block
        notes_parts = []
        if city or country:
            notes_parts.append(f'Location: {", ".join(filter(None, [city, country]))}')
        if industry:
            notes_parts.append(f'Industry: {industry}')
        if emp_count:
            notes_parts.append(f'Employees: {emp_count}')
        if headline:
            notes_parts.append(f'Headline: {headline[:200]}')
        if linkedin:
            notes_parts.append(f'LinkedIn: {linkedin}')
        notes_parts.append(f'Apollo ID: {apollo_id}')
        notes_parts.append(f'Segment: {seg_key}')

        lead = {
            'first_name':   first_name,
            'last_name':    last_name,
            'email':        email_val if email_val else None,
            'company':      org_name,
            'website':      website if website else None,
            'source':       'apollo',
            'status':       'new',
            'assigned_to':  assigned,
            'tags':         tags + ([industry] if industry and industry not in tags else []),
            'notes':        '\n'.join(notes_parts),
            'email_status': 'valid' if email_status == 'verified' else (None if not email_val else 'unverified'),
        }

        # Remove None values to avoid Supabase type errors
        lead = {k: v for k, v in lead.items() if v is not None}

        leads_to_insert.append(lead)
        existing_apollo_ids.add(apollo_id)
        if email_val:
            existing_emails.add(email_val.lower())

        log(f'    + {full_name} | {title} | {domain or "no domain"} | email={"YES" if email_val else "no"}')

    log(f'  Segment complete: {len(leads_to_insert)} new leads (credits used: {credits_used})')
    return leads_to_insert, credits_used

# ─────────────────────────────────────────────────────────────────────────────
# Insert leads to Supabase
# ─────────────────────────────────────────────────────────────────────────────
def insert_leads(leads):
    if not leads:
        return 0
    # Normalise all leads to have identical keys (Supabase batch requirement)
    all_keys = set()
    for l in leads: all_keys.update(l.keys())
    for l in leads:
        for k in all_keys:
            l.setdefault(k, None)
    # Batch insert 10 at a time
    inserted = 0
    for i in range(0, len(leads), 10):
        batch = leads[i:i+10]
        url = f"{SUPABASE_URL}/rest/v1/leads"
        payload = json.dumps(batch).encode()
        req = urllib.request.Request(
            url, data=payload, method='POST',
            headers={
                'apikey': KEY,
                'Authorization': f'Bearer {KEY}',
                'Content-Type': 'application/json',
                'Prefer': 'return=minimal,resolution=ignore-duplicates',
            }
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                inserted += len(batch)
        except urllib.error.HTTPError as e:
            log(f'  Insert error: {e.code} {e.read()[:200]}')
        except Exception as e:
            log(f'  Insert error: {e}')
        time.sleep(0.3)
    return inserted

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
log(f'=== Apollo Lead Sourcer ===  segment={ARG_SEGMENT}  reveal={ARG_REVEAL}  limit={ARG_LIMIT}')

if ARG_SEGMENT == 'all':
    segments_to_run = list(ICP_SEGMENTS.keys())
else:
    segments_to_run = [ARG_SEGMENT] if ARG_SEGMENT in ICP_SEGMENTS else list(ICP_SEGMENTS.keys())

existing_apollo_ids, existing_emails = load_existing_ids()

total_inserted = 0
total_credits  = 0
segment_summary = []

for seg_key in segments_to_run:
    seg = ICP_SEGMENTS[seg_key]
    try:
        new_leads, credits = search_segment(
            seg_key, seg, ARG_LIMIT,
            existing_apollo_ids, existing_emails
        )
        n = insert_leads(new_leads)
        total_inserted += n
        total_credits  += credits
        segment_summary.append(f'  {seg["label"]}: +{n}')
        log(f'  Inserted {n} leads for {seg["label"]}')
    except Exception as e:
        log(f'Error in segment {seg_key}: {e}')
        import traceback; traceback.print_exc()
    time.sleep(1)

summary = (
    f'🎯 <b>Apollo Lead Sourcing Complete</b>\n\n'
    f'<b>New leads added: {total_inserted}</b>\n'
    + '\n'.join(segment_summary) +
    f'\n\nCredits used (email reveals): {total_credits}'
    f'\nThese leads are queued for Hunter waterfall enrichment.'
)

log(summary.replace('<b>', '').replace('</b>', ''))
tg(summary)
print(f'\n✅ Done — {total_inserted} leads inserted')
PY
