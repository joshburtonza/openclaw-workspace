#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# masara-lead-handler.sh
#
# Handles natural language lead requests from Masara via Telegram.
# Parses her request with Claude Haiku, searches Apollo, enriches, and
# sends a formatted lead list with CALL PREP NOTES back via Telegram.
#
# Coaching features:
#   - Personalised call prep notes for each lead batch
#   - Opening lines tailored to Masara's calling style
#   - Objection handling tips based on the ICP
#   - Coaching tips that rotate based on her profile
#
# Usage:
#   bash masara-lead-handler.sh <chat_id> "<natural language request>"
#
# Daily limit: 50 leads per day (tracked in tmp/masara-lead-usage-YYYY-MM-DD)
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CHAT_ID="${1:-}"
REQUEST="${2:-}"

if [[ -z "$CHAT_ID" || -z "$REQUEST" ]]; then
    echo "Usage: masara-lead-handler.sh <chat_id> <request>" >&2
    exit 1
fi

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
APOLLO_KEY="${APOLLO_API_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
JOSH_CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
LOG="$WS/out/masara-lead-handler.log"
GATE="$WS/bin/claude-gated"
mkdir -p "$WS/out" "$WS/tmp"

export SUPABASE_URL KEY APOLLO_KEY BOT_TOKEN CHAT_ID JOSH_CHAT_ID LOG WS REQUEST GATE

