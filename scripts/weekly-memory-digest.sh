#!/usr/bin/env bash
# weekly-memory-digest.sh
# Runs every Sunday at 09:00 SAST.
# Queries interaction_log + user_models + agent_memory → builds a "what the system
# has learned about you this week" report and sends to Josh on Telegram.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
LOG="$WS/out/weekly-memory-digest.log"
HAIKU_MODEL="claude-haiku-4-5-20251001"

mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

if [[ -z "$KEY" ]]; then log "ERROR: SUPABASE_SERVICE_ROLE_KEY not set"; exit 1; fi

log "=== Weekly memory digest ==="

export KEY SUPABASE_URL BOT_TOKEN CHAT_ID WS HAIKU_MODEL

python3 - <<'PY'
import os, json, subprocess, datetime, urllib.request, tempfile, sys

KEY          = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
BOT_TOKEN    = os.environ.get('BOT_TOKEN', '')
CHAT_ID      = os.environ.get('CHAT_ID', '1140320036')
HAIKU_MODEL  = os.environ['HAIKU_MODEL']

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

# ── Build Haiku prompt ─────────────────────────────────────────────────────────

memories_text = json.dumps([
    {'agent': m['agent'], 'type': m['memory_type'],
     'content': m['content'], 'confidence': m['confidence']}
    for m in learned_memories
], indent=2) if learned_memories else '[]'

raw_obs = user_model.get('raw_observations') or []

prompt = f"""You are writing a weekly intelligence report for Josh — the founder of Amalfi AI.
Based on one week of behavioural signals from his AI operating system, write him a concise,
insightful personal report about what the system has learned about him this week.

Write in second person ("You..."). Be specific, honest, and genuinely useful.
Format as a Telegram message with HTML bold tags for headers.
Keep it under 600 words. No bullet soup — use short punchy paragraphs.

## Signal stats
{stats_summary}

## New agent memories learned this week (confidence >= 0.6)
{memories_text}

## Raw observations logged
{json.dumps(raw_obs[-10:], indent=2)}

## Terminal session topics (sample)
{json.dumps(session_texts[:8], indent=2)}

## Telegram messages (sample)
{json.dumps(message_texts[:8], indent=2)}

## Voice note transcripts (sample)
{json.dumps(voice_texts[:5], indent=2)}

Write the report now. Start with a short punchy title line, then the insights."""

# ── Call Haiku ────────────────────────────────────────────────────────────────

env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE')}
tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, prefix='/tmp/wmd-')
tmp.write(prompt)
tmp.close()

try:
    r = subprocess.run(
        ['claude', '--print', '--model', HAIKU_MODEL, '--dangerously-skip-permissions'],
        stdin=open(tmp.name), capture_output=True, text=True, timeout=90, env=env,
    )
    report = r.stdout.strip()
except Exception as e:
    report = ''
    print(f"  [warn] Haiku call failed: {e}", file=sys.stderr)
finally:
    os.unlink(tmp.name)

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
