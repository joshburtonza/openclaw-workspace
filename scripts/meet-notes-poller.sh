#!/bin/bash
# meet-notes-poller.sh
# Watches josh@amalfiai.com for Gemini Notes meeting emails.
# Fetches full transcript from Google Drive (email body is truncated).
# Runs Claude Opus analysis, sends Telegram debrief immediately.
# Also saves to research_sources for long-term intel pipeline.
# Runs every 15 min via LaunchAgent.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a
source "$WS/scripts/lib/task-helpers.sh"

LOG="$WS/out/meet-notes-poller.log"
SEEN_FILE="$WS/tmp/meet-notes-seen.txt"
mkdir -p "$WS/out" "$WS/tmp"

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; echo "[$(date '+%H:%M:%S')] $*"; }
log "=== Meet notes poller ==="
TASK_ID=$(task_create "Meet Notes Poller" "Scanning for new meeting notes" "meet-notes-poller" "normal")

KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
SALAH_CHAT_ID="${TELEGRAM_SALAH_CHAT_ID:-}"
SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
ACCOUNT="josh@amalfiai.com"

touch "$SEEN_FILE"

# ── Search for unread Gemini Notes emails ─────────────────────────────────────
# Gemini Notes emails contain a truncated summary; full transcript is on Google Drive.
# Read AI dropped — it only provides truncated summaries with no Drive equivalent.

EMAILS_JSON=$(gog gmail search \
  "from:gemini-notes@google.com is:unread" \
  --account "$ACCOUNT" \
  --json --results-only 2>/dev/null || echo "[]")

COUNT=$(echo "$EMAILS_JSON" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo "0")

if [[ "$COUNT" -eq 0 ]]; then
  log "No new meeting notes."
  exit 0
fi

log "Found $COUNT meeting note email(s). Processing..."

export EMAILS_JSON KEY SUPABASE_URL BOT_TOKEN CHAT_ID SALAH_CHAT_ID SEEN_FILE ACCOUNT WS

python3 - <<'PY'
import os, json, subprocess, urllib.request, urllib.error, datetime, re, tempfile

EMAILS_JSON  = os.environ['EMAILS_JSON']
KEY          = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID       = os.environ['CHAT_ID']
SALAH_CHAT_ID = os.environ.get('SALAH_CHAT_ID', '')
SEEN_FILE     = os.environ['SEEN_FILE']
ACCOUNT       = os.environ['ACCOUNT']
WS            = os.environ['WS']

emails = json.loads(EMAILS_JSON) if EMAILS_JSON.strip().startswith('[') else []

with open(SEEN_FILE) as f:
    seen = set(l.strip() for l in f if l.strip())

processed = 0

