#!/usr/bin/env bash
# weekly-memory-digest.sh
# Runs every Sunday at 09:00 SAST.
# Queries interaction_log + user_models + agent_memory → builds a "what the system
# has learned about you this week" report and sends to Josh on Telegram.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
LOG="$WS/out/weekly-memory-digest.log"
GPT_MODEL="gpt-4o"

mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

if [[ -z "$KEY" ]]; then log "ERROR: SUPABASE_SERVICE_ROLE_KEY not set"; exit 1; fi

log "=== Weekly memory digest ==="

export KEY SUPABASE_URL BOT_TOKEN CHAT_ID WS GPT_MODEL

python3 - <<'PY'
import os, json, datetime, urllib.request, subprocess, tempfile, sys

KEY          = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
BOT_TOKEN    = os.environ.get('BOT_TOKEN', '')
CHAT_ID      = os.environ.get('CHAT_ID', '1140320036')
OPENAI_KEY   = os.environ.get('OPENAI_API_KEY', '')

# ── Model helpers ─────────────────────────────────────────────────────────────

def call_claude(prompt, model):
    """Call a Claude model via CLI. Returns text output."""
    env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE')}
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, prefix='/tmp/wmd-')
    tmp.write(prompt)
    tmp.close()
    try:
        r = subprocess.run(
            ['claude', '--print', '--model', model, '--dangerously-skip-permissions'],
            stdin=open(tmp.name), capture_output=True, text=True, timeout=120, env=env,
        )
        return r.stdout.strip()
    except Exception as e:
        print(f"  [warn] Claude ({model}) call failed: {e}", file=sys.stderr)
        return ''
    finally:
        os.unlink(tmp.name)

def call_openai(prompt, model='gpt-5.2', temperature=0.7):
    """Call OpenAI API with specified model. Returns text output."""
    if not OPENAI_KEY:
        return ''
    try:
        body = {'model': model, 'messages': [{'role': 'user', 'content': prompt}]}
        if not model.startswith('o'):
            body['temperature'] = temperature
        payload = json.dumps(body).encode()
        req = urllib.request.Request(
            'https://api.openai.com/v1/chat/completions',
            data=payload,
            headers={'Authorization': f'Bearer {OPENAI_KEY}',
                     'Content-Type': 'application/json'},
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read())
            return data['choices'][0]['message']['content'].strip()
    except Exception as e:
        print(f"  [warn] OpenAI ({model}) call failed: {e}", file=sys.stderr)
        return ''

now     = datetime.datetime.now(datetime.timezone.utc)
week_ago = (now - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')

def supa_get(path):
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"  [warn] supa_get {path}: {e}", file=sys.stderr)
        return []

def tg(text):
    if not BOT_TOKEN:
        return
    # Split if over Telegram limit
    chunks = []
    current = ''
    for para in text.split('\n\n'):
        if len(current) + len(para) + 2 > 3800:
            if current:
                chunks.append(current.strip())
            current = para
        else:
            current += ('\n\n' if current else '') + para
    if current:
        chunks.append(current.strip())
    for chunk in chunks:
        try:
            data = json.dumps({'chat_id': CHAT_ID, 'text': chunk, 'parse_mode': 'HTML'}).encode()
            req = urllib.request.Request(
                f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
                data=data, headers={'Content-Type': 'application/json'}, method='POST',
            )
            urllib.request.urlopen(req, timeout=10)
        except Exception as e:
            print(f"  [warn] tg send failed: {e}", file=sys.stderr)

# ── Pull data ──────────────────────────────────────────────────────────────────

signals = supa_get(
    f"interaction_log?timestamp=gte.{week_ago}"
    f"&select=signal_type,actor,user_id,signal_data,timestamp"
    f"&order=timestamp.asc&limit=500"
)

user_model = supa_get(
    "user_models?user_id=eq.josh&select=*"
)
user_model = user_model[0] if user_model else {}