python3 << 'PY'
import json, os, sys, re, urllib.request, urllib.parse, datetime, time, subprocess

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['KEY']
APOLLO_KEY   = os.environ['APOLLO_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
JOSH_CHAT_ID = os.environ['JOSH_CHAT_ID']
LOG_PATH     = os.environ['LOG']
WS           = os.environ['WS']
REQUEST      = os.environ['REQUEST']
GATE         = os.environ['GATE']

DAILY_LIMIT = 50
TODAY = datetime.date.today().isoformat()
USAGE_FILE = f"{WS}/tmp/masara-lead-usage-{TODAY}"

APOLLO_UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36'
PROFILE_FILE = f"{WS}/tmp/masara-profile.json"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def load_masara_profile():
    """Load Masara's coaching profile."""
    try:
        with open(PROFILE_FILE) as f:
            return json.loads(f.read())
    except:
        return {}

def save_masara_profile(profile):
    """Save updated profile."""
    with open(PROFILE_FILE, 'w') as f:
        json.dump(profile, f, indent=2)

def log(msg):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    line = f'[{ts}] {msg}'
    print(line, flush=True)
    with open(LOG_PATH, 'a') as f: f.write(line + '\n')

def tg(text, chat=None):
    cid = chat or CHAT_ID
    payload = json.dumps({'chat_id': cid, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        data=payload, headers={'Content-Type': 'application/json'}
    )
    try: urllib.request.urlopen(req, timeout=10)
    except Exception as e: log(f'tg error: {e}')

def tg_doc(chat, filepath, caption=''):
    """Send a file as a Telegram document."""
    import mimetypes
    boundary = '----FormBoundary' + str(int(time.time()))
    fname = os.path.basename(filepath)
    mime = mimetypes.guess_type(filepath)[0] or 'text/csv'

    with open(filepath, 'rb') as f:
        file_data = f.read()

    body = (
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="chat_id"\r\n\r\n{chat}\r\n'
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="caption"\r\n\r\n{caption}\r\n'
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="parse_mode"\r\n\r\nHTML\r\n'
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="document"; filename="{fname}"\r\n'
        f'Content-Type: {mime}\r\n\r\n'
    ).encode() + file_data + f'\r\n--{boundary}--\r\n'.encode()

    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendDocument',
        data=body,
        headers={'Content-Type': f'multipart/form-data; boundary={boundary}'}
    )
    try: urllib.request.urlopen(req, timeout=30)
    except Exception as e: log(f'tg_doc error: {e}')

def get_daily_usage():
    try:
        with open(USAGE_FILE) as f:
            return int(f.read().strip())
    except:
        return 0

def set_daily_usage(count):
    with open(USAGE_FILE, 'w') as f:
        f.write(str(count))

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
            log(f'  Apollo {endpoint} HTTP {e.code}: {e.read()[:200]}')
            if e.code == 429:
                time.sleep(3 * (attempt + 1))
            else:
                return None
        except Exception as e:
            log(f'  Apollo {endpoint} error: {e}')
            time.sleep(1)
    return None

def supa_get(path):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    req = urllib.request.Request(url, headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except Exception as e:
        log(f'supa_get error: {e}')
        return []

def supa_post(path, data):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    payload = json.dumps(data).encode()
    req = urllib.request.Request(url, data=payload, method='POST', headers={
        'apikey': KEY, 'Authorization': f'Bearer {KEY}',
        'Content-Type': 'application/json', 'Prefer': 'return=minimal',
    })
    try:
        urllib.request.urlopen(req, timeout=20)
        return True
    except Exception as e:
        log(f'supa_post error: {e}')
        return False

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Parse natural language request with Claude Haiku
# ─────────────────────────────────────────────────────────────────────────────

def parse_request(text):
    """Use Claude Haiku to extract structured search params from natural language."""
    prompt = f"""You are a lead sourcing assistant. Parse this request into Apollo.io search parameters.

Request: "{text}"

Return ONLY valid JSON with these fields (omit any that aren't specified):
{{
  "count": <number of leads requested, default 15, max 50>,
  "person_titles": ["<job titles to search for>"],
  "person_locations": ["<countries or cities>"],
  "organization_industries": ["<industries in lowercase>"],
  "organization_num_employees_ranges": ["<range like '1,10' or '11,50' or '51,200' or '201,1000'>"],
  "wants_email": true/false,
  "wants_phone": true/false,
  "wants_linkedin": true/false,
  "keywords": ["<any other keywords mentioned>"]
}}

Rules:
- If they say "any firms" or don't specify industry, omit organization_industries
- If they say "any size" or don't specify, omit organization_num_employees_ranges
- If no location specified, default to person_locations: ["South Africa"]
- Map common terms: "tech managers" = ["Technology Manager", "IT Manager", "Engineering Manager"]
- Map "CTO" = ["CTO", "Chief Technology Officer"]
- Map "CEO" = ["CEO", "Chief Executive Officer"]
- Map "founders" = ["Founder", "Co-Founder"]
- Map "directors" = ["Director", "Managing Director"]
- Always set wants_email, wants_phone, wants_linkedin to true unless they say otherwise
- Return ONLY the JSON, no explanation"""

    try:
        result = subprocess.run(
            [GATE, '-m', 'claude-haiku-4-5-20251001', '-p', prompt, '--output-format', 'json'],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, 'CLAUDE_GATED_CALLER': 'masara-lead-handler'}
        )
        raw = result.stdout.strip()
        # Extract JSON from response (handle markdown code blocks)
        if '```' in raw:
            raw = re.search(r'```(?:json)?\s*(.*?)\s*```', raw, re.DOTALL)
            raw = raw.group(1) if raw else '{}'
        return json.loads(raw)
    except subprocess.TimeoutExpired:
        log('Claude Haiku timed out')
        return None
    except json.JSONDecodeError as e:
        log(f'JSON parse error: {e} | raw: {raw[:200]}')
        return None
    except Exception as e:
        log(f'parse_request error: {e}')
        return None

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Search Apollo
# ─────────────────────────────────────────────────────────────────────────────

def search_apollo(params, count):
    """Search Apollo with parsed params, return list of lead dicts."""
    search_payload = {
        'per_page': min(count * 2, 100),  # fetch extra for dedup buffer
        'page': 1,
    }

    if params.get('person_titles'):
        search_payload['person_titles'] = params['person_titles']
    if params.get('person_locations'):
        search_payload['person_locations'] = params['person_locations']
    if params.get('organization_industries'):
        search_payload['organization_industries'] = params['organization_industries']
    if params.get('organization_num_employees_ranges'):
        search_payload['organization_num_employees_ranges'] = params['organization_num_employees_ranges']

    log(f'Apollo search: {json.dumps(search_payload, indent=2)}')

    # Load existing emails for dedup
    existing_emails = set()
    existing_rows = supa_get('leads?select=email&limit=5000')
    for r in existing_rows:
        if r.get('email'):
            existing_emails.add(r['email'].lower().strip())

    results = apollo_post('mixed_people/api_search', search_payload)
    if not results:
        return []

    people = results.get('people', [])
    total = results.get('total_entries', 0)
    log(f'  Apollo returned {len(people)} of {total:,} total matches')

    leads = []
    for raw in people:
        if len(leads) >= count:
            break

        apollo_id  = raw.get('id', '')
        first_name = (raw.get('first_name') or '').strip()
        last_name  = (raw.get('last_name') or '').strip()
        title      = raw.get('title') or ''
        org_raw    = raw.get('organization', {}) or {}
        org_name   = (org_raw.get('name') or '').strip()
        linkedin   = raw.get('linkedin_url') or ''
        city       = raw.get('city') or ''
        country    = raw.get('country') or ''
        email      = raw.get('email') or ''

        if not first_name or not org_name:
            continue

        if email and email.lower() in existing_emails:
            continue

        # Reveal profile for email + phone
        reveal_r = apollo_post('people/match', {
            'id': apollo_id,
            'reveal_personal_emails': True,
            'reveal_phone_number': True,
        })
        time.sleep(0.8)

        person = {}
        if reveal_r:
            person = reveal_r.get('person', {}) or {}

        final_email    = person.get('email') or email or ''
        final_linkedin = person.get('linkedin_url') or linkedin or ''
        final_phone    = ''
        phone_numbers  = person.get('phone_numbers', []) or []
        if phone_numbers:
            # Prefer mobile, then direct, then any
            for ptype in ['mobile_phone', 'direct_phone', 'other_phone']:
                for p in phone_numbers:
                    if p.get('type') == ptype and p.get('sanitized_number'):
                        final_phone = p['sanitized_number']
                        break
                if final_phone:
                    break
            if not final_phone and phone_numbers:
                final_phone = phone_numbers[0].get('sanitized_number', '')

        org = person.get('organization', {}) or org_raw
        domain = org.get('primary_domain') or ''

        lead = {
            'name': f"{first_name} {last_name}".strip(),
            'title': person.get('title') or title,
            'company': org_name,
            'email': final_email,
            'phone': final_phone,
            'linkedin': final_linkedin,
            'city': person.get('city') or city,
            'country': person.get('country') or country,
            'domain': domain,
            'apollo_id': apollo_id,
        }
        leads.append(lead)

        if final_email:
            existing_emails.add(final_email.lower())

        log(f'  ✓ {lead["name"]} | {lead["title"]} @ {lead["company"]} | email={bool(final_email)} phone={bool(final_phone)}')

    return leads

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Insert into Supabase leads table
# ─────────────────────────────────────────────────────────────────────────────

def insert_leads(leads, params):
    """Insert leads into Supabase for tracking."""
    inserted = 0
    for lead in leads:
        row = {
            'first_name': lead['name'].split()[0] if lead['name'] else '',
            'last_name': ' '.join(lead['name'].split()[1:]) if ' ' in lead.get('name', '') else '',
            'email': lead.get('email') or None,
            'company': lead.get('company'),
            'website': f"https://{lead['domain']}" if lead.get('domain') else None,
            'source': 'apollo',
            'status': 'new',
            'assigned_to': 'Masara',
            'tags': ['masara-sourced', 'telemarketing'],
            'notes': f"Sourced by Masara via Telegram.\nTitle: {lead.get('title','')}\nRequest: {REQUEST[:200]}",
            'apollo_id': lead.get('apollo_id'),
            'linkedin_url': lead.get('linkedin') or None,
            'title': lead.get('title') or None,
            'city': lead.get('city') or None,
            'country': lead.get('country') or None,
            'email_status': 'unverified' if lead.get('email') else None,
            'phone_number': lead.get('phone') or None,
        }
        if supa_post('leads', row):
            inserted += 1
    return inserted

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Format and send results via Telegram + CSV
# ─────────────────────────────────────────────────────────────────────────────

def generate_call_prep(leads, params, profile):
    """Use Claude Haiku to generate personalised call prep notes."""
    if not leads:
        return ''

    # Build a summary of leads for context
    lead_summary = []
    for l in leads[:10]:  # Top 10 for context (token budget)
        lead_summary.append(f"- {l['name']}, {l.get('title','')} at {l['company']} ({l.get('city','')}, {l.get('country','')})")
    leads_text = '\n'.join(lead_summary)

    style = profile.get('call_style', 'friendly')
    challenges = profile.get('challenges', 'general objections')
    experience = profile.get('experience', 'some experience')
    pitch = profile.get('pitch_style', 'AI automation for businesses')

    prompt = f"""You are a cold calling coach for a telemarketer named Masara. She works at Amalfi AI (an AI automation agency in South Africa).

Her profile:
- Experience: {experience}
- Calling style: {style}
- Strengths: {profile.get('strengths', 'N/A')}
- Challenges: {challenges}
- How she describes Amalfi: {pitch}

She just sourced these leads:
{leads_text}

Titles searched: {', '.join(params.get('person_titles', ['various']))}
Industries: {', '.join(params.get('organization_industries', ['various']))}

Write a SHORT call prep briefing (max 400 words) with:
1. A 2-sentence opening line she can use, tailored to this ICP
2. 3 discovery questions to ask these types of prospects
3. The #1 objection she'll likely face from this ICP and how to handle it
4. One quick coaching tip based on her challenges

Use plain, warm South African English. No corporate speak. Be encouraging but practical.
Format with simple line breaks (no markdown). Keep it punchy."""

    try:
        result = subprocess.run(
            [GATE, '-m', 'claude-haiku-4-5-20251001', '-p', prompt, '--max-tokens', '600'],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, 'CLAUDE_GATED_CALLER': 'masara-call-prep'}
        )
        return result.stdout.strip()
    except Exception as e:
        log(f'call prep generation error: {e}')
        return ''

