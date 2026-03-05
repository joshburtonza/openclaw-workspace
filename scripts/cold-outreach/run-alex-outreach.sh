#!/usr/bin/env bash
# run-alex-outreach.sh
# Alex cold outreach — runs every 10 min via LaunchAgent.
# Sends exactly 1 email per run, highest-probability lead first.
# Dynamic warmup cap: 10→15→20→30→40→50/day over 6 weeks.
# Time window: 6:30am–3:00pm SAST, Mon–Fri only.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

source "$WS/scripts/lib/agent-registry.sh"
agent_checkin "worker-outreach-sender" "worker" "sales-supervisor"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
FROM_ACCOUNT="alex@amalfiai.com"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="1140320036"
OPENAI_MODEL="gpt-4o"
export OPENAI_MODEL
LOG="$WS/out/alex-outreach.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
source "$WS/scripts/lib/task-helpers.sh"

# ── 1. Time window (SAST = UTC+2) ─────────────────────────────────────────────
SAST_MINS=$(TZ=Africa/Johannesburg date +%-H)
SAST_MINS=$(( SAST_MINS * 60 + $(TZ=Africa/Johannesburg date +%-M) ))
SAST_DOW=$(TZ=Africa/Johannesburg date +%u)
[[ "$SAST_DOW" -ge 6 ]] && { log "Weekend — skip."; exit 0; }
[[ "$SAST_MINS" -lt 390 || "$SAST_MINS" -ge 900 ]] && exit 0  # outside 6:30–15:00

log "=== Alex run (SAST $(TZ=Africa/Johannesburg date '+%H:%M %a')) ==="
TASK_ID=$(task_create "Alex outreach run" "Selecting and emailing next lead in sequence" "Alex" "normal")

export SUPABASE_URL SUPABASE_KEY FROM_ACCOUNT BOT_TOKEN CHAT_ID OPENAI_API_KEY

python3 - <<'PY'
import os, sys, json, subprocess, datetime, time, re, uuid
import urllib.request, urllib.error
from html.parser import HTMLParser

VERCEL_PIXEL_BASE = "https://amalfi-mission-control.vercel.app/api/track-open"

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SUPABASE_KEY']
FROM_ACCOUNT = os.environ['FROM_ACCOUNT']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']

# ── Supabase helpers ───────────────────────────────────────────────────────────

def supa_get(path):
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())

