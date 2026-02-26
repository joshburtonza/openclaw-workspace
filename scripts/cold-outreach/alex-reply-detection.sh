#!/usr/bin/env bash
# alex-reply-detection.sh
# Polls alex@amalfiai.com for replies from contacted leads.
# Classifies each reply, then routes by intent:
#   VOICE_AI_LEAD       → same-day escalation to Josh (🎙️) + log
#   POSITIVE_INTERESTED → urgent Josh Telegram notification
#   UNSUBSCRIBE         → auto-suppress lead in Supabase + log
#   WANTS_MORE_INFO     → queue tailored follow-up draft
#   OBJECTION           → log for manual review + Telegram note
#   OUT_OF_OFFICE       → log only, no action
#   OTHER               → standard reply notification
# Runs every 2 hours via LaunchAgent.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="1140320036"
ACCOUNT="alex@amalfiai.com"
LOG="$WS/out/alex-reply-detection.log"

mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
source "$WS/scripts/lib/task-helpers.sh"

if [[ -z "$SUPABASE_KEY" ]]; then
    log "ERROR: SUPABASE_SERVICE_ROLE_KEY not set — cannot proceed"
    exit 1
fi

log "=== Reply detection run ==="

JOSH_CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
export SUPABASE_URL SUPABASE_KEY BOT_TOKEN CHAT_ID ACCOUNT WS JOSH_CHAT_ID

python3 - <<'PY'
import os, sys, json, re, subprocess, datetime, urllib.request, urllib.error, threading
from concurrent.futures import ThreadPoolExecutor

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SUPABASE_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
ACCOUNT      = os.environ['ACCOUNT']
WS           = os.environ['WS']
JOSH_CHAT_ID = os.environ.get('JOSH_CHAT_ID', '1140320036')

def supa_get(path):
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())

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