def get_coaching_tip(batch_num):
    """Rotate through coaching tips based on batch number."""
    tips = [
        "💡 <b>Tip:</b> Smile when you dial. People can hear it in your voice.",
        "💡 <b>Tip:</b> Write down the prospect's name and use it 2-3 times. It builds instant rapport.",
        "💡 <b>Tip:</b> If they say \"send me an email\", always ask a qualifying question first.",
        "💡 <b>Tip:</b> Keep a tally of calls vs connects vs meetings booked. Patterns emerge fast.",
        "💡 <b>Tip:</b> The first 3 calls of the day are warmups. Don't call your best leads first.",
        "💡 <b>Tip:</b> After a rejection, stand up and stretch. Reset before the next call.",
        "💡 <b>Tip:</b> Don't read a script word for word. Have bullet points and be natural.",
        "💡 <b>Tip:</b> Ask \"Is now a bad time?\" instead of \"Is now a good time?\" — it gets better results.",
        "💡 <b>Tip:</b> Mirror the prospect's pace. Fast talkers want fast. Slow talkers want slow.",
        "💡 <b>Tip:</b> If you're nervous, remember: they're just people. Most will be polite.",
        "💡 <b>Tip:</b> End every call with a next step. Even \"I'll email you Tuesday\" is something.",
        "💡 <b>Tip:</b> Listen more than you talk. A 70/30 split (them/you) is golden.",
        "💡 <b>Tip:</b> Track your best time of day. Most people have a calling sweet spot.",
        "💡 <b>Tip:</b> When a gatekeeper asks \"What's this about?\", say the prospect's name first.",
        "💡 <b>Tip:</b> Celebrate small wins. A callback counts. A \"maybe\" counts. Keep momentum.",
    ]
    return tips[batch_num % len(tips)]

