#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# analyse-leads.sh
# AI-powered lead scoring for the AOS CRM.
#
# For each lead, Claude Sonnet analyses all available data (enrichment,
# website content, LinkedIn, business profile) and scores them 0-100 for
# fit with Amalfi AI services. Results stored in ai_analysis (JSONB),
# ai_score, ai_analysed_at on the leads table.
#
# Usage:
#   bash analyse-leads.sh                  → process pending task_queue items
#   bash analyse-leads.sh --lead <id>      → analyse one lead by ID
#   bash analyse-leads.sh --all            → analyse all unscored leads
#   bash analyse-leads.sh --all --limit 20 → batch of 20
#   bash analyse-leads.sh --rerun          → reanalyse all (overwrite existing)
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"

LOG="$WS/out/analyse-leads.log"
mkdir -p "$WS/out"

# Pass all args as single env var
SCRIPT_ARGS="${*:-}"
export SUPABASE_URL KEY BOT_TOKEN CHAT_ID LOG WS SCRIPT_ARGS

python3 << 'PY'
import json, os, sys, re, subprocess, urllib.request, urllib.parse, datetime, time, html

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
LOG_PATH     = os.environ['LOG']
WS           = os.environ['WS']
ARGS         = os.environ.get('SCRIPT_ARGS', '').split()

# ── Parse args ─────────────────────────────────────────────────────────────

MODE       = 'queue'   # queue | single | all | rerun
LEAD_ID    = None
LIMIT      = 10

i = 0
while i < len(ARGS):
    a = ARGS[i]
    if a == '--lead' and i + 1 < len(ARGS):
        MODE = 'single'; LEAD_ID = ARGS[i+1]; i += 2
    elif a == '--all':
        MODE = 'all'; i += 1
    elif a == '--rerun':
        MODE = 'rerun'; i += 1
    elif a == '--limit' and i + 1 < len(ARGS):
        LIMIT = int(ARGS[i+1]); i += 2
    else:
        i += 1

# ── Helpers ────────────────────────────────────────────────────────────────

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
        log(f'supa_get failed ({path[:80]}): {e}')
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