def tg(chat_id, text):
    if not BOT_TOKEN:
        return
    try:
        data = json.dumps({"chat_id": chat_id, "text": text, "parse_mode": "HTML"}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            data=data, headers={"Content-Type": "application/json"}, method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def log_signal(user_id, signal_type, signal_data=None):
    """Fire-and-forget: log a typed signal to interaction_log for adaptive memory."""
    try:
        data = json.dumps({
            'actor': 'alex',
            'user_id': user_id or 'unknown',
            'signal_type': signal_type,
            'signal_data': signal_data or {},
        }).encode()
        req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/interaction_log",
            data=data,
            headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                     'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
            method='POST',
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        pass  # never block the main flow

# ── Intent classification ───────────────────────────────────────────────────────

VOICE_AI_KEYWORDS = [
    'outbound', 'outbound calling', 'outbound calls', 'cold call', 'cold calling',
    'voice ai', 'voice agent', 'voice bot', 'voice automation', 'calling leads',
    'phone automation', 'phone ai', 'phone agent', 'phone outreach', 'phone leads',
    'lead gen', 'lead generation', 'lead qualifying', 'ai caller', 'ai calling',
    'autodial', 'auto dial', 'auto-dial', 'robocall', 'robo call',
    'call automation', 'automated calls', 'automated calling', 'automated dialing',
    'sales calls', 'calling prospects', 'prospect calling', 'dial leads',
    'conversational ai', 'conversational voice', 'voice prospecting',
    'phone prospecting', 'outreach calls', 'cold outreach calls',
]
POSITIVE_KEYWORDS = [
    'interested', 'sounds good', 'tell me more', 'love to', 'would like to',
    "let's chat", 'sounds interesting', 'yes please', 'book a call',
    'schedule a call', 'open to', 'happy to chat', 'worth a chat',
    'keen to', 'would love', 'want to learn', 'let me know more',
    'demo', 'show me', 'can you show', 'see it in action', 'how does it work',
    'walk me through', 'live demo', 'show how', 'demonstration', 'see your system',
    'see the system', 'see it work', 'show us how', 'watch it work', 'see a demo',
    'in action', 'show us', 'see how it',
]
WANTS_MORE_INFO_KEYWORDS = [
    'how much', 'pricing', 'what does it cost', 'case studies', 'examples',
    'what exactly', 'more information', 'more info', 'can you elaborate',
    'what services', 'what do you offer', 'your rates', 'cost of',
    'can you send', 'send me', 'brochure', 'details',
]
UNSUBSCRIBE_KEYWORDS = [
    'unsubscribe', 'remove me', 'stop emailing', 'opt out', 'not interested',
    'please remove', 'take me off', 'do not contact', "don't contact", "don't email",
    'stop contact', 'no thanks', 'not relevant', 'please stop',
]
OBJECTION_KEYWORDS = [
    'too expensive', 'not the right fit', 'already have', 'using another',
    'not a priority', 'no budget', 'not now', 'wrong time', 'bad time',
    'not in the market', "we're fine", 'we are fine', 'solved this',
    'not what we need', 'not for us', "won't work", 'will not work',
]
OUT_OF_OFFICE_KEYWORDS = [
    'out of office', 'out of the office', 'on leave', 'on holiday', 'on vacation',
    'away from the office', 'auto-reply', 'automatic reply', 'autoreply',
    'will be back', 'will return', 'i am away', "i'm away", 'currently away',
    'annual leave', 'maternity leave', 'paternity leave',
]

def classify_keywords(text):
    t = text.lower()
    if any(kw in t for kw in OUT_OF_OFFICE_KEYWORDS):
        return {"intent": "OUT_OF_OFFICE", "enthusiasm": None}
    if any(kw in t for kw in UNSUBSCRIBE_KEYWORDS):
        return {"intent": "UNSUBSCRIBE", "enthusiasm": None}
    if any(kw in t for kw in VOICE_AI_KEYWORDS):
        return {"intent": "VOICE_AI_LEAD", "enthusiasm": None}
    if any(kw in t for kw in OBJECTION_KEYWORDS):
        return {"intent": "OBJECTION", "enthusiasm": None}
    if any(kw in t for kw in POSITIVE_KEYWORDS):
        return {"intent": "POSITIVE_INTERESTED", "enthusiasm": None}
    if any(kw in t for kw in WANTS_MORE_INFO_KEYWORDS):
        return {"intent": "WANTS_MORE_INFO", "enthusiasm": None}
    return None

def classify_llm(text):
    prompt = (
        "Classify this cold email reply as exactly one of these labels:\n"
        "VOICE_AI_LEAD - mentions outbound calling, cold calling, voice AI, phone automation, lead gen/generation, or AI-driven phone/calling systems\n"
        "POSITIVE_INTERESTED - interested, wants a call, demo, or to learn more\n"
        "WANTS_MORE_INFO - asking for pricing, case studies, or more details before deciding\n"
        "UNSUBSCRIBE - wants to be removed from outreach / stop being contacted\n"
        "OBJECTION - pushback (wrong fit, bad timing, budget, already have a solution)\n"
        "OUT_OF_OFFICE - automated out-of-office or away message\n"
        "OTHER - cannot determine or does not fit above\n\n"
        "Also rate the enthusiasm level 1-5 where 1=lukewarm/polite, 5=ready to buy/very excited.\n\n"
        "Reply text:\n" + text[:500] + "\n\n"
        'Reply with ONLY valid JSON: {"intent": "LABEL", "enthusiasm": N}'
    )
    env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE')}
    try:
        r = subprocess.run(
            ['claude', '--print', '--model', 'claude-haiku-4-5-20251001'],
            input=prompt, capture_output=True, text=True, timeout=30, env=env,
        )
        result = json.loads(r.stdout.strip())
        valid = ('VOICE_AI_LEAD', 'POSITIVE_INTERESTED', 'WANTS_MORE_INFO', 'UNSUBSCRIBE',
                 'OBJECTION', 'OUT_OF_OFFICE', 'OTHER')
        intent = str(result.get('intent', '')).upper().replace(' ', '_')
        if intent not in valid:
            intent = 'OTHER'
        enthusiasm = result.get('enthusiasm')
        try:
            enthusiasm = int(enthusiasm)
            if enthusiasm < 1 or enthusiasm > 5:
                enthusiasm = None
        except (TypeError, ValueError):
            enthusiasm = None
        return {"intent": intent, "enthusiasm": enthusiasm}
    except Exception:
        return {"intent": "OTHER", "enthusiasm": None}

def classify_intent(text):
    result = classify_keywords(text)
    return result if result else classify_llm(text)

def get_reply_text(gog_output):
    """Fetch full email body via thread get; fall back to gog search snippet."""
    thread_ids = re.findall(r'thread_id:\s*(\S+)', gog_output, re.IGNORECASE)
    if not thread_ids:
        thread_ids = re.findall(r'\b([0-9a-f]{16,})\b', gog_output)
    if not thread_ids:
        return gog_output
    r = subprocess.run(
        ['gog', 'gmail', 'thread', 'get', thread_ids[0], '--account', ACCOUNT, '--plain'],
        capture_output=True, text=True, timeout=30,
    )
    if r.returncode == 0 and r.stdout.strip():
        body = r.stdout.strip()
        # Strip quoted history — only want latest reply
        for sep in [r'\n_{5,}\n', r'\nOn .*wrote:\n', r'\n-----Original Message-----\n']:
            body = re.split(sep, body, maxsplit=1)[0]
        return body.strip()
    return gog_output

def write_jsonl(filepath, record):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, 'a') as f:
        f.write(json.dumps(record) + '\n')

