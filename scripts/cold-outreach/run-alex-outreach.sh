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
import os, sys, json, subprocess, datetime, time, re
import urllib.request, urllib.error
from html.parser import HTMLParser

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

OUTCOME_HOOKS = {
    'recruitment':    'CV screening in under 30 seconds',
    'legal_property': 'contract intake processed without manual triage',
    'logistics':      'booking and dispatch flow without the back-and-forth',
}

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
    fname    = lead.get('first_name', 'there')
    lname    = lead.get('last_name', '') or ''
    company  = lead.get('company', '') or 'your company'
    notes    = lead.get('notes', '') or ''
    source   = lead.get('source', '')
    is_person = source == 'linkedin'

    industry = detect_industry(lead)
    hook     = OUTCOME_HOOKS.get(industry, '')

    known_parts = []
    if notes:
        known_parts.append(notes[:300])
    if website_context:
        known_parts.append(f"Website content: {website_context}")
    known = "\n".join(known_parts) or "No additional context available."

    base_rules = """STRICT RULES — violating any of these means the email fails:
- NO hyphens or dashes anywhere. Not in subject lines. Not in the body. Not ever.
- NO corporate or marketing language. No "leverage", "synergies", "solutions", "streamline", "cutting-edge", "transform".
- NO cliched openers. Not "I hope this finds you well", "I came across your company", "I wanted to reach out", "I noticed", "I stumbled upon".
- NO AI-sounding phrases. No "In today's fast-paced world", "In an era of", "It's no secret that".
- Subject line must sound like a human typed it fast. Short. No punchline. No exclamation marks.
- Body must read like a real email from a real person who spent 10 minutes on your website. Casual but smart.
- South African English.
- Sign off: Alex, Amalfi AI (on two separate lines, no pipe symbol, no hyphens)

Return EXACTLY this format with nothing before or after:
Subject: [subject line]
Body: [full email body including sign-off]"""

    if step == 1:
        intro_style = (
            f"You are writing to {fname} {lname}".strip() + (f", who works at {company}" if company else "") + "."
            if is_person else
            f"You are writing to whoever handles decisions at {company}."
        )
        specificity_note = (
            f"Reference something concrete and specific about {fname}'s role or {company} from the context. Not a compliment. An observation that shows you actually looked."
            if is_person else
            f"Reference something specific about {company} from the context that shows you actually looked at them."
        )
        vertical_instruction = (
            f"\n3b. Before moving to the audit offer, drop in one concrete outcome example "
            f"specific to their industry — one sentence, natural, not a bullet. "
            f"Adapt this reference (do not copy verbatim): \"{hook}\""
        ) if hook else ""

        return f"""You are Alex. You run Amalfi AI, a small AI agency in South Africa. You build AI agents that take over repetitive work for growing businesses: inbox management, lead follow up, content, admin ops. Your clients are small to mid size companies that want to move faster without hiring.

{intro_style}

Context about them:
{known}

Write a first cold outreach email. Here is exactly what it needs to do:

1. Open with "Hey {fname}," on its own line.
2. Write 1 to 2 sentences that show you actually looked at them. Be specific. Reference their actual work or situation, not just their industry. Do not compliment them. Just show you understand what they are dealing with.
3. Introduce yourself naturally: "I run Amalfi AI" and in one plain sentence say what you actually do and why it is relevant to their situation specifically.{vertical_instruction}
4. Offer the free audit: Tell them you do free AI audits where you look at their actual workflow, find where they are losing time and money, and come back with a plain English breakdown of what could be automated. Make clear there is no pitch, no commitment. You just look and report back.
5. Close with one simple question or invitation. Not "would love to chat". Something natural like asking if they would want to do one, or if it is worth a quick conversation.

{specificity_note}

{base_rules}"""

    elif step == 2:
        return f"""You are Alex from Amalfi AI. You sent {fname} at {company} an email 4 days ago about a free AI audit offer. No reply.

Context about them:
{known}

Write a short follow up. Rules for this one specifically:
- Do NOT say "just following up", "checking in", "circling back", or "wanted to resurface this".
- Open with "Hey {fname}," on its own line.
- Come at it from a slightly different angle. Pick something new from the context to lead with, or acknowledge that inboxes are chaos and keep it brief.
- Remind them the free audit is still on the table. Keep it one sentence.
- 3 sentences total in the body max.
- Close naturally. Not "let me know". Something human.

{base_rules}"""

    else:
        return f"""You are Alex from Amalfi AI. This is your third and last email to {fname} at {company}. Two emails, no reply.

Write a short graceful close. Rules:
- Open with "Hey {fname}," on its own line.
- 2 sentences in the body. That is it.
- First sentence: acknowledge timing might just be off and that is fine.
- Second sentence: leave the door open. Something like telling them the free audit offer does not expire and they can come back whenever.
- No guilt. No passive aggression. No "I understand you must be busy."
- Warm and genuine. Like a real person who is not desperate.

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


def send_email(to_email, subject, body):
    result = subprocess.run(
        ['gog', 'gmail', 'send',
         '--account', FROM_ACCOUNT,
         '--to', to_email,
         '--subject', subject,
         '--body', body,
         '--no-input'],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"gog send failed: {result.stderr[:300]}")
    msg_id = ''
    for line in result.stdout.split('\n'):
        if 'message' in line.lower() and 'id' in line.lower():
            parts = line.split()
            if parts:
                msg_id = parts[-1].strip()
            break
    return msg_id

# ── Pick the next lead (priority: step 3 > step 2 > step 1 highest-scored) ───

sent_count = 0
error_msg  = None
sent_to    = None
step_used  = None
score_used = None

try:
    # ── Step 3 candidates (contacted, steps 1+2 done, 9+ days since step 2) ──
    def try_step3():
        leads = supa_get("leads?status=eq.contacted&select=*&order=last_contacted_at.asc&limit=200&email_status=not.in.(invalid,risky)")
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
        leads = supa_get("leads?status=eq.contacted&select=*&order=last_contacted_at.asc&limit=200&email_status=not.in.(invalid,risky)")
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
        candidates = supa_get("leads?status=eq.new&select=*&limit=500&order=created_at.asc&email_status=not.in.(invalid,risky)")
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
    print(f"[alex] Step {step} → {email} ({company}) [vertical: {vertical}]")

    # Research
    print(f"[alex] Fetching website context: {website or '(none)'}")
    ctx = research_website(website) if website else ""
    if ctx:
        print(f"[alex] Context: {ctx[:80]}...")

    # Generate
    print("[alex] Generating email...")
    subject, body = generate_email(lead, step, ctx)
    print(f"[alex] Subject: {subject}")

    # Send
    msg_id = send_email(email, subject, body)
    print(f"[alex] Sent ✓ (msg_id={msg_id or 'n/a'})")

    # Log
    supa_post("outreach_log", {
        "lead_id": lid, "step": step,
        "subject": subject, "body": body,
        "gmail_message_id": msg_id,
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