learned_memories = supa_get(
    "agent_memory?confidence=gte.0.6"
    "&select=agent,scope,memory_type,content,confidence,created_at"
    f"&created_at=gte.{week_ago}"
    "&order=confidence.desc&limit=30"
)

if not signals:
    print("No signals this week — nothing to digest.")
    sys.exit(0)

# ── Build stats ────────────────────────────────────────────────────────────────

from collections import Counter, defaultdict

type_counts   = Counter(s['signal_type'] for s in signals)
active_hours  = Counter(
    datetime.datetime.fromisoformat(s['timestamp'].replace('Z', '+00:00')).hour
    for s in signals
)
active_days   = Counter(
    datetime.datetime.fromisoformat(s['timestamp'].replace('Z', '+00:00')).strftime('%A')
    for s in signals
)

# Claude session topics
session_texts = [
    s['signal_data'].get('text', '')
    for s in signals
    if s['signal_type'] == 'claude_session' and s.get('signal_data')
]

# Telegram message topics
message_texts = [
    s['signal_data'].get('text', '')
    for s in signals
    if s['signal_type'] == 'message_sent' and s.get('signal_data')
]

# Voice transcripts
voice_texts = [
    s['signal_data'].get('transcript', '')
    for s in signals
    if s['signal_type'] == 'voice_message_sent' and s.get('signal_data')
]

# Most active hour
peak_hour_utc  = active_hours.most_common(1)[0][0] if active_hours else None
peak_hour_sast = (peak_hour_utc + 2) % 24 if peak_hour_utc is not None else None
peak_day       = active_days.most_common(1)[0][0] if active_days else None

# Approved vs adjusted emails
approved  = type_counts.get('email_approved', 0)
adjusted  = type_counts.get('email_adjusted', 0)
held      = type_counts.get('email_held', 0)
total_email_actions = approved + adjusted + held
approval_rate = round(approved / total_email_actions * 100) if total_email_actions > 0 else None

stats_summary = f"""Signal breakdown ({len(signals)} total):
- Terminal sessions: {type_counts.get('claude_session', 0)}
- Telegram messages: {type_counts.get('message_sent', 0)}
- Voice notes: {type_counts.get('voice_message_sent', 0)}
- Emails approved/held/adjusted: {approved}/{held}/{adjusted}
- Tasks created/completed: {type_counts.get('task_created', 0)}/{type_counts.get('task_completed', 0)}
- Replies received: {type_counts.get('reply_received', 0)} ({type_counts.get('reply_positive', 0)} positive)
- Meetings analysed: {type_counts.get('meeting_analysed', 0)}

Most active hour: {peak_hour_sast}:00 SAST ({peak_hour_utc}:00 UTC)
Most active day: {peak_day}
Email approval rate: {approval_rate}%"""

memories_text = json.dumps([
    {'agent': m['agent'], 'type': m['memory_type'],
     'content': m['content'], 'confidence': m['confidence']}
    for m in learned_memories
], indent=2) if learned_memories else '[]'
raw_obs = user_model.get('raw_observations') or []

raw_data_block = f"""## Stats
{stats_summary}

## Newly learned patterns (confidence >= 0.6)
{memories_text}

## Raw observations
{json.dumps(raw_obs[-10:], indent=2)}

## Terminal session topics
{json.dumps(session_texts[:10], indent=2)}

## Telegram messages
{json.dumps(message_texts[:10], indent=2)}

## Voice notes
{json.dumps(voice_texts[:6], indent=2)}"""

# ── Step 1: Haiku — structured extraction from raw signals ────────────────────