# ── Fetch contacted leads (not yet marked replied) ─────────────────────────────

leads = supa_get(
    "leads?status=in.(contacted,sequence_complete)"
    "&reply_received_at=is.null"
    "&select=id,first_name,last_name,email,company,status"
    "&limit=500"
)

if not leads:
    print("No contacted leads to check.")
    sys.exit(0)

print(f"Checking {len(leads)} leads for replies...")

voice_ai_replies  = []
positive_replies  = []
info_replies      = []
objection_replies = []
other_replies     = []
ts = now_utc()
lock = threading.Lock()

def process_lead(lead):
    email = (lead.get('email') or '').strip()
    if not email:
        return

    # Search alex's inbox for any email FROM this address
    result = subprocess.run(
        ['gog', 'gmail', 'search',
         f'from:{email}',
         '--account', ACCOUNT,
         '--max', '1'],
        capture_output=True, text=True, timeout=30,
    )

    if result.returncode != 0:
        return

    output = result.stdout.strip()
    if not output or 'no messages' in output.lower() or 'no results' in output.lower():
        return

    # Get full reply text and classify intent
    reply_text = get_reply_text(output)
    classified = classify_intent(reply_text)
    intent     = classified['intent']
    enthusiasm = classified['enthusiasm']
    print(f"  Reply from {email} — intent: {intent}, enthusiasm: {enthusiasm}")

    name    = f"{lead.get('first_name','')} {lead.get('last_name','') or ''}".strip()
    company = lead.get('company') or email
    entry   = {"name": name, "email": email, "company": company, "intent": intent,
                "enthusiasm": enthusiasm, "lead_id": lead['id'], "detected_at": ts}

    # ── Route by intent ────────────────────────────────────────────────────────

    if intent == 'UNSUBSCRIBE':
        # Auto-suppress: mark lead as unsubscribed so no further outreach fires
        try:
            supa_patch(f"leads?id=eq.{lead['id']}", {
                "status":            "unsubscribed",
                "reply_received_at": ts,
                "reply_sentiment":   intent,
            })
        except Exception as e:
            print(f"  [!] Supabase patch failed for {lead['id']}: {e}", file=sys.stderr)
            return
        log_signal(lead['id'], 'reply_received', {
            'intent': 'UNSUBSCRIBE', 'email': email, 'company': company, 'name': name,
        })
        with lock:
            write_jsonl(os.path.join(WS, 'tmp', 'unsubscribes.jsonl'), entry)
        print(f"  → Auto-suppressed {email} from sequence")
        # Brief Telegram note so Josh knows (no action needed, just awareness)
        tg(CHAT_ID, f"🚫 <b>Unsubscribe</b> — {name} @ {company} removed from sequence.")
        return

    # All other intents: mark as replied
    sentiment = f"{intent}:{enthusiasm}" if enthusiasm is not None else intent
    try:
        supa_patch(f"leads?id=eq.{lead['id']}", {
            "status":            "replied",
            "reply_received_at": ts,
            "reply_sentiment":   sentiment,
        })
    except Exception as e:
        print(f"  [!] Supabase patch failed for {lead['id']}: {e}", file=sys.stderr)
        return

    # Log base signal + specific intent signals to interaction_log
    log_signal(lead['id'], 'reply_received', {
        'intent': intent, 'enthusiasm': enthusiasm, 'email': email,
        'company': company, 'name': name,
    })
    if intent in ('POSITIVE_INTERESTED', 'VOICE_AI_LEAD'):
        log_signal(lead['id'], 'reply_positive', {
            'enthusiasm': enthusiasm, 'email': email, 'company': company,
            'category': 'voice_ai' if intent == 'VOICE_AI_LEAD' else 'interested',
        })
    elif intent == 'OBJECTION':
        log_signal(lead['id'], 'reply_objection', {'email': email, 'company': company})

    with lock:
        if intent == 'VOICE_AI_LEAD':
            voice_ai_replies.append(entry)
            write_jsonl(os.path.join(WS, 'tmp', 'voice-ai-leads.jsonl'), entry)

        elif intent == 'POSITIVE_INTERESTED':
            positive_replies.append(entry)

        elif intent == 'WANTS_MORE_INFO':
            info_replies.append(entry)
            write_jsonl(os.path.join(WS, 'tmp', 'followup-drafts-queue.jsonl'),
                        {**entry, "action": "draft_tailored_followup"})

        elif intent == 'OBJECTION':
            objection_replies.append(entry)
            write_jsonl(os.path.join(WS, 'tmp', 'objections-review.jsonl'), entry)

        elif intent == 'OUT_OF_OFFICE':
            # Log only — lead is still contactable later, no status change needed
            write_jsonl(os.path.join(WS, 'tmp', 'out-of-office.jsonl'), entry)
            print(f"  → OOO logged for {email}, no action taken")

        else:  # OTHER
            other_replies.append(entry)