def format_and_send(leads, params, profile):
    """Send results to Masara as a formatted message + CSV + call prep + coaching."""
    if not leads:
        tg("😕 No leads found matching your criteria. Try broadening your search — "
           "fewer title restrictions or a wider location.")
        return

    count = len(leads)
    with_email = sum(1 for l in leads if l.get('email'))
    with_phone = sum(1 for l in leads if l.get('phone'))
    with_linkedin = sum(1 for l in leads if l.get('linkedin'))

    # ── Message 1: Lead summary + preview ──
    summary = (
        f"✅ <b>Found {count} leads</b>\n"
        f"📧 {with_email} with email | 📱 {with_phone} with phone | 🔗 {with_linkedin} with LinkedIn\n\n"
    )

    preview_count = min(5, count)
    summary += f"<b>Preview (first {preview_count}):</b>\n\n"

    for i, lead in enumerate(leads[:preview_count]):
        summary += f"<b>{i+1}. {lead['name']}</b>\n"
        summary += f"   {lead.get('title', '')} @ {lead['company']}\n"
        if lead.get('email'):
            summary += f"   📧 {lead['email']}\n"
        if lead.get('phone'):
            summary += f"   📱 {lead['phone']}\n"
        if lead.get('linkedin'):
            summary += f"   🔗 {lead['linkedin']}\n"
        summary += "\n"

    if count > preview_count:
        summary += f"<i>... and {count - preview_count} more in the CSV below</i>"

    tg(summary)

    # ── Message 2: Call prep notes (if profile exists) ──
    if profile.get('onboarded'):
        log('Generating call prep notes...')
        call_prep = generate_call_prep(leads, params, profile)
        if call_prep:
            tg(f"📝 <b>Call Prep Notes</b>\n\n{call_prep}")
        else:
            log('Call prep generation returned empty')

    # ── Message 3: Coaching tip ──
    batch_num = profile.get('total_batches', 0)
    tip = get_coaching_tip(batch_num)
    tg(tip)

    # ── CSV file ──
    csv_path = f"{WS}/tmp/masara-leads-{TODAY}-{int(time.time())}.csv"
    import csv
    with open(csv_path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['Name', 'Title', 'Company', 'Email', 'Phone', 'LinkedIn', 'City', 'Country'])
        for lead in leads:
            writer.writerow([
                lead.get('name', ''),
                lead.get('title', ''),
                lead.get('company', ''),
                lead.get('email', ''),
                lead.get('phone', ''),
                lead.get('linkedin', ''),
                lead.get('city', ''),
                lead.get('country', ''),
            ])

    tg_doc(CHAT_ID, csv_path, f"📋 <b>{count} leads</b> — {TODAY}")

    # ── Notify Josh ──
    tg(f"📋 Masara sourced <b>{count} leads</b> via Alex bot.\n"
       f"Request: <i>{REQUEST[:200]}</i>\n"
       f"📧 {with_email} emails | 📱 {with_phone} phones",
       chat=JOSH_CHAT_ID)

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    log(f'\n=== Masara lead request: {REQUEST[:200]} ===')

    # Load her coaching profile
    profile = load_masara_profile()
    log(f'  Profile loaded: onboarded={profile.get("onboarded", False)}, batches={profile.get("total_batches", 0)}')

    # Check daily limit
    used = get_daily_usage()
    if used >= DAILY_LIMIT:
        tg(f"⚠️ Daily limit reached ({DAILY_LIMIT} leads). Resets at midnight. Try again tomorrow!\n\n"
           f"In the meantime, review your existing leads and prep for tomorrow's calls 💪")
        return

    remaining = DAILY_LIMIT - used

    # Step 1: Parse request
    log('Step 1: Parsing request with Claude Haiku...')
    params = parse_request(REQUEST)
    if not params:
        tg("😕 Couldn't quite understand that. Try something like:\n\n"
           "<i>\"15 leads, CTOs at tech companies in South Africa\"</i>\n\n"
           "Include: how many leads, job titles, and optionally the industry or location.")
        return

    count = min(params.get('count', 15), remaining)
    log(f'  Parsed: {json.dumps(params, indent=2)}')
    log(f'  Requesting {count} leads (used {used}/{DAILY_LIMIT} today)')

    # Step 2: Search Apollo
    log('Step 2: Searching Apollo...')
    leads = search_apollo(params, count)

    if not leads:
        tg("😕 No leads matched those filters. A few things to try:\n"
           "• Broaden the job titles (e.g. \"managers\" instead of \"senior tech leads\")\n"
           "• Widen the location (e.g. \"South Africa\" instead of a specific city)\n"
           "• Drop the industry filter if you used one\n\n"
           "Give it another go!")
        return

    # Step 3: Insert into Supabase
    log(f'Step 3: Inserting {len(leads)} leads into Supabase...')
    inserted = insert_leads(leads, params)
    log(f'  Inserted {inserted} new leads')

    # Step 4: Format, send with call prep + coaching
    log('Step 4: Sending results + call prep to Masara...')
    format_and_send(leads, params, profile)

    # Update daily usage
    new_usage = used + len(leads)
    set_daily_usage(new_usage)
    log(f'  Daily usage: {new_usage}/{DAILY_LIMIT}')

    # Update her profile stats
    profile['total_batches'] = profile.get('total_batches', 0) + 1
    profile['total_leads_sourced'] = profile.get('total_leads_sourced', 0) + len(leads)
    profile['last_request'] = REQUEST[:200]
    profile['last_request_at'] = datetime.datetime.now().isoformat()
    save_masara_profile(profile)
    log(f'  Profile updated: batch #{profile["total_batches"]}, {profile["total_leads_sourced"]} total leads')

    log('=== Done ===')

try:
    main()
except Exception as e:
    log(f'FATAL: {e}')
    tg(f"❌ Something went wrong: {str(e)[:200]}\n\nTry again or ask Josh for help.")
PY
