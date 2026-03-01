#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# enrich-leads.sh
# Waterfall lead enrichment: Apollo → Hunter.io → Apify
#
# For each lead with email_status=null or 'unverified':
#   1. Apollo  — people/match (finds verified email from name+domain)
#   2. Hunter  — email-finder (pattern-based + database lookup)
#   3. Apify   — website crawler (scrapes contact page for emails)
#   4. Pattern — generate permutations + pick most likely
#   5. Verify  — Hunter.io email verifier → update email_status
#
# Usage:
#   bash enrich-leads.sh              → process up to 20 pending leads
#   bash enrich-leads.sh --lead <id>  → enrich a specific lead by ID
#   bash enrich-leads.sh --email <e>  → verify a specific email
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
APOLLO_KEY="${APOLLO_API_KEY:-}"
HUNTER_KEY="${HUNTER_IO_API_KEY:-}"
APIFY_KEY="${APIFY_API_TOKEN:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"

LOG="$WS/out/enrich-leads.log"
mkdir -p "$WS/out"

ARG1="${1:-}"
ARG2="${2:-}"

export SUPABASE_URL KEY APOLLO_KEY HUNTER_KEY APIFY_KEY BOT_TOKEN CHAT_ID LOG WS ARG1 ARG2

python3 << 'PY'
import json, os, sys, re, urllib.request, urllib.parse, datetime, time

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['KEY']
APOLLO_KEY   = os.environ['APOLLO_KEY']
HUNTER_KEY   = os.environ['HUNTER_KEY']
APIFY_KEY    = os.environ['APIFY_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
LOG_PATH     = os.environ['LOG']
WS           = os.environ['WS']
ARG1         = os.environ.get('ARG1', '')
ARG2         = os.environ.get('ARG2', '')

# Apollo requires browser User-Agent — Python urllib default is blocked by Cloudflare (error 1010)
APOLLO_HEADERS = {
    'X-Api-Key':    APOLLO_KEY,
    'Content-Type': 'application/json',
    'Accept':       'application/json, text/plain, */*',
    'User-Agent':   'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
}

def log(msg):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    line = f'[{ts}] {msg}'
    print(line, flush=True)
    with open(LOG_PATH, 'a') as f: f.write(line + '\n')

def tg(text):
    payload = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        data=payload, headers={'Content-Type': 'application/json'}
    )
    try: urllib.request.urlopen(req, timeout=10)
    except Exception as e: log(f'tg failed: {e}')