with ThreadPoolExecutor(max_workers=10) as executor:
    executor.map(process_lead, leads)

# ── VOICE_AI_LEAD — same-day escalation to Josh ───────────────────────────────

if voice_ai_replies:
    count = len(voice_ai_replies)
    lines = [f"🎙️ <b>VOICE AI LEAD{'S' if count > 1 else ''} — {count} inbound signal{'s' if count > 1 else ''}! Respond same-day.</b>\n"]
    for r in voice_ai_replies:
        lines.append(f"• <b>{r['name']}</b> @ {r['company']} ({r['email']})")
    lines.append(
        "\n⚡ Early-mover window is NOW — these leads mentioned outbound calling, "
        "voice AI, or phone automation. Tag: voice_ai_lead. "
        "Open Mission Control → Alex CRM to action immediately."
    )
    msg = "\n".join(lines)
    tg(JOSH_CHAT_ID, msg)
    if JOSH_CHAT_ID != CHAT_ID:
        tg(CHAT_ID, msg)

# ── POSITIVE_INTERESTED — urgent Josh notification ─────────────────────────────

if positive_replies:
    count = len(positive_replies)
    lines = [f"🔥 <b>HIGH PRIORITY — {count} interested lead{'s' if count > 1 else ''}!</b>\n"]
    for r in positive_replies:
        enthusiasm = r.get('enthusiasm')
        score_str = f" — score: {enthusiasm}/5" if enthusiasm is not None else ""
        fire = " 🔥" if enthusiasm is not None and enthusiasm >= 4 else ""
        lines.append(f"• <b>{r['name']}</b> @ {r['company']}{score_str}{fire}")
    lines.append(
        "\n⚡ These leads are warm — follow up within the hour. "
        "Open Mission Control → Alex CRM to action."
    )
    msg = "\n".join(lines)
    tg(JOSH_CHAT_ID, msg)
    if JOSH_CHAT_ID != CHAT_ID:
        tg(CHAT_ID, msg)

# ── WANTS_MORE_INFO — queued follow-up drafts notification ────────────────────

if info_replies:
    count = len(info_replies)
    lines = [f"📋 <b>{count} lead{'s' if count > 1 else ''} want{'s' if count == 1 else ''} more info — follow-up draft queued</b>\n"]
    for r in info_replies:
        lines.append(f"• <b>{r['name']}</b> @ {r['company']} ({r['email']})")
    lines.append(
        "\n📁 Tailored follow-up drafts queued in tmp/followup-drafts-queue.jsonl"
    )
    tg(CHAT_ID, "\n".join(lines))

# ── OBJECTION — manual review alert ──────────────────────────────────────────

if objection_replies:
    count = len(objection_replies)
    lines = [f"⚠️ <b>{count} objection repl{'ies' if count > 1 else 'y'} — manual review needed</b>\n"]
    for r in objection_replies:
        lines.append(f"• <b>{r['name']}</b> @ {r['company']} ({r['email']})")
    lines.append(
        "\n📁 Logged to tmp/objections-review.jsonl — review and decide whether to re-engage."
    )
    tg(CHAT_ID, "\n".join(lines))

# ── OTHER — standard reply notification ───────────────────────────────────────

if other_replies:
    count = len(other_replies)
    lines = [f"📥 <b>Alex — {count} new repl{'ies' if count > 1 else 'y'} (unclassified)</b>\n"]
    for r in other_replies:
        lines.append(f"• <b>{r['name']}</b> @ {r['company']} ({r['email']})")
    lines.append("\nOpen Mission Control → Alex CRM to review and qualify.")
    tg(CHAT_ID, "\n".join(lines))

total = len(voice_ai_replies) + len(positive_replies) + len(info_replies) + len(objection_replies) + len(other_replies)
print(
    f"Done. New replies: {total} "
    f"({len(voice_ai_replies)} VOICE_AI_LEAD, "
    f"{len(positive_replies)} POSITIVE_INTERESTED, "
    f"{len(info_replies)} WANTS_MORE_INFO, "
    f"{len(objection_replies)} OBJECTION, "
    f"{len(other_replies)} OTHER)"
)
PY
