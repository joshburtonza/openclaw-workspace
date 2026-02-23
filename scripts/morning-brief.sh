#!/usr/bin/env bash
# morning-brief.sh — generates a daily voice note brief and sends via Telegram
# Runs at 05:30 UTC (07:30 SAST) via LaunchAgent
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"
source "$WORKSPACE/scripts/lib/task-helpers.sh"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
unset CLAUDECODE

BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
_CHAT_ID_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/josh_private_chat_id"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-$(cat "$_CHAT_ID_FILE" 2>/dev/null || echo "1140320036")}"
KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
AUDIO_OUT="/Users/henryburton/.openclaw/media/outbound/morning-brief.opus"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Morning brief starting"
TASK_ID=$(task_create "Morning Brief" "Generating daily voice note brief and SWOT" "morning-brief" "normal")

# ── Data OS snapshot (single source of truth from data-os-sync) ──────────────

DASHBOARD_SNAPSHOT="Dashboard unavailable."
DASHBOARD_JSON="$WORKSPACE/data/dashboard.json"
if [[ -f "$DASHBOARD_JSON" ]]; then
  DASHBOARD_SNAPSHOT=$(python3 -c "
import json, sys
try:
    d = json.load(open('${DASHBOARD_JSON}'))
    r  = d.get('retainer', {})
    p  = d.get('pipeline', {}).get('last_7d', {})
    dh = d.get('delivery', {})
    mrr      = r.get('mrr', 0)
    active   = r.get('active_clients', 0)
    paid     = r.get('paid_this_month', 0)
    missing  = r.get('missing', [])
    sent_7d  = p.get('sent', 0)
    awaiting = p.get('awaiting', 0)
    health   = dh.get('health_status', 'unknown').upper()
    commits  = dh.get('total_commits_7d', 0)
    parts = [
        'MRR: R' + '{:,}'.format(int(mrr)) + ' (' + str(paid) + '/' + str(active) + ' clients paid)',
        'Pipeline (7d): ' + str(sent_7d) + ' sent, ' + str(awaiting) + ' awaiting approval',
        'Delivery: ' + health + ' (' + str(commits) + ' commits/7d)',
    ]
    if missing:
        parts.append('Missing payment: ' + ', '.join(missing))
    print(' | '.join(parts))
except Exception as e:
    print('Dashboard read error: ' + str(e))
" 2>/dev/null || echo "Dashboard read failed.")
fi
echo "  Dashboard: $DASHBOARD_SNAPSHOT"

# ── Gather live context ───────────────────────────────────────────────────────

# Pending approvals
PENDING_JSON=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?status=eq.awaiting_approval&select=client,subject,created_at&order=created_at.asc&limit=10" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY")