def supa_post(path, data):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    payload = json.dumps(data).encode()
    req = urllib.request.Request(url, data=payload, method='POST', headers={
        'apikey': KEY, 'Authorization': f'Bearer {KEY}',
        'Content-Type': 'application/json', 'Prefer': 'return=minimal'
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r: return r.status
    except Exception as e:
        log(f'supa_post failed: {e}')
        return 0

def fetch_website(url, timeout=8):
    """Scrape and clean website text, return first 2500 chars."""
    if not url:
        return ''
    if not url.startswith('http'):
        url = 'https://' + url
    try:
        req = urllib.request.Request(
            url,
            headers={
                'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
                'Accept': 'text/html,application/xhtml+xml',
            }
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(80000).decode('utf-8', errors='ignore')
        # Strip scripts, styles, then tags
        raw = re.sub(r'<script[^>]*>.*?</script>', ' ', raw, flags=re.DOTALL | re.IGNORECASE)
        raw = re.sub(r'<style[^>]*>.*?</style>', ' ', raw, flags=re.DOTALL | re.IGNORECASE)
        raw = re.sub(r'<[^>]+>', ' ', raw)
        raw = html.unescape(raw)
        raw = ' '.join(raw.split())
        return raw[:2500]
    except Exception as e:
        log(f'  website fetch failed ({url[:60]}): {e}')
        return ''

def call_claude(prompt):
    """Call Claude Sonnet, return raw stdout."""
    env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE')}
    try:
        r = subprocess.run(
            ['claude', '--print', '--model', 'claude-sonnet-4-6'],
            input=prompt, capture_output=True, text=True, timeout=60, env=env,
        )
        return r.stdout.strip()
    except Exception as e:
        log(f'  claude call failed: {e}')
        return ''

def extract_json(text):
    """Extract first JSON object from Claude output (may have markdown fences)."""
    # Try bare JSON first
    text = text.strip()
    if text.startswith('{'):
        try: return json.loads(text)
        except: pass
    # Strip markdown code fences
    m = re.search(r'```(?:json)?\s*(\{.*?\})\s*```', text, re.DOTALL)
    if m:
        try: return json.loads(m.group(1))
        except: pass
    # Find first { ... } block
    m = re.search(r'\{.*\}', text, re.DOTALL)
    if m:
        try: return json.loads(m.group(0))
        except: pass
    return None

def parse_notes_field(notes):
    """Extract enrichment from legacy notes blob."""
    if not notes:
        return {}
    def get(key):
        m = re.search(rf'^{re.escape(key)}:\s*(.+)$', notes, re.MULTILINE | re.IGNORECASE)
        return m.group(1).strip() if m else None
    return {
        'location': get('Location'),
        'industry':  get('Industry'),
        'employees': get('Employees'),
        'linkedin':  get('LinkedIn'),
        'title':     get('Title'),
    }

def analyse_lead(lead):
    """Run Claude analysis on a single lead dict. Returns (analysis_json, score)."""
    first   = lead.get('first_name', '')
    last    = lead.get('last_name', '') or ''
    title   = lead.get('title', '') or ''
    company = lead.get('company', '') or ''
    email   = lead.get('email', '')
    website = lead.get('website', '') or ''
    linkedin = lead.get('linkedin_url', '') or ''
    industry = lead.get('industry', '') or ''
    emp     = lead.get('employee_count')
    loc_city = lead.get('location_city', '') or ''
    loc_country = lead.get('location_country', '') or ''
    source  = lead.get('source', '') or ''
    notes   = lead.get('notes', '') or ''
    q_score = lead.get('quality_score') or 0

    # Fill blanks from legacy notes blob
    nb = parse_notes_field(notes)
    if not title    and nb.get('title'):    title    = nb['title']
    if not industry and nb.get('industry'): industry = nb['industry']
    if not linkedin and nb.get('linkedin'): linkedin = nb['linkedin']
    if not emp      and nb.get('employees'):
        try: emp = int(nb['employees'])
        except: pass
    if not loc_city and nb.get('location'):
        parts = nb['location'].split(',')
        if len(parts) >= 2:
            loc_city    = parts[0].strip()
            loc_country = parts[-1].strip()
        else:
            loc_city = nb['location']

    location_str = ', '.join(filter(None, [loc_city, loc_country]))
    emp_str = f'{emp} employees' if emp else 'Unknown size'

    log(f'  Fetching website: {website or "(none)"}')
    web_content = fetch_website(website) if website else ''
    web_summary = web_content[:2000] if web_content else 'Not available'

    prompt = f"""You are a senior sales intelligence analyst at Amalfi AI — a specialist AI agency that helps SMBs automate their operations, lead generation, outreach, meeting intelligence, and data workflows using custom AI agents.

Our ideal client:
- SMB with 10–500 employees, ideally in South Africa, UK, Australia, or any English-speaking market
- Decision maker: Founder, CEO, MD, Director, Head of Sales/Marketing/Ops, CTO
- Industry: professional services, technology, marketing agencies, e-commerce, logistics, finance, real estate, recruitment
- Pain points: manual admin, slow lead gen, inefficient follow-up, data scattered across tools
- Budget indicator: established business, active web presence, growing team

Analyse this CRM lead and score their fit as a potential Amalfi AI client.

LEAD DETAILS:
Name: {first} {last}
Title: {title or 'Unknown'}
Company: {company or 'Unknown'}
Industry: {industry or 'Unknown'}
Size: {emp_str}
Location: {location_str or 'Unknown'}
Email: {email}
LinkedIn: {linkedin or 'Not available'}
Website: {website or 'Not available'}
Source: {source or 'Unknown'}
Existing quality score: {q_score}/100

WEBSITE CONTENT:
{web_summary}

SCORING GUIDE (0–100):
90–100 = Dream client: decision maker, established business, clear AI automation needs, right size
70–89  = Strong fit: decision maker or close, relevant industry, some signals of automation need
50–69  = Moderate fit: right industry but unclear seniority, or junior title but growing company
30–49  = Weak fit: wrong industry, very small, or no signals of budget/need
0–29   = Poor fit: student, freelancer, wrong geography, or clearly not a buyer

OUTPUT: Return ONLY valid JSON, no markdown, no explanation:
{{
  "score": <integer 0-100>,
  "headline": "<one punchy sentence: seniority + company + key signal>",
  "fit_summary": "<2-3 sentences on why they are or aren't a fit, referencing specific details>",
  "opportunities": ["<specific AI use case 1>", "<specific AI use case 2>", "<specific AI use case 3>"],
  "risks": ["<concern 1>", "<concern 2 if any>"],
  "next_action": "<specific, personalised outreach angle based on their business>"
}}"""

    log(f'  Calling Claude...')
    raw = call_claude(prompt)
    if not raw:
        return None, None

    parsed = extract_json(raw)
    if not parsed:
        log(f'  Could not parse JSON from Claude output: {raw[:200]}')
        return None, None

    score = parsed.get('score')
    try:
        score = max(0, min(100, int(score)))
        parsed['score'] = score
    except (TypeError, ValueError):
        score = None

    return parsed, score

# ── Fetch leads ────────────────────────────────────────────────────────────

def get_leads_to_process():
    if MODE == 'single':
        rows = supa_get(f'leads?id=eq.{LEAD_ID}&select=*')
        return rows if rows else []
    elif MODE == 'queue':
        # Process pending task_queue items
        tasks = supa_get(
            f"task_queue?task_type=eq.analyse_crm_lead&status=eq.pending&select=*&order=created_at.asc&limit={LIMIT}"
        )
        if not tasks:
            log('No pending analyse_crm_lead tasks in queue.')
            return []
        lead_ids = [t.get('payload', {}).get('lead_id') for t in tasks if t.get('payload', {}).get('lead_id')]
        # Mark tasks as in_progress
        for t in tasks:
            supa_patch(f"task_queue?id=eq.{t['id']}", {'status': 'in_progress'})
        if not lead_ids:
            return []
        ids_filter = ','.join(f'"{lid}"' if '-' in lid else lid for lid in lead_ids)
        rows = supa_get(f'leads?id=in.({",".join(lead_ids)})&select=*')
        return rows
    elif MODE == 'rerun':
        return supa_get(f'leads?select=*&order=created_at.desc&limit={LIMIT}')
    else:
        # MODE == 'all': only unscored leads
        return supa_get(f'leads?ai_analysed_at=is.null&select=*&order=created_at.desc&limit={LIMIT}')

# ── Main ───────────────────────────────────────────────────────────────────

leads = get_leads_to_process()
if not leads:
    log('No leads to process.')
    sys.exit(0)

log(f'Analysing {len(leads)} lead(s) — mode={MODE}')
done = 0
errors = 0

for lead in leads:
    lead_id = lead.get('id')
    name = f"{lead.get('first_name','')} {lead.get('last_name','') or ''}".strip()
    company = lead.get('company', '') or ''
    label = f"{name} @ {company}" if company else name

    log(f'[{done+1}/{len(leads)}] {label}')

    analysis, score = analyse_lead(lead)
    if analysis is None:
        log(f'  FAILED — skipping')
        errors += 1
        # Mark task failed if in queue mode
        if MODE == 'queue':
            tasks = supa_get(f"task_queue?task_type=eq.analyse_crm_lead&status=eq.in_progress&select=id")
            # best effort — just log
        continue

    update = {
        'ai_analysis':    analysis,
        'ai_score':       score,
        'ai_analysed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    status = supa_patch(f'leads?id=eq.{lead_id}', update)
    if status in (200, 204):
        log(f'  Score: {score} — "{analysis.get("headline","")}"')
        done += 1
    else:
        log(f'  Supabase update failed (status {status})')
        errors += 1

    # Mark task_queue done
    if MODE == 'queue':
        tasks = supa_get(f"task_queue?task_type=eq.analyse_crm_lead&status=eq.in_progress&select=id&limit=1")
        for t in tasks:
            supa_patch(f"task_queue?id=eq.{t['id']}", {'status': 'done', 'completed_at': datetime.datetime.now(datetime.timezone.utc).isoformat()})

    time.sleep(1)  # Avoid hammering Claude

log(f'Done. {done} analysed, {errors} errors.')

if done > 0:
    tg(
        f'<b>AOS Lead Analysis Complete</b>\n'
        f'Analysed {done} lead(s), {errors} error(s).\n'
        f'Check the CRM for AI scores.'
    )
PY