def _tg_send_one(chat_id, text):
    data = json.dumps({'chat_id': chat_id, 'text': text, 'parse_mode': 'Markdown'}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        data=data, headers={'Content-Type': 'application/json'}, method='POST'
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def tg_send(text):
    """Send to Josh and CC Salah on all meeting debriefs."""
    if not BOT_TOKEN or not CHAT_ID:
        return
    _tg_send_one(CHAT_ID, text)
    if SALAH_CHAT_ID:
        _tg_send_one(SALAH_CHAT_ID, text)

def call_claude(prompt, model):
    tmp = tempfile.NamedTemporaryFile(suffix='.txt', delete=False, mode='w')
    tmp.write(prompt)
    tmp.close()
    try:
        env = dict(os.environ)
        env.pop('CLAUDECODE', None)
        env.pop('CLAUDE_CODE', None)
        result = subprocess.run(
            ['claude', '--print', '--model', model, '--dangerously-skip-permissions'],
            stdin=open(tmp.name), capture_output=True, text=True, timeout=120, env=env
        )
        return result.stdout.strip() or ''
    except Exception as e:
        print(f"  [warn] Claude ({model}) call failed: {e}")
        return ''
    finally:
        os.unlink(tmp.name)

def call_openai(prompt, model='gpt-5.2', temperature=0.7):
    openai_key = os.environ.get('OPENAI_API_KEY', '')
    if not openai_key:
        return ''
    try:
        import urllib.request as _req
        # o3 and o-series models don't support temperature
        body = {'model': model, 'messages': [{'role': 'user', 'content': prompt}]}
        if not model.startswith('o'):
            body['temperature'] = temperature
        payload = json.dumps(body).encode()
        req = _req.Request(
            'https://api.openai.com/v1/chat/completions',
            data=payload,
            headers={'Authorization': f'Bearer {openai_key}',
                     'Content-Type': 'application/json'},
        )
        with _req.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
            return data['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f"  [warn] OpenAI ({model}) call failed: {e}")
        return ''

def claude_complete(system_prompt, user_content):
    return call_claude(f"{system_prompt}\n\n---\n\n{user_content}", 'claude-opus-4-6')

def extract_meeting_name(subject):
    gemini_match = re.match(r'^Notes:\s*"(.+?)"', subject)
    readai_match = re.match(r'^[^\w]*(.+?)\s+on\s+\w+\s+\d+', subject)
    if gemini_match:
        return gemini_match.group(1).strip()
    elif readai_match:
        return readai_match.group(1).strip()
    return subject

def clean_email_body(body):
    text = re.sub(r'<[^>]+>', ' ', body)
    text = re.sub(r'https?://\S+', '', text)
    text = re.sub(r'[\u200b\u00ad\ufeff]', '', text)
    text = re.sub(r'\s{3,}', '\n\n', text).strip()
    return text

def fetch_body(email_id, fallback):
    try:
        result = subprocess.run(
            ['gog', 'gmail', 'read', email_id, '--account', ACCOUNT, '--results-only'],
            capture_output=True, text=True, timeout=30
        )
        if result.stdout.strip():
            return result.stdout.strip()
    except Exception as e:
        print(f"  [warn] Could not fetch body for {email_id}: {e}")
    return fallback

def fetch_drive_transcript(meeting_name):
    """Search Google Drive for a Gemini Notes doc matching the meeting name and return full text."""
    try:
        result = subprocess.run(
            ['gog', 'drive', 'search', meeting_name, '--account', ACCOUNT,
             '--json', '--results-only'],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0 or not result.stdout.strip():
            return None
        files = json.loads(result.stdout)
        if isinstance(files, dict):
            files = files.get('files', [])
        # Find the Gemini Notes doc (Google Doc with "Notes by Gemini" in name)
        doc = next((
            f for f in files
            if f.get('mimeType') == 'application/vnd.google-apps.document'
            and 'Notes by Gemini' in f.get('name', '')
        ), None)
        if not doc:
            return None
        file_id = doc['file_id'] if 'file_id' in doc else doc.get('id','')
        if not file_id:
            return None
        dl = subprocess.run(
            ['gog', 'drive', 'download', file_id, '--account', ACCOUNT, '--format', 'txt'],
            capture_output=True, text=True, timeout=60
        )
        # gog outputs the saved path — find and read it
        for line in dl.stdout.splitlines():
            if line.startswith('path'):
                path = line.split('\t', 1)[-1].strip()
                with open(path) as f:
                    return f.read()
    except Exception as e:
        print(f"  [warn] Drive transcript fetch failed: {e}")
    return None

SYSTEM_PROMPT = """You are a sharp meeting intelligence analyst for Josh Burton, founder of Amalfi AI — an AI agency building AI operating systems for South African businesses.

Your job: give Josh a fast, honest, useful debrief he can act on immediately. He reads this on his phone.

TONE: Direct and conversational. Like a smart colleague who was in the room. Not a consultant's report.

FORMAT — use exactly this structure, plain Markdown, no extra headers:

📋 *[Meeting name]* — [type: Discovery/Progress/Delivery/Internal]
*With:* [names + companies]
*When:* [date/time]

*What happened:*
[3-5 tight sentences — what was actually discussed, not just topics listed]

*Decisions & agreements:*
[What was confirmed or moved. "Nothing concrete" if unclear]

*Action items:*
[🔴 Josh: specific thing]
[Other person: specific thing]

*Relationship read:*
[One honest paragraph — where does this relationship stand? Warm/cool/stalling/promising? Trust signals or red flags?]

*Watch out for:*
[1-3 specific concerns or follow-up items. Real risks, not generic warnings]

*Verdict:*
[One sentence. Honest read on what this meeting means for the business]

RULES:
- If the notes were truncated or cut off, say so at the very top: "⚠️ Notes were partial — debrief based on available content"
- If names/companies are unknown, say so rather than guessing
- Flag scope creep, compliance risk, or unclear priorities
- No padding, no "great session" filler, no corporate speak"""

CLIENT_KEYWORDS = {
    'ascend': 'qms-guard', 'qms': 'qms-guard', 'riaan': 'qms-guard',
    'favlog': 'favorite-flow', 'favorite': 'favorite-flow',
    'flair': 'favorite-flow', 'irshad': 'favorite-flow',
    'race technik': 'chrome-auto-care', 'farhaan': 'chrome-auto-care',
}
CLIENT_CONTEXT_PATHS = {
    'qms-guard':        f"{WS}/clients/qms-guard/CONTEXT.md",
    'favorite-flow':    f"{WS}/clients/favorite-flow-9637aff2/CONTEXT.md",
    'chrome-auto-care': f"{WS}/clients/chrome-auto-care/CONTEXT.md",
}

# ── Pass 1: group emails by normalised meeting name ────────────────────────
# Each group collects all email IDs + transcript chunks from every source
meetings = {}  # name_key -> {name, subjects, email_ids, senders, chunks}

for email in emails:
    email_id = email.get('id') or email.get('messageId', '')
    if not email_id or email_id in seen:
        continue

    subject = email.get('subject', '') or ''
    if any(skip in subject for skip in ['Weekly Kickoff', 'Weekly Summary', "won't generate", 'next meeting']):
        seen.add(email_id)
        continue

    sender = email.get('from', '')
    body   = fetch_body(email_id, email.get('body') or email.get('snippet', ''))

    if not body or len(body.strip()) < 100:
        print(f"  [skip] {subject} — body too short")
        seen.add(email_id)
        continue

    meeting_name = extract_meeting_name(subject)

    # For Gemini emails, try to pull the full transcript from Google Drive
    if 'gemini' in sender.lower() or 'google.com' in sender.lower():
        drive_text = fetch_drive_transcript(meeting_name)
        if drive_text and len(drive_text) > len(body):
            print(f"  [drive] Using full Drive transcript ({len(drive_text)} chars)")
            body = drive_text

    clean = clean_email_body(body)
    name_key = re.sub(r'\s+', ' ', meeting_name.lower().strip())

    if name_key not in meetings:
        meetings[name_key] = {
            'name':      meeting_name,
            'subjects':  [],
            'email_ids': [],
            'senders':   [],
            'chunks':    [],
        }

    meetings[name_key]['subjects'].append(subject)
    meetings[name_key]['email_ids'].append(email_id)
    meetings[name_key]['senders'].append(sender)
    meetings[name_key]['chunks'].append(clean)

# ── Pass 2: analyse each unique meeting with merged transcript ─────────────
for name_key, mtg in meetings.items():
    meeting_name = mtg['name']
    email_ids    = mtg['email_ids']
    subjects     = mtg['subjects']
    chunks       = mtg['chunks']
    sources      = mtg['senders']

    print(f"  Processing: {meeting_name} ({len(chunks)} source(s))")

    # Merge transcripts — label each source if more than one
    if len(chunks) == 1:
        merged_transcript = chunks[0][:12000]
    else:
        parts = []
        source_labels = ['Read AI' if 'read.ai' in s else 'Gemini Notes' if 'google' in s else s for s in sources]
        for label, chunk in zip(source_labels, chunks):
            parts.append(f"--- {label} ---\n{chunk[:6000]}")
        merged_transcript = '\n\n'.join(parts)

    # Detect client context from combined probe
    probe = (' '.join(subjects) + ' ' + merged_transcript[:500]).lower()
    client_key = next((v for k, v in CLIENT_KEYWORDS.items() if k in probe), None)
    client_context_section = ''
    if client_key:
        ctx_path = CLIENT_CONTEXT_PATHS.get(client_key, '')
        if ctx_path and os.path.exists(ctx_path):
            with open(ctx_path) as cf:
                client_context_section = f"\n## Client Context\n{cf.read()}\n"

    user_content = f"""## Meeting
{subjects[0]}
{client_context_section}
## Notes ({len(chunks)} source(s) combined)
{merged_transcript}"""

    # ── Step 1: Haiku — extract facts from transcript ─────────────────────────
    haiku_extract_prompt = f"""Extract a structured JSON summary from this meeting transcript. Return JSON only.
{{
  "attendees": ["names mentioned"],
  "decisions_made": ["list of concrete decisions"],
  "action_items": [{{"who": "name", "what": "task", "by_when": "date or null"}}],
  "numbers_mentioned": ["revenue, dates, percentages, budgets"],
  "blockers_raised": ["issues or concerns raised"],
  "sentiment_moments": ["notable emotional moments — positive or negative"],
  "open_questions": ["unresolved questions"],
  "next_meeting": "date or null"
}}

{user_content}"""

    extraction_raw = call_claude(haiku_extract_prompt, 'claude-haiku-4-5-20251001')
    extraction_clean = extraction_raw.strip()
    if extraction_clean.startswith('```'):
        extraction_clean = extraction_clean.split('\n', 1)[1].rsplit('```', 1)[0].strip()

    # ── Step 2: Opus — strategic analysis ─────────────────────────────────────
    opus_prompt = f"""{SYSTEM_PROMPT}

---

{user_content}

---

## Structured extraction (by Haiku)
{extraction_clean}

Provide your deep strategic analysis of this meeting."""

    opus_analysis = call_claude(opus_prompt, 'claude-opus-4-6')
    if not opus_analysis:
        opus_analysis = '(Opus analysis unavailable)'

    # ── Step 3: o3 — second opinion ───────────────────────────────────────────
    second_opinion_prompt = f"""Claude Opus has analysed a client meeting for an AI startup founder.

Meeting: {meeting_name}
Client context: {client_key or 'unknown'}

Opus concluded:
{opus_analysis}

Extracted facts:
{extraction_clean}

Review Opus's analysis as an independent model. What did it get right? What did it miss
or weight differently? Any risks or opportunities Opus didn't surface? 2 short paragraphs."""

    second_opinion = call_openai(second_opinion_prompt, model='o3')

    # ── Step 4: gpt-5.2 — write the final Telegram debrief ────────────────────
    debrief_prompt = f"""You are writing a post-meeting debrief for Josh Burton, founder of Amalfi AI.
Two AI models have analysed this meeting. Synthesise into a sharp, actionable Telegram message.

Rules:
- Address Josh directly ("you", "your")
- Lead with the most important thing he needs to know or do
- Where Opus and o3 agree, state it clearly
- Where they differ, briefly surface both
- Concrete action items with owners
- HTML bold for section headers
- Under 400 words. Punchy paragraphs, no bullet walls.

## Meeting: {meeting_name}
## Opus analysis
{opus_analysis}

## Second opinion (o3)
{second_opinion if second_opinion else '(unavailable — Opus analysis only)'}

## Extracted facts
{extraction_clean}

Write the debrief now."""

    analysis = call_openai(debrief_prompt, model='gpt-5.2', temperature=0.65)
    if not analysis:
        # Fallback to Opus-only if OpenAI failed
        analysis = opus_analysis or '_(Analysis unavailable)_'

    # ── Step 4b: plain-language version for Salah (non-technical co-founder) ──
    salah_debrief_prompt = f"""You are writing a post-meeting summary for Salah, co-founder of Amalfi AI.
Salah is NOT technical. He is a business partner who wants to know what happened in plain English.

Rules:
- Address Salah directly ("you", "your team")
- Zero technical jargon. No mention of APIs, repos, code, databases, deployments, or any developer terms.
- Focus only on: what the meeting was about, what the client needs, what was agreed, what happens next.
- Use plain business language a non-technical founder would use.
- Under 250 words. Short paragraphs.
- HTML bold for section headers.
- Never use hyphens. Use em dashes (—) or rephrase.

## Meeting: {meeting_name}
## What happened (from the analysis)
{analysis}

Write the plain-language summary for Salah now."""

    salah_analysis = call_openai(salah_debrief_prompt, model='gpt-5.2', temperature=0.65)
    if not salah_analysis:
        salah_analysis = analysis  # fallback to Josh's version

    # Send Josh's version to Josh only, Salah's version to Salah only
    def send_to_one(chat_id, text):
        if len(text) <= 4000:
            _tg_send_one(chat_id, text)
        else:
            chunks_out = []
            current = ''
            for para in text.split('\n\n'):
                if len(current) + len(para) + 2 > 3800:
                    if current:
                        chunks_out.append(current.strip())
                    current = para
                else:
                    current += ('\n\n' if current else '') + para
            if current:
                chunks_out.append(current.strip())
            for chunk in chunks_out:
                _tg_send_one(chat_id, chunk)

    if BOT_TOKEN and CHAT_ID:
        send_to_one(CHAT_ID, analysis)
    if BOT_TOKEN and SALAH_CHAT_ID:
        send_to_one(SALAH_CHAT_ID, salah_analysis)

    print(f"  [ok] Telegram debrief sent: {meeting_name}")

    # Save merged notes to research_sources (once per meeting)
    payload = {
        'title':       f"Meeting: {meeting_name}",
        'raw_content': f"Subject: {subjects[0]}\nSources: {', '.join(sources)}\n\n{merged_transcript[:10000]}",
        'status':      'pending',
        'metadata':    {
            'type':        'meeting_notes',
            'email_ids':   email_ids,
            'sources':     sources,
            'subject':     subjects[0],
            'ingested_at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        },
    }
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/research_sources",
        data=json.dumps(payload).encode(),
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
        method='POST',
    )
    try:
        urllib.request.urlopen(req, timeout=15)
    except Exception as e:
        print(f"  [warn] research_sources insert failed: {e}")

    # Log to interaction_log (adaptive memory)
    try:
        signal_payload = json.dumps({
            'actor': 'conductor',
            'user_id': client_key or 'unknown',
            'signal_type': 'meeting_analysed',
            'signal_data': {
                'meeting_name': meeting_name,
                'subject': subjects[0],
                'client_key': client_key,
                'sources': sources,
            },
        }).encode()
        sig_req = urllib.request.Request(
            f"{SUPABASE_URL}/rest/v1/interaction_log",
            data=signal_payload,
            headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                     'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
            method='POST',
        )
        urllib.request.urlopen(sig_req, timeout=5)
    except Exception:
        pass  # non-fatal

    # Mark all source emails as read
    for eid in email_ids:
        subprocess.run(
            ['gog', 'gmail', 'thread', 'modify', eid,
             '--account', ACCOUNT, '--remove=UNREAD', '--force'],
            capture_output=True, timeout=15
        )
        seen.add(eid)

    processed += 1

# Persist seen IDs
all_seen = list(seen)[-500:]
with open(SEEN_FILE, 'w') as f:
    f.write('\n'.join(all_seen))

print(f"Done — {processed} meeting(s) analysed.")
PY

task_complete "$TASK_ID" "Meet notes poller complete"
log "Meet notes poller complete."
