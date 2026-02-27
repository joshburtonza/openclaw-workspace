#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# aos-value-report.sh
# Monthly "What AOS did for you" report — sent on 1st of each month.
# Justifies the R6k/month retainer by showing concrete activity.
#
# Usage: bash aos-value-report.sh [YYYY-MM]  (defaults to last month)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
OWNER_NAME="${AOS_OWNER_NAME:-Josh}"
COMPANY="${AOS_COMPANY:-Amalfi AI}"
SOPHIA_EMAIL="${AOS_SOPHIA_EMAIL:-sophia@amalfiai.com}"

LOG="$WS/out/aos-value-report.log"
mkdir -p "$WS/out"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Value report starting" >> "$LOG"

# ── Date range: last calendar month ──────────────────────────────────────────
TARGET_MONTH="${1:-}"
if [[ -n "$TARGET_MONTH" ]]; then
  MONTH_LABEL="$TARGET_MONTH"
  MONTH_START="${TARGET_MONTH}-01T00:00:00Z"
  MONTH_END=$(python3 -c "
import datetime
y,m = map(int, '${TARGET_MONTH}'.split('-'))
if m == 12: y2,m2 = y+1,1
else: y2,m2 = y,m+1
print(f'{y2:04d}-{m2:02d}-01T00:00:00Z')
")
else
  MONTH_START=$(python3 -c "
import datetime
today = datetime.date.today()
first = today.replace(day=1)
last_month = first - datetime.timedelta(days=1)
print(last_month.strftime('%Y-%m-01T00:00:00Z'))
")
  MONTH_END=$(python3 -c "
import datetime
today = datetime.date.today()
print(today.replace(day=1).strftime('%Y-%m-%dT00:00:00Z'))
")
  MONTH_LABEL=$(python3 -c "
import datetime
today = datetime.date.today()
last = (today.replace(day=1) - datetime.timedelta(days=1))
print(last.strftime('%B %Y'))
")
fi

export MONTH_START MONTH_END MONTH_LABEL SUPABASE_URL KEY BOT_TOKEN CHAT_ID
export OPENAI_KEY OWNER_NAME COMPANY SOPHIA_EMAIL WS LOG

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reporting on: $MONTH_LABEL ($MONTH_START → $MONTH_END)" >> "$LOG"

python3 - << 'PY'
import json, os, sys, urllib.request, urllib.error, datetime, subprocess

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
OPENAI_KEY   = os.environ['OPENAI_KEY']
OWNER_NAME   = os.environ['OWNER_NAME']
COMPANY      = os.environ['COMPANY']
SOPHIA_EMAIL = os.environ['SOPHIA_EMAIL']
WS           = os.environ['WS']
LOG          = os.environ['LOG']
MONTH_START  = os.environ['MONTH_START']
MONTH_END    = os.environ['MONTH_END']
MONTH_LABEL  = os.environ['MONTH_LABEL']

def log(msg):
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    print(f'  [{ts}] {msg}', flush=True)
    with open(LOG, 'a') as f:
        f.write(f'[{ts}] {msg}\n')

def supa_get(path):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    req = urllib.request.Request(url, headers={
        'apikey': KEY, 'Authorization': f'Bearer {KEY}'
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except Exception as e:
        log(f'[warn] Supabase query failed ({path[:60]}): {e}')
        return []

def count_query(path):
    rows = supa_get(path)
    return len(rows) if isinstance(rows, list) else 0

def tg_send(text):
    payload = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        data=payload,
        headers={'Content-Type': 'application/json'}
    )
    try:
        urllib.request.urlopen(req, timeout=15)
    except Exception as e:
        log(f'[warn] Telegram send failed: {e}')

def call_openai(prompt):
    if not OPENAI_KEY:
        return prompt
    body = json.dumps({
        'model': 'gpt-4o',
        'messages': [{'role': 'user', 'content': prompt}],
        'temperature': 0.5,
    }).encode()
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=body,
        headers={'Authorization': f'Bearer {OPENAI_KEY}', 'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())['choices'][0]['message']['content'].strip()
    except Exception as e:
        log(f'[warn] OpenAI failed: {e}')
        return None

# ── Gather stats ──────────────────────────────────────────────────────────────
log('Gathering email stats...')
emails_sent = count_query(
    f"email_queue?status=eq.sent"
    f"&sent_at=gte.{MONTH_START}&sent_at=lt.{MONTH_END}"
    f"&select=id"
)
emails_approved = count_query(
    f"interaction_log?signal_type=eq.email_approved"
    f"&timestamp=gte.{MONTH_START}&timestamp=lt.{MONTH_END}"
    f"&select=id"
)
emails_held = count_query(
    f"interaction_log?signal_type=eq.email_held"
    f"&timestamp=gte.{MONTH_START}&timestamp=lt.{MONTH_END}"
    f"&select=id"
)

log('Gathering meeting stats...')
meetings_rows = supa_get(
    f"research_sources?title=ilike.*Notes*"
    f"&created_at=gte.{MONTH_START}&created_at=lt.{MONTH_END}"
    f"&select=title,created_at"
)
meetings_analysed = len(meetings_rows) if isinstance(meetings_rows, list) else 0
meeting_titles = [r.get('title', '')[:60] for r in (meetings_rows or [])[:8]]

log('Gathering task stats...')
tasks_done = count_query(
    f"tasks?status=eq.done"
    f"&updated_at=gte.{MONTH_START}&updated_at=lt.{MONTH_END}"
    f"&select=id"
)
tasks_rows = supa_get(
    f"tasks?status=eq.done"
    f"&updated_at=gte.{MONTH_START}&updated_at=lt.{MONTH_END}"
    f"&select=title"
    f"&limit=10"
)
task_titles = [r.get('title', '')[:70] for r in (tasks_rows or [])]

log('Gathering research stats...')
research_done = count_query(
    f"research_sources?status=eq.processed"
    f"&created_at=gte.{MONTH_START}&created_at=lt.{MONTH_END}"
    f"&select=id"
)

log('Gathering signal stats...')
signals_total = count_query(
    f"interaction_log?timestamp=gte.{MONTH_START}&timestamp=lt.{MONTH_END}&select=id"
)

log('Gathering git commit stats...')
total_commits = 0
try:
    import glob as _glob
    client_dirs = _glob.glob(f'{WS}/clients/*')
    for cdir in client_dirs:
        result = subprocess.run(
            ['git', 'log', '--oneline',
             f'--after={MONTH_START[:10]}',
             f'--before={MONTH_END[:10]}'],
            capture_output=True, text=True, cwd=cdir, timeout=10
        )
        total_commits += len([l for l in result.stdout.splitlines() if l.strip()])
except Exception:
    pass

# ── Time saved estimate ───────────────────────────────────────────────────────
# Conservative estimates per action:
# Email drafted+sent: 8 min saved, Meeting debrief: 20 min, Task researched: 30 min
time_saved_hours = round(
    (emails_sent * 8 + meetings_analysed * 20 + tasks_done * 30 + research_done * 15) / 60
)

log(f'Stats: {emails_sent} emails, {meetings_analysed} meetings, {tasks_done} tasks, {research_done} research, ~{time_saved_hours}h saved')

# ── Build GPT narrative ───────────────────────────────────────────────────────
data_summary = f"""
Month: {MONTH_LABEL}
Owner: {OWNER_NAME} at {COMPANY}

RAW STATS:
- Emails drafted and sent by Sophia: {emails_sent}
- Email drafts Josh reviewed (approved: {emails_approved}, held: {emails_held})
- Meetings analysed and debriefed: {meetings_analysed}
- Tasks researched and implemented: {tasks_done}
- Research sources processed: {research_done}
- Code commits pushed to client repos: {total_commits}
- Total AI interactions logged: {signals_total}
- Estimated time saved: ~{time_saved_hours} hours

MEETINGS COVERED:
{chr(10).join('- ' + t for t in meeting_titles) if meeting_titles else '- (none this month)'}

TASKS COMPLETED:
{chr(10).join('- ' + t for t in task_titles) if task_titles else '- (none this month)'}
"""

gpt_prompt = f"""You are writing a monthly value report for {OWNER_NAME} at {COMPANY}, summarising what their Amalfi OS AI assistant did last month.

Tone: confident, warm, business-like. Written TO {OWNER_NAME} FROM Amalfi AI.
Format: plain text, suitable for Telegram. Max 300 words.
Use the data below. Convert the dry numbers into business value language — time saved, decisions supported, relationships maintained.

Do NOT use hyphens (-) anywhere. Use bullet points (•) instead.
Do NOT use markdown. This goes into Telegram HTML so use <b>bold</b> sparingly for headers only.

{data_summary}

Write the full report now. End with a single sentence on what AOS will focus on next month.
"""

log('Generating narrative with GPT-4o...')
narrative = call_openai(gpt_prompt)

if not narrative:
    # Fallback: plain stats report
    narrative = (
        f"<b>Amalfi OS — {MONTH_LABEL} Report</b>\n\n"
        f"Here is what your AI OS handled last month:\n\n"
        f"• <b>Emails sent by Sophia:</b> {emails_sent}\n"
        f"• <b>Meetings analysed:</b> {meetings_analysed}\n"
        f"• <b>Tasks completed:</b> {tasks_done}\n"
        f"• <b>Research sources processed:</b> {research_done}\n"
        f"• <b>Code commits:</b> {total_commits}\n"
        f"• <b>Estimated time saved:</b> ~{time_saved_hours} hours\n\n"
        f"Your OS ran continuously this month and handled the above autonomously."
    )
else:
    # Wrap with header
    narrative = f"<b>Amalfi OS — {MONTH_LABEL} Report</b>\n\n{narrative}"

log('Sending to Telegram...')
tg_send(narrative)
log('Value report sent.')
print(narrative[:500])
PY

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Value report complete" >> "$LOG"