PENDING_TEXT=$(echo "$PENDING_JSON" | python3 -c "
import json, sys, time, calendar
from datetime import datetime
rows = json.loads(sys.stdin.read()) or []
if not rows:
    print('No pending approvals.')
else:
    now_ts = time.time()
    for r in rows:
        created = r['created_at'].replace('Z','').replace('+00:00','')[:19]
        try:
            ts = datetime.strptime(created, '%Y-%m-%dT%H:%M:%S')
            age_h = int((now_ts - calendar.timegm(ts.timetuple())) / 3600)
        except Exception:
            age_h = 0
        print(r['client'].replace('_',' ') + ': ' + r['subject'][:50] + ' (' + str(age_h) + 'h old)')
" 2>/dev/null || echo "Unable to fetch pending.")

# Repo changes (last 24h)
REPO_CHANGES=""
for ENTRY in "chrome-auto-care:Race Technik" "qms-guard:Ascend LC" "favorite-flow-9637aff2:Favorite Logistics"; do
  DIR="${ENTRY%%:*}"
  NAME="${ENTRY#*:}"
  COMMITS=$(git -C "$WORKSPACE/clients/$DIR" log --oneline --since="24 hours ago" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$COMMITS" -gt 0 ]] && REPO_CHANGES="${REPO_CHANGES}${NAME}: ${COMMITS} commit(s). "
done
[[ -z "$REPO_CHANGES" ]] && REPO_CHANGES="No repo changes in last 24h."

# Active reminders due today
REMINDERS=$(curl -s "${SUPABASE_URL}/rest/v1/notifications?type=eq.reminder&status=eq.unread&select=title,metadata&limit=5" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | python3 -c "
import json, sys
from datetime import datetime, timezone
rows = json.loads(sys.stdin.read()) or []
today = datetime.now(timezone.utc).strftime('%Y-%m-%d')
due_today = []
for r in rows:
    meta = r.get('metadata') or {}
    due = meta.get('due','')
    if due.startswith(today):
        due_today.append(r['title'])
if due_today:
    print('Reminders today: ' + ', '.join(due_today) + '.')
else:
    print('')
" 2>/dev/null || echo "")

# OOO status
OOO_STATUS=""
if [[ -f "$WORKSPACE/tmp/sophia-ooo-cache" ]]; then
  OOO_VAL=$(cat "$WORKSPACE/tmp/sophia-ooo-cache" 2>/dev/null || echo "false")
  [[ "$OOO_VAL" != "false" ]] && OOO_STATUS="Note: Josh is currently OOO — $OOO_VAL."
fi

DOW=$(date +%A)
DATE_STR=$(date +"%B %-d")

# ── WhatsApp inbox summary ─────────────────────────────────────────────────────

WHATSAPP_SUMMARY=""
WHATSAPP_INBOX_FILE="$WORKSPACE/data/whatsapp-inbox.md"
if [[ -f "$WHATSAPP_INBOX_FILE" ]]; then
  WHATSAPP_SUMMARY=$(python3 -c "
import re, sys
text = open('${WHATSAPP_INBOX_FILE}').read()
# Extract first para (count line) and client headers
lines = text.split('\n')
count_line = ''
clients_seen = []
for l in lines:
    if l.startswith('*') and 'message' in l.lower():
        count_line = l.strip('* ')
    elif l.startswith('## '):
        clients_seen.append(l[3:].strip())
if count_line:
    summary = count_line
    if clients_seen:
        summary += ' From: ' + ', '.join(clients_seen) + '.'
    print(summary)
else:
    print('No WhatsApp messages in last 24h.')
" 2>/dev/null || echo "WhatsApp inbox unavailable.")
fi

# ── Gather SWOT operational data ──────────────────────────────────────────────

SWOT_DATA=$(python3 - <<SWOTPY 2>/dev/null || echo "SWOT data unavailable"
import json, urllib.request, subprocess, datetime, collections

URL = "${SUPABASE_URL}"
KEY = "${KEY}"
WS  = "${WORKSPACE}"

def supa_get(path):
    req = urllib.request.Request(
        URL + "/rest/v1/" + path,
        headers={"apikey": KEY, "Authorization": "Bearer " + KEY},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except Exception:
        return []

# Email queue stats (last 7 days)
seven_ago = (datetime.datetime.utcnow() - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')
email_rows = supa_get("email_queue?select=status&created_at=gte." + seven_ago)
ec = collections.Counter(r.get('status', '') for r in email_rows)

# Retainer revenue signals (current month)
curr_month = datetime.datetime.utcnow().strftime('%Y-%m')
income_rows  = supa_get("income_entries?month=eq." + curr_month + "&select=client,amount,status")
client_rows  = supa_get("clients?status=eq.active&select=name")
active_names = [c['name'] for c in client_rows]
paid_names   = [e['client'] for e in income_rows if e.get('status') in ('paid', 'invoiced')]
missing      = [n for n in active_names if n not in paid_names]
total_inv    = sum(float(e.get('amount', 0) or 0) for e in income_rows if e.get('status') in ('paid', 'invoiced'))

# Repo delivery velocity (7 days)
repos = [
    ("chrome-auto-care",         "Race Technik"),
    ("qms-guard",                "Ascend LC"),
    ("favorite-flow-9637aff2",   "Favorite Logistics"),
]
repo_parts = []
for (d, n) in repos:
    try:
        r = subprocess.run(
            ["git", "-C", WS + "/clients/" + d, "log", "--oneline", "--since=7 days ago"],
            capture_output=True, text=True, timeout=10,
        )
        count = len([l for l in r.stdout.strip().split("\n") if l.strip()])
        repo_parts.append(n + ": " + str(count) + " commit(s)")
    except Exception:
        repo_parts.append(n + ": unknown")

# Alex outreach reply rates
lead_rows   = supa_get("leads?select=status&limit=1000")
lc          = collections.Counter(r.get('status', '') for r in lead_rows)
total_leads = len(lead_rows)
replied     = lc.get('replied', 0)
outreached  = sum(lc.get(s, 0) for s in ('contacted', 'sequence_complete', 'replied'))
reply_rate  = str(int(replied / outreached * 100)) + "%" if outreached > 0 else "n/a"

# Referral attribution (new leads last 7 days by referral_source)
new_lead_rows = supa_get("leads?created_at=gte." + seven_ago + "&select=referral_source&limit=500")
rc = collections.Counter(r.get('referral_source') or 'unknown' for r in new_lead_rows)
ref_parts = [s + "=" + str(rc[s]) for s in ('direct', 'referral', 'community', 'inbound', 'cold') if rc.get(s)]
if rc.get('unknown'): ref_parts.append('unknown=' + str(rc['unknown']))
ref_summary = ", ".join(ref_parts) if ref_parts else "none"

out = [
    "Email queue (7d): sent=" + str(ec.get('sent',0)) + ", rejected=" + str(ec.get('rejected',0)) + ", awaiting_approval=" + str(ec.get('awaiting_approval',0)),
    "Retainer (" + curr_month + "): " + str(len(active_names)) + " active clients, " + str(len(paid_names)) + " paid/invoiced, " + str(len(missing)) + " missing payment, R" + str(int(total_inv)) + " invoiced",
    "Delivery velocity (7d): " + " | ".join(repo_parts),
    "Alex outreach: " + str(total_leads) + " total leads, " + str(outreached) + " contacted, " + str(replied) + " replied, reply rate " + reply_rate,
    "New leads this week (" + str(len(new_lead_rows)) + " total) by source: " + ref_summary,
]
print("\n".join(out))
SWOTPY
)
echo "  SWOT data: ${SWOT_DATA}"

# ── Generate brief text via Claude ───────────────────────────────────────────

PROMPT_TMP=$(mktemp /tmp/morning-brief-XXXXXX)
cat > "$PROMPT_TMP" << PROMPT
Write a short morning voice brief for Josh. Today is ${DOW}, ${DATE_STR}.

Live data:
- Business snapshot (MRR / pipeline / delivery): ${DASHBOARD_SNAPSHOT}
- Pending approvals: ${PENDING_TEXT}
- Dev activity (24h): ${REPO_CHANGES}
- WhatsApp inbox: ${WHATSAPP_SUMMARY}
- ${REMINDERS}
- ${OOO_STATUS}

Style rules:
- Casual, direct, no corporate speak — like a smart colleague giving a morning rundown
- Conversational openers: "So listen", "Quick one", "Morning" — vary it
- 2-3 points max — only what actually matters
- If there are pending approvals, mention them clearly (Josh needs to act)
- End with ONE clear question or action item for Josh
- Keep it under 100 words — this will be read aloud as a voice note
- No bullet points, no headings — flowing speech

Reply with ONLY the brief text. Nothing else. No quotes.
PROMPT

BRIEF_TEXT=$(claude --print --model claude-haiku-4-5-20251001 < "$PROMPT_TMP" 2>/dev/null)
rm -f "$PROMPT_TMP"

if [[ -z "$BRIEF_TEXT" ]]; then
  BRIEF_TEXT="Morning Josh. Quick heads up — you've got ${PENDING_TEXT} sitting in the approval queue. ${REPO_CHANGES} What's your priority today?"
fi

echo "  Brief: $BRIEF_TEXT"

# ── Generate SWOT analysis via Claude ─────────────────────────────────────────

SWOT_PROMPT_TMP=$(mktemp /tmp/swot-prompt-XXXXXX)
cat > "$SWOT_PROMPT_TMP" << SWOTPROMPT
Operational data for Amalfi AI (week ending ${DATE_STR}):

${SWOT_DATA}

Given this week's operational data, produce a 4-point SWOT for Amalfi AI in 80 words or fewer per quadrant.

Output format — use these exact labels on their own line, followed by a plain paragraph. No bullet points, no markdown, no asterisks:

STRENGTHS:
[paragraph]

WEAKNESSES:
[paragraph]

OPPORTUNITIES:
[paragraph]

THREATS:
[paragraph]

Reply with ONLY the four labelled quadrants. No preamble, no sign-off.
SWOTPROMPT

SWOT_TEXT=$(claude --print --model claude-haiku-4-5-20251001 < "$SWOT_PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$SWOT_PROMPT_TMP"

if [[ -z "$SWOT_TEXT" ]]; then
  SWOT_TEXT="SWOT generation failed — data gathered but Claude call returned empty."
fi

echo "  SWOT generated"

# ── Gather content recommendation data ────────────────────────────────────────

CONTENT_DATA=$(python3 - <<CONTENTPY 2>/dev/null || echo "Content data unavailable"
import json, urllib.request, datetime

URL = "${SUPABASE_URL}"
KEY = "${KEY}"

def supa_get(path):
    req = urllib.request.Request(
        URL + "/rest/v1/" + path,
        headers={"apikey": KEY, "Authorization": "Bearer " + KEY},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except Exception:
        return []

seven_ago = (datetime.datetime.utcnow() - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')

# Recent calendar events as meeting proxies
cal_rows = supa_get("calendar_events?start_at=gte." + seven_ago + "&status=eq.confirmed&select=title,description,start_at&order=start_at.desc&limit=15")
meetings = []
for e in cal_rows:
    parts = [e.get('title','').strip()]
    desc = (e.get('description') or '').strip()
    if desc:
        parts.append(desc[:200])
    line = ' — '.join(p for p in parts if p)
    if line:
        meetings.append(line)

# Recent sent emails for outbound themes
email_rows = supa_get("email_queue?status=eq.sent&created_at=gte." + seven_ago + "&select=client,subject,body&order=created_at.desc&limit=10")
email_themes = []
for e in email_rows:
    client = e.get('client','').replace('_',' ')
    subject = (e.get('subject') or '').strip()
    body_snippet = (e.get('body') or '')[:300].strip()
    if subject:
        entry = client + ': ' + subject
        if body_snippet:
            entry += ' — ' + body_snippet
        email_themes.append(entry)

out = []
if meetings:
    out.append("RECENT MEETINGS (last 7 days):\n" + "\n".join(meetings[:10]))
else:
    out.append("RECENT MEETINGS: No calendar events found.")

if email_themes:
    out.append("\nRECENT EMAIL THEMES (sent last 7 days):\n" + "\n".join(email_themes))
else:
    out.append("\nRECENT EMAIL THEMES: No sent emails found.")

print("\n".join(out))
CONTENTPY
)
echo "  Content data gathered"

# ── Generate content recommendations via Claude ────────────────────────────────

CONTENT_PROMPT_TMP=$(mktemp /tmp/content-prompt-XXXXXX)
cat > "$CONTENT_PROMPT_TMP" << CONTENTPROMPT
Amalfi AI client data from the past 7 days:

${CONTENT_DATA}

Based on Amalfi AI's client conversations and pain points this week, suggest 3 short-form video or LinkedIn post angles that would resonate with similar prospects.

Format each idea as:
ANGLE [N]: [one-line hook]
WHY IT WORKS: [one sentence grounded in the client data above]

Reply with ONLY the 3 angles in this format. No preamble, no sign-off.
CONTENTPROMPT

CONTENT_IDEAS=$(claude --print --model claude-haiku-4-5-20251001 < "$CONTENT_PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$CONTENT_PROMPT_TMP"

if [[ -z "$CONTENT_IDEAS" ]]; then
  CONTENT_IDEAS="Content recommendations unavailable — Claude call returned empty."
fi

echo "  Content ideas generated"

# ── TTS via ElevenLabs ────────────────────────────────────────────────────────

mkdir -p "$(dirname "$AUDIO_OUT")"

TTS_OK=false
if echo "$BRIEF_TEXT" | bash "$WORKSPACE/scripts/tts/elevenlabs-tts-to-opus.sh" --out "$AUDIO_OUT" 2>/dev/null; then
  TTS_OK=true
  echo "  TTS: audio generated"
else
  echo "  TTS: failed, will send text fallback" >&2
fi

# ── Send via Telegram ─────────────────────────────────────────────────────────

if [[ "$TTS_OK" == "true" && -f "$AUDIO_OUT" ]]; then
  # Send as voice note
  RESP=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendVoice" \
    -F "chat_id=${CHAT_ID}" \
    -F "voice=@${AUDIO_OUT}" \
    -F "caption=📋 Morning Brief — ${DOW} ${DATE_STR}")
  MSG_ID=$(echo "$RESP" | python3 -c "
import json,sys
try:
    r=json.loads(sys.stdin.read())
    print(r.get('result',{}).get('message_id','sent'))
except:
    print('sent')
" 2>/dev/null || echo "sent")
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Voice brief sent (msg $MSG_ID)"
else
  # Text fallback
  TEXT_MSG="🌅 *Morning Brief — ${DOW} ${DATE_STR}*

${BRIEF_TEXT}"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$TEXT_MSG"),\"parse_mode\":\"Markdown\"}" > /dev/null
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Text brief sent (TTS fallback)"
fi

# ── Send SWOT via Telegram ─────────────────────────────────────────────────────

SWOT_MSG="📊 SWOT — ${DOW} ${DATE_STR}

${SWOT_TEXT}"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$SWOT_MSG")}" > /dev/null \
  || echo "  SWOT Telegram send failed" >&2
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") SWOT sent"

# ── Send Content Ideas via Telegram ───────────────────────────────────────────

CONTENT_MSG="💡 Content Ideas — ${DOW} ${DATE_STR}

${CONTENT_IDEAS}"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$CONTENT_MSG")}" > /dev/null \
  || echo "  Content ideas Telegram send failed" >&2
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Content ideas sent"

# ── Send WhatsApp Inbox via Telegram ──────────────────────────────────────────

if [[ -f "$WORKSPACE/data/whatsapp-inbox.md" ]]; then
  WA_INBOX_BODY=$(cat "$WORKSPACE/data/whatsapp-inbox.md")
  WA_INBOX_MSG="📱 WhatsApp Inbox — ${DOW} ${DATE_STR}

${WA_INBOX_BODY}

Reply via Telegram: /reply wa [contact] [message]"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$WA_INBOX_MSG")}" > /dev/null \
    || echo "  WhatsApp inbox Telegram send failed" >&2
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WhatsApp inbox sent"
fi

# ── Positioning Note (scope-boundary reminder) ────────────────────────────────

RETAINER_PENDING_COUNT=$(echo "$PENDING_JSON" | python3 -c "
import json, sys
rows = json.loads(sys.stdin.read()) or []
retainer_clients = {'ascend_lc', 'race_technik', 'favorite_logistics'}
print(sum(1 for r in rows if r.get('client','') in retainer_clients))
" 2>/dev/null || echo "0")

if [[ "$RETAINER_PENDING_COUNT" -ge 3 ]]; then
  POSITIONING_NOTE="📌 Positioning Note

You have ${RETAINER_PENDING_COUNT} client emails pending approval today. Reminder: stay contractor — frame all responses as a specialist delivering defined outcomes, not an embedded resource. Watch for scope expansion language in drafts."
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$POSITIONING_NOTE")}" > /dev/null \
    || echo "  Positioning note Telegram send failed" >&2
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Positioning note sent (${RETAINER_PENDING_COUNT} retainer approvals pending)"
fi

task_complete "$TASK_ID" "Morning brief sent"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Morning brief complete"