def supa_get(path):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    req = urllib.request.Request(url, headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except Exception as e:
        log(f'supa_get failed ({path[:60]}): {e}')
        return []

def supa_patch(path, data):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    payload = json.dumps(data).encode()
    req = urllib.request.Request(url, data=payload, method='PATCH', headers={
        'apikey': KEY, 'Authorization': f'Bearer {KEY}',
        'Content-Type': 'application/json', 'Prefer': 'return=minimal'
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r: return r.status
    except Exception as e:
        log(f'supa_patch failed: {e}')
        return 0

def extract_domain(website, email=''):
    """Get clean domain from website URL or email."""
    if website:
        m = re.search(r'(?:https?://)?(?:www\.)?([^/\s]+)', website)
        if m:
            d = m.group(1).strip()
            if '.' in d: return d.lower()
    if email and '@' in email:
        d = email.split('@')[1].strip().lower()
        if d not in ('gmail.com', 'yahoo.com', 'hotmail.com', 'outlook.com'):
            return d
    return None

# ── Step 0: Apollo org enrichment ────────────────────────────────────────────
def apollo_org_enrich(domain):
    """Call Apollo /organizations/enrich — free, no credits. Returns dict of company intel."""
    if not APOLLO_KEY or not domain:
        return {}
    body = json.dumps({'domain': domain}).encode()
    req = urllib.request.Request(
        'https://api.apollo.io/v1/organizations/enrich',
        data=body,
        headers=APOLLO_HEADERS,
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.loads(r.read())
        org = d.get('organization') or {}
        if not org:
            return {}

        # Tech stack: list of tool names
        techs = [t.get('name') for t in (org.get('technologies') or []) if t.get('name')]

        # Keywords / specialties
        keywords = org.get('keywords') or []

        # Revenue: prefer printed label
        revenue = org.get('organization_revenue_printed') or org.get('annual_revenue_printed')

        result = {
            'company_description':  (org.get('short_description') or '')[:500] or None,
            'tech_stack':           techs if techs else None,
            'company_keywords':     keywords[:20] if keywords else None,
            'twitter_url':          org.get('twitter_url') or None,
            'company_linkedin_url': org.get('linkedin_url') or None,
            'annual_revenue':       revenue or None,
            'founded_year':         org.get('founded_year') or None,
            # Update employee count only if we have nothing yet
            'employee_count_org':   org.get('estimated_num_employees') or None,
            'industry_org':         org.get('industry') or None,
        }
        log(f'  Apollo org: description={bool(result["company_description"])}, '
            f'techs={len(techs)}, revenue={revenue}, twitter={bool(result["twitter_url"])}')
        return result
    except Exception as e:
        log(f'  Apollo org error: {e}')
        return {}

# ── Step 1: Apollo people/match ───────────────────────────────────────────────
def apollo_find_email(first_name, last_name, domain, company=''):
    """Try Apollo people/match to find email for a person."""
    if not APOLLO_KEY: return None, None
    payload = {
        'first_name': first_name,
        'last_name': last_name,
        'domain': domain,
        'reveal_personal_emails': True,
    }
    if company: payload['organization_name'] = company
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        'https://api.apollo.io/v1/people/match',
        data=body,
        headers=APOLLO_HEADERS,
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.loads(r.read())
        p = d.get('person', {}) or {}
        email = p.get('email')
        linkedin = p.get('linkedin_url')
        title = p.get('title', '')
        # Pull employment history — store most recent previous company
        eh = p.get('employment_history') or []
        prev_companies = [
            h.get('organization_name') for h in eh
            if h.get('organization_name') and h.get('current') is False
        ][:3]

        enrichment = {
            'linkedin':          linkedin,
            'title':             title,
            'apollo_id':         p.get('id'),
            'photo':             p.get('photo_url'),
            'seniority':         p.get('seniority') or None,
            'departments':       p.get('departments') or None,
            'headline':          p.get('headline') or None,
            'person_twitter':    p.get('twitter_url') or None,
            'phone_numbers':     [ph.get('sanitized_number') for ph in (p.get('phone_numbers') or []) if ph.get('sanitized_number')] or None,
            'show_intent':       p.get('show_intent') or None,
            'intent_strength':   p.get('intent_strength') or None,
            'prev_companies':    prev_companies or None,
        }
        if email:
            log(f'  Apollo found email: {email}')
            return email, enrichment
        # No email but got profile data
        if linkedin or title:
            log(f'  Apollo: no email, got profile (title={title})')
            return None, enrichment
        return None, None
    except Exception as e:
        log(f'  Apollo error: {e}')
        return None, None

# ── Step 2: Hunter.io email-finder ────────────────────────────────────────────
def hunter_find_email(first_name, last_name, domain):
    """Use Hunter.io email-finder (costs 1 search credit)."""
    if not HUNTER_KEY: return None
    params = urllib.parse.urlencode({
        'domain': domain,
        'first_name': first_name,
        'last_name': last_name,
        'api_key': HUNTER_KEY,
    })
    req = urllib.request.Request(f'https://api.hunter.io/v2/email-finder?{params}')
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read())
        data = d.get('data', {}) or {}
        email = data.get('email')
        score = data.get('score', 0)
        if email and score >= 50:
            log(f'  Hunter found email: {email} (score={score})')
            return email
        elif email:
            log(f'  Hunter found email but low confidence: {email} (score={score})')
            return email
        return None
    except Exception as e:
        log(f'  Hunter email-finder error: {e}')
        return None

def hunter_domain_pattern(domain):
    """Get the email pattern for a domain (free, no credits)."""
    if not HUNTER_KEY: return None
    params = urllib.parse.urlencode({'domain': domain, 'api_key': HUNTER_KEY, 'limit': 1})
    req = urllib.request.Request(f'https://api.hunter.io/v2/domain-search?{params}')
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            d = json.loads(r.read())
        return (d.get('data', {}) or {}).get('pattern')
    except Exception:
        return None

def hunter_verify(email):
    """Verify an email via Hunter.io. Returns (status, score)."""
    if not HUNTER_KEY: return 'unverified', 0
    params = urllib.parse.urlencode({'email': email, 'api_key': HUNTER_KEY})
    req = urllib.request.Request(f'https://api.hunter.io/v2/email-verifier?{params}')
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.loads(r.read())
        data = d.get('data', {}) or {}
        status = data.get('status', 'unverified')
        score  = data.get('score', 0)
        log(f'  Hunter verify {email}: {status} (score={score})')
        return status, score
    except Exception as e:
        log(f'  Hunter verify error: {e}')
        return 'unverified', 0

# ── Step 3: Pattern generation ────────────────────────────────────────────────
def generate_patterns(first, last, domain, hunter_pattern=None):
    """Generate likely email patterns given name + domain."""
    f = first.lower().strip()
    l = last.lower().strip() if last else ''
    fi = f[0] if f else ''
    li = l[0] if l else ''

    if hunter_pattern:
        # Use Hunter's known pattern for this domain
        p = hunter_pattern
        email = p.replace('{first}', f).replace('{last}', l).replace('{f}', fi).replace('{l}', li)
        if '@' not in email:
            email = f'{email}@{domain}'
        return [email]

    # Generate all common patterns ranked by frequency
    patterns = []
    if l:
        patterns = [
            f'{f}@{domain}',
            f'{f}.{l}@{domain}',
            f'{fi}{l}@{domain}',
            f'{f}{l}@{domain}',
            f'{f}_{l}@{domain}',
            f'{fi}.{l}@{domain}',
            f'{f}{li}@{domain}',
        ]
    else:
        patterns = [f'{f}@{domain}']
    return patterns

# ── Step 4: Apify website email scraper ───────────────────────────────────────
def apify_scrape_emails(domain):
    """Use Apify to crawl contact/about pages and extract email addresses."""
    if not APIFY_KEY: return []
    # Try contact and about pages
    start_urls = [
        {'url': f'https://{domain}/contact'},
        {'url': f'https://{domain}/contact-us'},
        {'url': f'https://{domain}/about'},
        {'url': f'https://www.{domain}/contact'},
    ]
    actor_input = {
        'startUrls': start_urls,
        'maxCrawlPages': 5,
        'maxCrawlDepth': 1,
        'pageFunction': '''
async function pageFunction(context) {
    const { request, $ } = context;
    const emails = [];
    const text = $("body").text();
    const emailRegex = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}/g;
    const found = text.match(emailRegex) || [];
    return { url: request.url, emails: [...new Set(found)] };
}
''',
    }
    body = json.dumps(actor_input).encode()
    # Use website-content-crawler actor for email extraction
    url = f'https://api.apify.com/v2/acts/apify~website-content-crawler/run-sync-get-dataset-items?token={APIFY_KEY}&timeout=60&memory=256'
    req = urllib.request.Request(url, data=body, headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            results = json.loads(r.read())
        emails = set()
        for page in (results or []):
            # Extract emails from page text using regex
            text = page.get('text', '') or ''
            found = re.findall(r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}', text)
            for e in found:
                # Only keep emails from this domain
                if e.split('@')[-1].lower().replace('www.','') in domain:
                    emails.add(e.lower())
        log(f'  Apify found {len(emails)} email(s) on {domain}')
        return list(emails)
    except Exception as e:
        log(f'  Apify scrape error: {e}')
        return []

# ── Main enrichment waterfall ─────────────────────────────────────────────────
def enrich_lead(lead):
    lead_id    = lead['id']
    first      = (lead.get('first_name') or '').strip()
    last       = (lead.get('last_name') or '').strip()
    email      = (lead.get('email') or '').strip()
    company    = (lead.get('company') or '').strip()
    website    = (lead.get('website') or '').strip()
    notes      = (lead.get('notes') or '')
    status     = lead.get('email_status')

    log(f'Enriching: {first} {last} @ {company} <{email}>')

    domain = extract_domain(website, email)
    if not domain:
        log(f'  No domain — skipping enrichment')
        supa_patch(f'leads?id=eq.{lead_id}', {'email_status': 'no_domain'})
        return False

    found_email = email if email else None
    enrichment_data = {}
    org_data = {}
    source = None

    # ── Pass 0: Apollo org enrichment (always, regardless of email status) ─
    log(f'  [0/4] Apollo org: {domain}')
    org_data = apollo_org_enrich(domain)

    # ── Pass 1: Apollo ─────────────────────────────────────────────────────
    if not found_email and first:
        log(f'  [1/4] Apollo lookup: {first} {last} @ {domain}')
        apollo_email, apollo_meta = apollo_find_email(first, last, domain, company)
        if apollo_email:
            found_email = apollo_email
            source = 'apollo'
        if apollo_meta:
            enrichment_data.update({k: v for k, v in apollo_meta.items() if v})

    # ── Pass 2: Hunter.io email-finder ─────────────────────────────────────
    if not found_email and first:
        log(f'  [2/4] Hunter email-finder: {first} {last} @ {domain}')
        hunter_email = hunter_find_email(first, last, domain)
        if hunter_email:
            found_email = hunter_email
            source = 'hunter'

    # ── Pass 3: Pattern generation (using Hunter domain pattern) ───────────
    if not found_email and first:
        log(f'  [3/4] Pattern generation for {domain}')
        pattern = hunter_domain_pattern(domain)
        if pattern:
            log(f'  Domain email pattern: {pattern}')
        candidates = generate_patterns(first, last, domain, pattern)
        log(f'  Candidates: {candidates[:3]}')
        # Verify each candidate with Hunter until one passes
        for candidate in candidates[:4]:
            vstatus, vscore = hunter_verify(candidate)
            if vstatus == 'valid' and vscore >= 70:
                found_email = candidate
                source = 'pattern'
                break
            elif vstatus in ('valid', 'accept_all') and vscore >= 50:
                found_email = candidate
                source = 'pattern'
                break
            time.sleep(0.3)

    # ── Pass 4: Apify website scrape ───────────────────────────────────────
    if not found_email:
        log(f'  [4/4] Apify scraping {domain} contact pages...')
        scraped = apify_scrape_emails(domain)
        if scraped:
            # Prefer emails with first name in them
            priority = [e for e in scraped if first.lower() in e.lower()] if first else []
            found_email = (priority or scraped)[0]
            source = 'apify'

    # ── Verification ───────────────────────────────────────────────────────
    if found_email:
        log(f'  Verifying {found_email} (source: {source})...')
        vstatus, vscore = hunter_verify(found_email)
        # Map Hunter status → our email_status
        if vstatus == 'valid':
            email_status = 'valid'
        elif vstatus == 'accept_all':
            email_status = 'catch_all'
        elif vstatus in ('invalid', 'disposable'):
            email_status = 'invalid'
        elif vstatus == 'risky':
            email_status = 'risky'
        else:
            email_status = 'unverified'
    else:
        log(f'  No email found after all passes')
        email_status = 'not_found'
        found_email = email  # keep original if any

    # ── Update Supabase ────────────────────────────────────────────────────
    update = {
        'email_status': email_status,
        'enriched_at':  datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    if found_email and found_email != email:
        update['email'] = found_email
    if enrichment_data.get('linkedin'):
        update['linkedin_url'] = enrichment_data['linkedin']
    if enrichment_data.get('title') and not lead.get('title'):
        update['title'] = enrichment_data['title']
    if enrichment_data.get('apollo_id') and not lead.get('apollo_id'):
        update['apollo_id'] = enrichment_data['apollo_id']
    if enrichment_data.get('seniority') and not lead.get('seniority'):
        update['seniority'] = enrichment_data['seniority']
    if enrichment_data.get('departments') and not lead.get('departments'):
        update['departments'] = enrichment_data['departments']
    if enrichment_data.get('headline') and not lead.get('headline'):
        update['headline'] = enrichment_data['headline']

    # Org enrichment fields (always write if we got data and field is empty)
    if org_data.get('company_description') and not lead.get('company_description'):
        update['company_description'] = org_data['company_description']
    if org_data.get('tech_stack'):
        update['tech_stack'] = org_data['tech_stack']
    if org_data.get('company_keywords'):
        update['company_keywords'] = org_data['company_keywords']
    if org_data.get('twitter_url') and not lead.get('twitter_url'):
        update['twitter_url'] = org_data['twitter_url']
    if org_data.get('company_linkedin_url') and not lead.get('company_linkedin_url'):
        update['company_linkedin_url'] = org_data['company_linkedin_url']
    if org_data.get('annual_revenue') and not lead.get('annual_revenue'):
        update['annual_revenue'] = org_data['annual_revenue']
    if org_data.get('founded_year') and not lead.get('founded_year'):
        update['founded_year'] = org_data['founded_year']
    # Update employee_count from org if not set
    if org_data.get('employee_count_org') and not lead.get('employee_count'):
        update['employee_count'] = org_data['employee_count_org']
    # Update industry from org if not set
    if org_data.get('industry_org') and not lead.get('industry'):
        update['industry'] = org_data['industry_org']

    supa_patch(f'leads?id=eq.{lead_id}', update)
    log(f'  → {email_status} | email: {found_email} | source: {source or "none"}')
    return email_status in ('valid', 'catch_all')

# ── Backfill: Apollo person + org enrichment on already-verified leads ─────────
def backfill_lead(lead):
    """Run Apollo people/match + org enrichment on a lead that already has email.
    Skips the Hunter email waterfall entirely — just populates the proper columns."""
    lead_id = lead['id']
    first   = (lead.get('first_name') or '').strip()
    last    = (lead.get('last_name') or '').strip()
    email   = (lead.get('email') or '').strip()
    company = (lead.get('company') or '').strip()
    website = (lead.get('website') or '').strip()

    log(f'Backfilling: {first} {last} @ {company}')

    domain = extract_domain(website, email)
    if not domain:
        log(f'  No domain — skipping')
        return

    update = {'enriched_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}

    # Apollo org enrichment
    org_data = apollo_org_enrich(domain)
    if org_data.get('company_description') and not lead.get('company_description'):
        update['company_description'] = org_data['company_description']
    if org_data.get('tech_stack'):
        update['tech_stack'] = org_data['tech_stack']
    if org_data.get('company_keywords'):
        update['company_keywords'] = org_data['company_keywords']
    if org_data.get('twitter_url') and not lead.get('twitter_url'):
        update['twitter_url'] = org_data['twitter_url']
    if org_data.get('company_linkedin_url') and not lead.get('company_linkedin_url'):
        update['company_linkedin_url'] = org_data['company_linkedin_url']
    if org_data.get('annual_revenue') and not lead.get('annual_revenue'):
        update['annual_revenue'] = org_data['annual_revenue']
    if org_data.get('founded_year') and not lead.get('founded_year'):
        update['founded_year'] = org_data['founded_year']
    if org_data.get('employee_count_org') and not lead.get('employee_count'):
        update['employee_count'] = org_data['employee_count_org']
    if org_data.get('industry_org') and not lead.get('industry'):
        update['industry'] = org_data['industry_org']

    # Apollo person match — get profile without revealing email (no credits)
    if first and APOLLO_KEY:
        payload = {'first_name': first, 'last_name': last, 'domain': domain}
        if company: payload['organization_name'] = company
        body = json.dumps(payload).encode()
        req = urllib.request.Request(
            'https://api.apollo.io/v1/people/match',
            data=body,
            headers=APOLLO_HEADERS,
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                d = json.loads(r.read())
            p = d.get('person') or {}
            if p:
                eh = p.get('employment_history') or []
                if not lead.get('linkedin_url') and p.get('linkedin_url'):
                    update['linkedin_url'] = p['linkedin_url']
                if not lead.get('title') and p.get('title'):
                    update['title'] = p['title']
                if not lead.get('apollo_id') and p.get('id'):
                    update['apollo_id'] = p['id']
                if not lead.get('seniority') and p.get('seniority'):
                    update['seniority'] = p['seniority']
                if not lead.get('departments') and p.get('departments'):
                    update['departments'] = p['departments']
                if not lead.get('headline') and p.get('headline'):
                    update['headline'] = p['headline']
                if p.get('twitter_url') and 'twitter_url' not in update:
                    update['twitter_url'] = p['twitter_url']
                log(f'  Apollo person: linkedin={bool(p.get("linkedin_url"))}, seniority={p.get("seniority")}, headline={bool(p.get("headline"))}')
        except Exception as e:
            log(f'  Apollo person error: {e}')

    if len(update) > 1:  # more than just enriched_at
        supa_patch(f'leads?id=eq.{lead_id}', update)
        log(f'  → updated {len(update)-1} fields')
    else:
        log(f'  → nothing new to write')

# ── Entry point ───────────────────────────────────────────────────────────────
if ARG1 == '--lead' and ARG2:
    leads = supa_get(f'leads?id=eq.{ARG2}&select=*')
    if not leads:
        log(f'Lead {ARG2} not found')
        sys.exit(1)
    enrich_lead(leads[0])
    sys.exit(0)

if ARG1 == '--email' and ARG2:
    vstatus, vscore = hunter_verify(ARG2)
    log(f'Verification result: {vstatus} (score={vscore})')
    sys.exit(0)

if ARG1 == '--backfill':
    # Re-enrich all leads that already have emails but are missing company_description
    # Runs Apollo person/match + org enrichment only — skips Hunter waterfall
    limit = int(ARG2) if ARG2 and ARG2.isdigit() else 50
    leads = supa_get(
        f'leads?company_description=is.null'
        f'&email_status=in.(valid,catch_all,unverified)'
        f'&order=created_at.asc&limit={limit}&select=*'
    )
    if not leads:
        log('All leads already have company data — nothing to backfill')
        sys.exit(0)
    log(f'Backfilling {len(leads)} lead(s) with Apollo person + org data...')
    for lead in leads:
        try:
            backfill_lead(lead)
            time.sleep(1.2)  # Apollo rate limit courtesy
        except Exception as e:
            log(f'Error backfilling {lead.get("id")}: {e}')
    log(f'Backfill complete.')
    sys.exit(0)

# Default: process up to 20 leads needing enrichment
# Priority: email_status IS NULL first, then 'unverified'
leads = supa_get(
    'leads?email_status=is.null'
    '&status=neq.unsubscribed&status=neq.invalid'
    '&order=created_at.asc&limit=20&select=*'
)
if not leads:
    leads = supa_get(
        'leads?email_status=eq.unverified'
        '&status=neq.unsubscribed'
        '&order=created_at.asc&limit=10&select=*'
    )

if not leads:
    log('No leads to enrich')
    sys.exit(0)

log(f'Processing {len(leads)} lead(s)...')
success = 0
failed  = 0

for lead in leads:
    try:
        ok = enrich_lead(lead)
        if ok: success += 1
        else:   failed  += 1
        time.sleep(1)  # rate limit courtesy pause
    except Exception as e:
        log(f'Error enriching {lead.get("id")}: {e}')
        failed += 1

summary = f'✅ <b>Lead enrichment complete</b>\n\n• Verified: {success}\n• Not found/invalid: {failed}\n• Total processed: {len(leads)}'
log(summary.replace('<b>','').replace('</b>',''))

if success > 0:
    tg(summary)
PY