def supa_post(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()

def supa_patch(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()

def tg(text):
    if not BOT_TOKEN:
        return
    try:
        data = json.dumps({"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML"}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            data=data, headers={"Content-Type": "application/json"}, method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def now_utc_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def days_since(iso_str):
    if not iso_str:
        return 9999
    try:
        dt = datetime.datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return (datetime.datetime.now(datetime.timezone.utc) - dt).days
    except:
        return 9999

# ── Warmup: dynamic daily cap ──────────────────────────────────────────────────

def get_warmup_cap():
    """
    Calculate today's send cap based on days since first ever email sent.
    Schedule:
      Days  1-7:  10/day
      Days  8-14: 15/day
      Days 15-21: 20/day
      Days 22-28: 30/day
      Days 29-35: 40/day
      Days 36+:   50/day
    """
    try:
        first = supa_get("outreach_log?select=sent_at&order=sent_at.asc&limit=1")
        if not first:
            return 10  # No emails yet — first day
        first_sent = first[0]['sent_at']
        days_active = days_since(first_sent)
    except Exception:
        return 10

    if   days_active <  7: return 10
    elif days_active < 14: return 15
    elif days_active < 21: return 20
    elif days_active < 28: return 30
    elif days_active < 35: return 40
    else:                  return 50

DAILY_CAP = get_warmup_cap()

# Today's start (midnight SAST → UTC)
sast = datetime.timezone(datetime.timedelta(hours=2))
today_sast = datetime.datetime.now(sast).replace(hour=0, minute=0, second=0, microsecond=0)
today_utc  = today_sast.astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

sent_today = len(supa_get(f"outreach_log?select=id&sent_at=gte.{today_utc}"))
print(f"[warmup] Day cap: {DAILY_CAP} | Sent today: {sent_today}")

if sent_today >= DAILY_CAP:
    print("[alex] Daily warmup cap reached — done for today.")
    sys.exit(0)

# ── Lead scoring ───────────────────────────────────────────────────────────────

# Industry tiers for AI automation relevance
INDUSTRIES_HIGH = {
    'hr & staffing', 'human resources', 'staffing', 'recruitment',
    'business services', 'management consulting', 'consulting',
    'law firms', 'legal services', 'legal',
    'accounting', 'accounting services', 'finance', 'financial services',
    'custom software', 'software', 'saas', 'technology', 'it services',
    'architecture, engineering', 'engineering',
}
INDUSTRIES_MED = {
    'real estate', 'property', 'construction',
    'media & internet', 'media', 'publishing', 'marketing',
    'education', 'research', 'insurance',
    'logistics', 'supply chain', 'transportation',
}

DM_TITLES_TOP = [
    'chief executive', 'ceo', 'founder', 'co-founder', 'cofounder',
    'owner', 'managing director', 'managing partner', 'president',
]
DM_TITLES_MID = [
    'director', 'head of', 'vp ', 'vice president', 'partner',
    'principal', 'coo', 'cfo', 'cto', 'chief operating',
]
DM_TITLES_LOW = [
    'manager', 'senior manager', 'lead ', 'senior ',
]

def score_lead(lead):
    score = 0
    notes  = (lead.get('notes') or '').lower()
    source = lead.get('source', '')
    email  = (lead.get('email') or '').lower()
    tags   = [t.lower() for t in (lead.get('tags') or [])]
    tag_str = ' '.join(tags)

    # ── Source quality (real person vs business listing) ──
    if source == 'linkedin':
        score += 30

    # ── Decision-maker title ──
    if any(t in notes for t in DM_TITLES_TOP):
        score += 25
    elif any(t in notes for t in DM_TITLES_MID):
        score += 15
    elif any(t in notes for t in DM_TITLES_LOW):
        score += 5

    # ── Revenue band (proxy for ability to pay) ──
    if any(x in notes for x in ['$50 mil', '$100 mil', '$500 mil', '$1 bil', '$25 mil']):
        score += 20
    elif '$10 mil' in notes:
        score += 15
    elif '$5 mil' in notes:
        score += 12
    elif '$1 mil' in notes:
        score += 8

    # ── Company size (10-50 = sweet spot) ──
    if any(x in notes for x in ['size: 20 - 50', 'size: 50 - 100', 'size: 10 - 20']):
        score += 10
    elif 'size: 5 - 10' in notes:
        score += 7
    elif 'size: 1 - 5' in notes:
        score += 3

    # ── Industry fit ──
    if any(ind in tag_str for ind in INDUSTRIES_HIGH):
        score += 15
    elif any(ind in tag_str for ind in INDUSTRIES_MED):
        score += 8

    # ── Email quality (personal = better deliverability + personalization) ──
    generic_prefixes = ('info@', 'contact@', 'hello@', 'admin@', 'support@', 'office@')
    if not any(email.startswith(p) for p in generic_prefixes):
        score += 10

    # ── Rich context available (better personalization) ──
    if len(notes) > 200:
        score += 5
    elif len(notes) > 100:
        score += 3

    # ── Has website (can research) ──
    if lead.get('website'):
        score += 3

    # ── Has phone (multi-channel follow-up possible) ──
    if 'phone:' in notes:
        score += 2

    return score

# ── Industry vertical detection + outcome hooks ───────────────────────────────

VERTICAL_RECRUITMENT   = {'hr & staffing', 'human resources', 'staffing', 'recruitment', 'hr'}
VERTICAL_LEGAL_PROP    = {
    'law firms', 'legal services', 'legal', 'attorneys', 'conveyancing',
    'real estate', 'property',
}
VERTICAL_LOGISTICS     = {'logistics', 'supply chain', 'transportation', 'freight', 'courier', 'dispatch'}

VERTICAL_INDUSTRIAL = {
    'mining', 'mining operations', 'industrial', 'manufacturing', 'plant',
    'processing', 'heavy industry', 'resources', 'minerals', 'metallurgy',
    'smelting', 'refinery',
}
VERTICAL_MEDIA = {
    'media', 'entertainment', 'broadcast', 'television', 'tv channel',
    'lifestyle channel', 'streaming', 'publishing', 'magazine', 'events',
    'advertising sales', 'sponsorship',
}

OUTCOME_HOOKS = {
    'recruitment':        'tool consolidation that replaces fragmented spend on Venturi, LinkedIn Recruiter, and ChatGPT',
    'legal_property':     'contract intake processed without manual triage',
    'logistics':          'booking and dispatch flow without the back-and-forth',
    'industrial':         'compliance reporting and shift data captured automatically, no manual entry',
    'media_entertainment':'ad sales pipeline automated, subscription acquisition on autopilot',
}

# ── Geo detection ────────────────────────────────────────────────────────────

SA_SIGNALS = {
    '.co.za', '.za', 'south africa', 'johannesburg', 'cape town', 'durban',
    'pretoria', 'sandton', 'centurion', 'stellenbosch', 'port elizabeth',
    'bloemfontein', 'polokwane', 'nelspruit', 'pietermaritzburg',
}
UK_SIGNALS = {
    '.co.uk', '.uk', 'united kingdom', 'london', 'manchester', 'birmingham',
    'leeds', 'glasgow', 'edinburgh', 'bristol', 'liverpool', 'sheffield',
    'cardiff', 'belfast', 'nottingham', 'southampton',
}
US_SIGNALS = {
    '.com', 'united states', 'new york', 'san francisco', 'los angeles',
    'chicago', 'houston', 'phoenix', 'philadelphia', 'san antonio',
    'dallas', 'austin', 'seattle', 'boston', 'denver', 'atlanta',
}

def detect_geo(lead):
    """Detect lead geography from country field, email domain, notes, or tags."""
    country = (lead.get('country') or '').lower().strip()
    if country:
        if any(s in country for s in ['south africa', 'sa', 'za']):
            return 'south_africa'
        if any(s in country for s in ['united kingdom', 'uk', 'england', 'scotland', 'wales']):
            return 'united_kingdom'
        if any(s in country for s in ['united states', 'us', 'usa', 'america']):
            return 'united_states'
        return 'international'

    email   = (lead.get('email') or '').lower()
    notes   = (lead.get('notes') or '').lower()
    website = (lead.get('website') or '').lower()
    tags    = ' '.join([t.lower() for t in (lead.get('tags') or [])])
    blob    = f"{email} {notes} {website} {tags}"

    if any(s in blob for s in SA_SIGNALS):
        return 'south_africa'
    if any(s in blob for s in UK_SIGNALS):
        return 'united_kingdom'
    # .com is too generic, only match US if city/country signals present
    us_check = {s for s in US_SIGNALS if s != '.com'}
    if any(s in blob for s in us_check):
        return 'united_states'
    return 'international'

def detect_industry(lead):
    tags     = [t.lower() for t in (lead.get('tags') or [])]
    tag_str  = ' '.join(tags)
    notes    = (lead.get('notes') or '').lower()
    combined = tag_str + ' ' + notes

    if any(v in combined for v in VERTICAL_RECRUITMENT):
        return 'recruitment'
    if any(v in combined for v in VERTICAL_LEGAL_PROP):
        return 'legal_property'
    if any(v in combined for v in VERTICAL_LOGISTICS):
        return 'logistics'
    if any(v in combined for v in VERTICAL_INDUSTRIAL):
        return 'industrial'
    if any(v in combined for v in VERTICAL_MEDIA):
        return 'media_entertainment'
    return 'general'

# ── Website research ──────────────────────────────────────────────────────────

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self._parts = []
        self._skip  = False

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'nav', 'footer', 'head', 'noscript'):
            self._skip = True

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'nav', 'footer', 'head', 'noscript'):
            self._skip = False

    def handle_data(self, data):
        if not self._skip:
            s = data.strip()
            if s:
                self._parts.append(s)

    def get_text(self):
        return ' '.join(self._parts)

def research_website(url, timeout=6):
    if not url:
        return ""
    try:
        if not url.startswith("http"):
            url = "https://" + url
        req = urllib.request.Request(
            url, headers={"User-Agent": "Mozilla/5.0 (compatible; research-bot/1.0)"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(32768).decode("utf-8", errors="ignore")
        parser = TextExtractor()
        parser.feed(raw)
        text = re.sub(r'\s+', ' ', parser.get_text()).strip()
        if len(text) > 400:
            text = text[:400].rsplit(' ', 1)[0] + "…"
        return text
    except Exception:
        return ""

# ── Email generation ──────────────────────────────────────────────────────────

def build_prompt(lead, step, website_context):
    fname   = lead.get('first_name', 'there')
    company = lead.get('company', '') or 'your company'
    notes   = lead.get('notes', '') or ''
    geo     = detect_geo(lead)
    vertical = detect_industry(lead)
    hook    = OUTCOME_HOOKS.get(vertical, '')

    known_parts = []
    if notes:
        known_parts.append(notes[:300])
    if website_context:
        known_parts.append(f"Website snippet: {website_context}")
    known = "\n".join(known_parts) or "No additional context available."

    # ── Geo-aware tone rules ──
    if geo == 'south_africa':
        tone_rules = """TONE: South African English. Casual, warm, direct. These words are welcome if they fit naturally: howzit, kak, hectic, sharp, sorted, bru, ou, eish, ja, no stress. Do not force them.
NEVER use "lekker" or "aweh". Do not use them anywhere.
Greeting: "Howzit {fname}," on its own line.""".format(fname=fname)
    elif geo == 'united_kingdom':
        tone_rules = f"""TONE: British English. Professional but warm, not stiff. No slang. No SA slang (no howzit, bru, eish, kak, etc). Natural and conversational, like a sharp colleague sending a note.
Greeting: "Hi {fname}," on its own line."""
    elif geo == 'united_states':
        tone_rules = f"""TONE: American English. Friendly, direct, no fluff. No slang from other regions. Natural and conversational, like someone you would grab a coffee with.
Greeting: "Hey {fname}," on its own line."""
    else:
        tone_rules = f"""TONE: Professional international English. Warm but not overly casual. No regional slang. Clear and human.
Greeting: "Hi {fname}," on its own line."""

    base_rules = f"""STRICT RULES. Violate any of these and the email fails.

NO hyphens or dashes anywhere. Not in the subject. Not in the body. Not ever. Not a single one.
NO corporate words: leverage, synergies, solutions, streamline, cutting edge, transform, innovative, seamless, empower, robust.
NO banned phrases: "I hope this finds you well", "I came across", "I wanted to reach out", "I noticed", "I stumbled", "touch base", "circle back", "following up", "checking in".
NO banned words: game changer, move the needle, best in class, deep dive, bandwidth, holistic, paradigm, synergy.
NO "Cheers," or any word before the sign off. Sign off is Alex on line 1, Amalfi AI on line 2. That is it. No "Warm regards", no "Best", no "Thanks". Just the two lines.
{tone_rules}
Subject line: short, human, no punchline, no exclamation marks, no capitalising every word.
Email body: max 100 words. Reads like a real person typed it on their phone. Casual. Not polished. Not a template.

Return EXACTLY this format with nothing before or after:
Subject: [subject line]
Body: [full email body including sign off]"""

    # ── Build vertical-specific value line ──
    value_line = ""
    if hook:
        value_line = f"\nVertical insight to weave in naturally (do NOT quote verbatim): {hook}"
    if vertical == 'industrial':
        value_line += "\nCTA variant: offer a 20 minute live demo instead of a free audit. SA industrial buyers expect technical validation early."
    if vertical == 'recruitment':
        value_line += "\nPosition as cost reduction, not new expense. They are already spending 10k+ ZAR on fragmented tools."

    if step == 1:
        return f"""You are Alex from Amalfi AI. Write a genuine first cold email to {fname} at {company}.

Context about {company}:
{known}
{value_line}

WHAT ALEX DOES: Alex works at Amalfi AI, an AI automation agency. We build AI systems that handle repetitive business operations — things like client communication pipelines, compliance reporting, invoicing flows, booking systems, outreach automation. Our clients typically reclaim 60 to 70 percent of their admin time within 90 days.

Write the email with this structure:

1. Greeting (see tone rules below).
2. One genuine, specific line about what {company} does — reference something REAL from the context above. Not generic praise. Name a product, a service, a market they are in. Show you actually looked.
3. Introduce what Amalfi does in ONE sentence. Be specific about what kind of automation is relevant to THEIR business based on the context. NOT vague "change in the tech industry" language. Name the operational problem you could solve for them. Example: "we build AI systems that handle [specific thing relevant to their business] so your team can focus on [what matters to them]."
4. One concrete outcome or proof point. A real number, a real result, a real reference. Not "pretty big ROI" — something tangible like "one of our clients went from 3 hours of daily admin to 20 minutes" or "we automated an entire invoicing pipeline handling 500 documents a month."
5. Honest qualifier: "not sure if this is a fit for you guys" energy. Genuinely low pressure.
6. Casual invite to a quick call or Loom (short recorded video). End with something warm before sign off.

The whole email should flow as one natural paragraph, maybe two short ones. Keep it tight.

{base_rules}"""

    elif step == 2:
        return f"""You are Alex from Amalfi AI. Second email to {fname} at {company}. First email got no reply.

Write a short follow up. Requirements:
1. Greeting (see tone rules below).
2. Acknowledge this is a follow up without using "just checking in" or "following up". Be self aware about cold outreach. Something honest like acknowledging nobody asked for this but you genuinely think there is something here.
3. Come from a DIFFERENT angle than the first email. If step 1 was about the operational problem, this one should be about a specific outcome or case study. Mention something concrete: "we just finished building [type of system] for a [similar type of company]" or "we helped a [vertical] company cut their [specific process] time by [real percentage]."
4. Offer a Loom (short recorded video) as an alternative to a call. Frame it casually: "even a 2 minute Loom might be easier than a call."
5. Keep it genuinely low pressure. No guilt.

Three to four sentences max. One short paragraph.

{base_rules}"""

    else:
        return f"""You are Alex from Amalfi AI. Third and last email to {fname} at {company}. Two emails, no reply.

Write the final touchpoint. This is the graceful close. Requirements:
1. Greeting (see tone rules below).
2. Amused energy, not bitter or desperate. You respect that they are busy or not interested. Something playful.
3. One line: you are not going to keep pushing.
4. Leave the door open. No expiry. Reach out whenever.

Two to three sentences max. Flows like a text.
Subject: something casual and short, lowercase.
Do NOT guilt trip. Do NOT say "I understand you must be busy."

{base_rules}"""


def generate_email(lead, step, website_context):
    prompt = build_prompt(lead, step, website_context)
    api_key = os.environ.get('OPENAI_API_KEY', '')
    model   = os.environ.get('OPENAI_MODEL', 'gpt-4o')
    if not api_key:
        raise ValueError("OPENAI_API_KEY not set")

    import urllib.request as _req
    payload = json.dumps({
        'model': model,
        'messages': [{'role': 'user', 'content': prompt}],
        'temperature': 0.8,
    }).encode()
    req = _req.Request(
        'https://api.openai.com/v1/chat/completions',
        data=payload,
        headers={'Authorization': f'Bearer {api_key}', 'Content-Type': 'application/json'},
    )
    with _req.urlopen(req, timeout=90) as resp:
        data = json.loads(resp.read())
    raw = data['choices'][0]['message']['content'].strip()
    if not raw:
        raise ValueError("Empty response from OpenAI")

    subject, body = '', ''
    for i, line in enumerate(raw.split('\n')):
        if line.startswith('Subject:') and not subject:
            subject = line[len('Subject:'):].strip()
        elif line.startswith('Body:') and not body:
            body = '\n'.join(raw.split('\n')[i:]).replace('Body:', '', 1).strip()
            break

    if not subject or not body:
        raise ValueError(f"Could not parse Subject/Body:\n{raw[:300]}")
    return subject, body


def send_email(to_email, subject, html_body, track=True):
    """Send via gog with --track (primary). Returns (msg_id, tracking_id)."""
    args = ['gog', 'gmail', 'send',
            '--account', FROM_ACCOUNT,
            '--to', to_email,
            '--subject', subject,
            '--body-html', html_body,
            '--json',
            '--no-input']
    if track:
        args.append('--track')
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"gog send failed: {result.stderr[:300]}")
    try:
        data = json.loads(result.stdout)
        msg_id      = data.get('messageId') or data.get('message_id') or data.get('gmail_message_id') or ''
        tracking_id = data.get('tracking_id') or ''
        return msg_id, tracking_id
    except Exception:
        return '', ''

# ── Pick the next lead (priority: step 3 > step 2 > step 1 highest-scored) ───

sent_count = 0
error_msg  = None
sent_to    = None
step_used  = None
score_used = None

try:
    # ── Step 3 candidates (contacted, steps 1+2 done, 9+ days since step 2) ──
    def try_step3():
        leads = supa_get("leads?status=eq.contacted&select=*&order=last_contacted_at.asc&limit=200&email_status=eq.valid")
        for lead in leads:
            logs = supa_get(f"outreach_log?lead_id=eq.{lead['id']}&select=step,sent_at&order=step.asc")
            if sorted(l['step'] for l in logs) != [1, 2]:
                continue
            if days_since(logs[-1]['sent_at']) < 9:
                continue
            return lead, 3
        return None, None

    # ── Step 2 candidates (contacted, step 1 done, 4+ days since step 1) ──
    def try_step2():
        leads = supa_get("leads?status=eq.contacted&select=*&order=last_contacted_at.asc&limit=200&email_status=eq.valid")
        for lead in leads:
            logs = supa_get(f"outreach_log?lead_id=eq.{lead['id']}&select=step,sent_at&order=step.asc")
            if [l['step'] for l in logs] != [1]:
                continue
            if days_since(logs[-1]['sent_at']) < 4:
                continue
            return lead, 2
        return None, None

    # ── Step 1: new leads sorted by score (highest first) ──
    def try_step1():
        # Fetch a generous batch, score them all, return the best
        # Skip leads flagged as invalid or risky by email verification
        candidates = supa_get("leads?status=eq.new&select=*&limit=500&order=created_at.asc&email_status=eq.valid")
        scored = []
        for lead in candidates:
            # Quick check: skip if already has a log entry (race condition guard)
            existing = supa_get(f"outreach_log?lead_id=eq.{lead['id']}&select=id&limit=1")
            if existing:
                continue
            s = score_lead(lead)
            scored.append((s, lead))
        if not scored:
            return None, None
        scored.sort(key=lambda x: -x[0])
        best_score, best_lead = scored[0]
        print(f"[score] Top lead: {best_lead.get('first_name')} @ {best_lead.get('company')} — score {best_score}")
        # Show top 3 for logging
        for sc, l in scored[:3]:
            print(f"  {sc:3d}  {l.get('first_name','')} {l.get('last_name','')} @ {l.get('company','')}")
        return best_lead, 1

    lead, step = try_step3()
    if not lead:
        lead, step = try_step2()
    if not lead:
        lead, step = try_step1()

    if not lead:
        print("[alex] No leads ready — queue empty or all capped.")
        sys.exit(0)

    lid     = lead['id']
    email   = lead.get('email', '')
    company = lead.get('company', '') or email
    fname   = lead.get('first_name', '')
    website = lead.get('website', '')

    vertical = detect_industry(lead)
    geo = detect_geo(lead)
    print(f"[alex] Step {step} → {email} ({company}) [vertical: {vertical}] [geo: {geo}]")

    # Research
    print(f"[alex] Fetching website context: {website or '(none)'}")
    ctx = research_website(website) if website else ""
    if ctx:
        print(f"[alex] Context: {ctx[:80]}...")

    # Generate
    print("[alex] Generating email...")
    subject, body = generate_email(lead, step, ctx)
    print(f"[alex] Subject: {subject}")

    # Build HTML body — three-layer open tracking:
    #   1. CF Worker pixel (via gog --track): catches Apple Mail, Thunderbird, direct loaders
    #   2. Vercel pixel (fallback): catches opens if CF Worker is down
    #   3. Tracked "Amalfi AI" link: catches Gmail/Outlook which block pixels but pass clicks
    log_id      = str(uuid.uuid4())
    fallback_px = f'{VERCEL_PIXEL_BASE}?id={log_id}'
    track_link  = f'{VERCEL_PIXEL_BASE}?id={log_id}&url=https://amalfiai.com'

    # Replace "Amalfi AI" sign-off with a tracked link (invisible styling, natural colour)
    import re as _re
    body_html = body.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('\n', '<br>')
    body_html = _re.sub(
        r'Amalfi AI',
        f'<a href="{track_link}" style="color:inherit;text-decoration:none;">Amalfi AI</a>',
        body_html,
        count=1,
    )

    html_body = (
        '<div style="font-family:Arial,sans-serif;font-size:14px;line-height:1.7;color:#111;">'
        + body_html
        + '</div>'
        + f'<img src="{fallback_px}" width="1" height="1" alt="" style="display:none;border:0;" />'
    )

    # Send — gog injects CF Worker pixel + returns tracking_id
    msg_id, tracking_id = send_email(email, subject, html_body, track=True)
    print(f"[alex] Sent ✓ (msg_id={msg_id or 'n/a'} tracking_id={tracking_id or 'n/a'})")

    # Log with pre-generated ID (matches fallback pixel) + CF tracking_id
    supa_post("outreach_log", {
        "id": log_id, "lead_id": lid, "step": step,
        "subject": subject, "body": body,
        "gmail_message_id": msg_id,
        "tracking_id": tracking_id or None,
    })

    # Update lead
    patch = {"last_contacted_at": now_utc_iso()}
    if step == 1:
        patch["status"] = "contacted"
    elif step == 3:
        patch["status"] = "sequence_complete"
    supa_patch(f"leads?id=eq.{lid}", patch)

    # Audit log
    supa_post("audit_log", {
        "agent": "Alex Claww", "action": "email_sent", "status": "success",
        "details": {"to": email, "company": company, "step": step,
                    "subject": subject, "warmup_cap": DAILY_CAP,
                    "sent_today": sent_today + 1},
    })

    sent_count = 1
    step_used  = step
    sent_to    = f"<b>{fname}</b> @ {company}"

except Exception as e:
    error_msg = str(e)
    print(f"[alex] ERROR: {e}", file=sys.stderr)
    try:
        supa_post("audit_log", {
            "agent": "Alex Claww", "action": "email_sent", "status": "failure",
            "details": {"error": str(e)[:400]},
        })
    except Exception:
        pass

# Telegram ping on send or error
if sent_count > 0:
    remaining = DAILY_CAP - sent_today - 1
    tg(
        f"📤 <b>Alex</b> — step {step_used} sent ({sent_today + 1}/{DAILY_CAP} today)\n"
        f"→ {sent_to}\n"
        f"<i>{subject}</i>\n"
        f"<code>{remaining} sends remaining today</code>"
    )
elif error_msg:
    tg(f"⚠️ <b>Alex outreach error</b>\n{error_msg[:200]}")

print(f"[alex] Done. Sent={sent_count} Cap={DAILY_CAP} Error={error_msg or 'none'}")
PY

# Update task status
if [[ -n "${TASK_ID:-}" ]]; then
    task_complete "$TASK_ID" "Alex outreach run complete"
fi

agent_checkout "worker-outreach-sender" "idle" "Done"