print("  Step 1: Haiku extraction...", flush=True)
haiku_prompt = f"""Extract a clean structured summary from this week's behavioural signals.
Return JSON only — no explanation.

{{
  "peak_hours_sast": ["list of HH:00 strings"],
  "most_active_day": "day name",
  "least_active_day": "day name",
  "top_topics": ["extracted from terminal + telegram text"],
  "client_mentions": {{"slug": count}},
  "voice_vs_text": "X voice / Y text messages",
  "email_approval_rate": "X%",
  "tasks_completed": N,
  "build_vs_manage_ratio": "X% build / Y% manage (terminal vs telegram)",
  "anomalies": ["anything unusual or notable"],
  "recurring_themes": ["themes appearing across multiple signal types"]
}}

{raw_data_block}"""

extraction_raw = call_claude(haiku_prompt, 'claude-haiku-4-5-20251001')
# Strip markdown if present
extraction_clean = extraction_raw.strip()
if extraction_clean.startswith('```'):
    extraction_clean = extraction_clean.split('\n', 1)[1].rsplit('```', 1)[0].strip()
print(f"  Extraction: {extraction_clean[:120]}...", flush=True)

# ── Step 2: Opus — deep strategic analysis ────────────────────────────────────

print("  Step 2: Opus analysis...", flush=True)
opus_prompt = f"""You are analysing the behavioural data of Josh Burton, founder of Amalfi AI.
One week of signals from his AI operating system has been extracted and summarised.

Your job: deep, honest strategic analysis. What do these patterns reveal about his work habits,
focus, energy distribution, momentum, and blind spots? What's healthy, what's concerning?
Reference specific data points. Be direct — this is for Josh's eyes only.
500 words max. Analytical prose, not bullet points.

## Structured extraction (by Haiku)
{extraction_clean}

## Living user model
{json.dumps({'communication': user_model.get('communication', {}), 'goals': user_model.get('goals', {}), 'preferences': user_model.get('preferences', {}), 'flags': user_model.get('flags', {})}, indent=2)}

## Raw signals
{raw_data_block}"""

opus_analysis = call_claude(opus_prompt, 'claude-opus-4-6')
print(f"  Opus: {len(opus_analysis)} chars", flush=True)

# ── Step 3: o3 — second opinion ───────────────────────────────────────────────

print("  Step 3: o3 second opinion...", flush=True)
second_opinion_prompt = f"""Claude Opus has analysed one week of behavioural data for an AI startup founder.

Opus concluded:
{opus_analysis}

Raw data summary:
{extraction_clean}

As an independent model with different training, review this analysis.
What did Opus get right? What did it miss, overweight, or interpret differently?
What would you surface that Opus didn't? Be specific — 2 to 3 short paragraphs."""

second_opinion = call_openai(second_opinion_prompt, model='o3')
print(f"  Second opinion: {len(second_opinion)} chars", flush=True)

# ── Step 4: gpt-5.2 — write the final personal digest ────────────────────────

print("  Step 4: gpt-5.2 final digest...", flush=True)
digest_prompt = f"""You are writing Josh's weekly intelligence report from his AI operating system.
You have two independent analyses of his week. Your job: synthesise them into one personal,
readable report addressed directly to Josh.

Rules:
- Address him as "you" throughout
- Lead with the single most important insight
- Where Opus and o3 agree, state it with confidence
- Where they differ, surface both perspectives briefly
- Be warm, honest, and specific — no generic startup founder platitudes
- HTML bold tags for section headers
- Under 500 words
- No bullet lists — short punchy paragraphs only

## Opus analysis
{opus_analysis}

## Second opinion (o3)
{second_opinion}

## Hard stats
{stats_summary}

Write the digest now."""

report = call_openai(digest_prompt, model='gpt-5.2', temperature=0.75)

if not report:
    # Fallback: send raw stats
    report = f"<b>Weekly Memory Digest</b>\n\n{stats_summary}"

# ── Send ──────────────────────────────────────────────────────────────────────

week_str = now.strftime('%d %b %Y')
header = f"<b>Weekly Memory Digest — {week_str}</b>\n\n"
tg(header + report)

print(f"Done — digest sent. {len(signals)} signals, {len(learned_memories)} new memories.")
PY

log "Weekly memory digest complete."
