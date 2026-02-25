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

# Demo requests (leads who asked for a live demo)
DEMO_REQUESTS=$(curl -s "${SUPABASE_URL}/rest/v1/leads?status=eq.replied&reply_sentiment=eq.demo_request&select=first_name,last_name,company,reply_received_at&order=reply_received_at.desc&limit=10" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | python3 -c "
import json, sys
rows = json.loads(sys.stdin.read()) or []
if rows:
    parts = []
    for r in rows:
        name = (r.get('first_name','') + ' ' + (r.get('last_name') or '')).strip()
        company = r.get('company','')
        parts.append((name + ' @ ' + company) if company else name)
    print(str(len(rows)) + ' demo request(s): ' + ', '.join(parts))
else:
    print('')
" 2>/dev/null || echo "")

# Repo changes (last 24h)
REPO_CHANGES=""
for ENTRY in "qms-guard:Ascend LC" "favorite-flow-9637aff2:Favorite Logistics"; do
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

# ── AI News Digest ─────────────────────────────────────────────────────────────

AI_NEWS_RAW=""
for _AI_RSS in \
  "https://feeds.feedburner.com/venturebeat/SXUW" \
  "https://techcrunch.com/category/artificial-intelligence/feed/" \
  "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml"; do
  _AI_FEED=$(curl -s --max-time 8 "$_AI_RSS" 2>/dev/null || echo "")
  if [[ -n "$_AI_FEED" ]]; then
    _AI_TITLES=$(echo "$_AI_FEED" | python3 -c "
import sys, re, html
raw = sys.stdin.read()
items = re.findall(r'<item[^>]*>.*?</item>', raw, re.DOTALL)
out = []
for item in items[:8]:
    m = re.search(r'<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>', item, re.DOTALL)
    if m:
        t = html.unescape(m.group(1).strip())
        if len(t) > 15:
            out.append(t)
if out:
    print('\n'.join(out[:6]))
" 2>/dev/null || echo "")
    [[ -n "$_AI_TITLES" ]] && AI_NEWS_RAW="${AI_NEWS_RAW}${_AI_TITLES}"$'\n'
  fi
done

AI_NEWS_PROMPT_TMP=$(mktemp /tmp/ai-news-XXXXXX)
if [[ -n "$AI_NEWS_RAW" ]]; then
  cat > "$AI_NEWS_PROMPT_TMP" << AINEWSPROMPT
Today is ${DOW}, ${DATE_STR}. Recent AI/tech RSS headlines:

${AI_NEWS_RAW}

Select and summarise 3-5 most relevant for an AI agency founder deploying automation for SMBs. Focus on AI agents, LLM releases, automation tools, and business AI news.

Format each as:
- [Headline]: [One sentence on why it matters for AI agency work]

Reply with ONLY the list. No preamble, no sign-off.
AINEWSPROMPT
else
  cat > "$AI_NEWS_PROMPT_TMP" << AINEWSPROMPT
Today is ${DOW}, ${DATE_STR}. Synthesise 3-5 significant AI industry headlines from the past week that an AI agency founder deploying automation for SMBs should know today. Focus on AI agents, LLM releases, automation tools, and notable business AI product launches or policy moves.

Format each as:
- [Headline]: [One sentence on why it matters for AI agency work]

Reply with ONLY the list. No preamble, no sign-off.
AINEWSPROMPT
fi

AI_NEWS_DIGEST=$(claude --print --model claude-haiku-4-5-20251001 < "$AI_NEWS_PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$AI_NEWS_PROMPT_TMP"
[[ -z "$AI_NEWS_DIGEST" ]] && AI_NEWS_DIGEST="AI news digest unavailable."
echo "  AI news digest generated"

# ── SA Market Intelligence ─────────────────────────────────────────────────────
# Filters for SA-specific AI enterprise adoption signals: mining, logistics, legal, property
# Search terms: 'South Africa AI enterprise', 'SA mining automation', 'South Africa AI procurement'

SA_INTEL_RAW=""

# Filter existing RSS data for SA/Africa-relevant keywords
if [[ -n "$AI_NEWS_RAW" ]]; then
  SA_INTEL_RAW=$(echo "$AI_NEWS_RAW" | python3 -c "
import sys
lines = sys.stdin.read().split('\n')
keywords = ['south africa', 'africa ai', 'sa mining', 'mining automation', 'logistics ai',
            'legal ai', 'property ai', 'sa enterprise', 'african enterprise', 'johannesburg',
            'cape town', 'pretoria', 'durban', 'procurement ai', 'africa enterprise']
out = [l for l in lines if l.strip() and any(k in l.lower() for k in keywords)]
print('\n'.join(out))
" 2>/dev/null || echo "")
fi

# Additional SA-focused RSS sources
for _SA_RSS in \
  "https://businesstech.co.za/news/category/technology/feed/" \
  "https://www.itweb.co.za/feeds/rss/"; do
  _SA_FEED=$(curl -s --max-time 8 "$_SA_RSS" 2>/dev/null || echo "")
  if [[ -n "$_SA_FEED" ]]; then
    _SA_TITLES=$(echo "$_SA_FEED" | python3 -c "
import sys, re, html
raw = sys.stdin.read()
items = re.findall(r'<item[^>]*>.*?</item>', raw, re.DOTALL)
kw = ['ai', 'automation', 'machine learning', 'enterprise', 'mining', 'logistics', 'legal', 'property', 'procurement']
out = []
for item in items[:15]:
    m = re.search(r'<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>', item, re.DOTALL)
    if m:
        t = html.unescape(m.group(1).strip())
        if len(t) > 15 and any(k in t.lower() for k in kw):
            out.append(t)
if out:
    print('\n'.join(out[:8]))
" 2>/dev/null || echo "")
    [[ -n "$_SA_TITLES" ]] && SA_INTEL_RAW="${SA_INTEL_RAW}${_SA_TITLES}"$'\n'
  fi
done

# Pull SA-relevant calendar context from Supabase (last 48h)
SA_CALENDAR_CONTEXT=$(python3 - <<SAINTPY 2>/dev/null || echo ""
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

two_days_ago = (datetime.datetime.utcnow() - datetime.timedelta(days=2)).strftime('%Y-%m-%dT%H:%M:%SZ')
cal_rows = supa_get("calendar_events?start_at=gte." + two_days_ago + "&select=title,description,start_at&order=start_at.desc&limit=20")

sa_keywords = ['south africa', ' sa ', 'mining', 'logistics', 'legal', 'property', 'aleadx', 'procure']
sa_meetings = []
for e in cal_rows:
    title = (e.get('title') or '').lower()
    desc  = (e.get('description') or '').lower()
    if any(k in title + ' ' + desc for k in sa_keywords):
        sa_meetings.append(e.get('title', '').strip())

if sa_meetings:
    print('Recent SA-relevant meetings: ' + ', '.join(sa_meetings[:5]))
else:
    print('')
SAINTPY
)

SA_INTEL_PROMPT_TMP=$(mktemp /tmp/sa-intel-XXXXXX)
if [[ -n "$SA_INTEL_RAW" ]]; then
  cat > "$SA_INTEL_PROMPT_TMP" << SAINTELPRMT
Today is ${DOW}, ${DATE_STR}. You are briefing Josh, an AI agency founder in South Africa (Amalfi AI).

Recent SA-relevant signals from news feeds:
${SA_INTEL_RAW}

${SA_CALENDAR_CONTEXT:+Calendar context: ${SA_CALENDAR_CONTEXT}
}
Focus on AI enterprise adoption in SA verticals: mining, logistics, legal, property.
Flag any competitor AI agency activity in SA niche verticals.
Triggered by: 'South Africa AI enterprise', 'SA mining automation', 'South Africa AI procurement'

Summarise 2-4 most relevant signals. If SA-direct signals are sparse, infer from global mining/logistics/legal/property AI trends and note SA relevance.

Format each as:
- [Signal]: [One sentence on competitive/market implication for Amalfi AI]

Reply with ONLY the list. No preamble, no sign-off.
SAINTELPRMT
else
  cat > "$SA_INTEL_PROMPT_TMP" << SAINTELPRMT
Today is ${DOW}, ${DATE_STR}. You are briefing Josh, an AI agency founder in South Africa (Amalfi AI).

${SA_CALENDAR_CONTEXT:+Recent calendar context: ${SA_CALENDAR_CONTEXT}
}No direct SA AI news was found in today's RSS feeds. Using your training knowledge, surface 2-3 relevant AI adoption signals for Josh across SA verticals: mining automation, logistics AI, legal AI, property tech.

IMPORTANT: Generate the signals now from your training knowledge. Do not ask for more data. Do not ask clarifying questions. Just produce the output.

Format each as:
- [Signal]: [One sentence on competitive/market implication for Amalfi AI]

Reply with ONLY the list. No preamble, no sign-off.
SAINTELPRMT
fi

SA_INTEL_TEXT=$(claude --print --model claude-haiku-4-5-20251001 < "$SA_INTEL_PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$SA_INTEL_PROMPT_TMP"
[[ -z "$SA_INTEL_TEXT" ]] && SA_INTEL_TEXT="SA market intelligence unavailable."
echo "  SA market intelligence generated"

# ── Compliance Vertical Intelligence ──────────────────────────────────────────
# QMS/ISO/HACCP automation, SMB compliance workflow AI, Smartsheet ecosystem
# For Josh closing Ascend LC (QMS non-conformance) and Favorite Logistics (FLAIR)

COMPLIANCE_INTEL_RAW=""

# Filter existing RSS data for compliance-relevant keywords
if [[ -n "$AI_NEWS_RAW" ]]; then
  COMPLIANCE_INTEL_RAW=$(echo "$AI_NEWS_RAW" | python3 -c "
import sys
lines = sys.stdin.read().split('\n')
keywords = ['qms', 'iso 9001', 'haccp', 'compliance', 'non-conformance', 'nonconformance',
            'smartsheet', 'quality management', 'food safety', 'manufacturing compliance',
            'logistics compliance', 'workflow automation', 'document control',
            'audit management', 'corrective action', 'smb compliance', 'quality control']
out = [l for l in lines if l.strip() and any(k in l.lower() for k in keywords)]
print('\n'.join(out))
" 2>/dev/null || echo "")
fi

# Additional compliance/QMS-focused RSS sources
for _COMP_RSS in \
  "https://www.qualitymag.com/rss/articles" \
  "https://www.foodsafetymagazine.com/rss/"; do
  _COMP_FEED=$(curl -s --max-time 8 "$_COMP_RSS" 2>/dev/null || echo "")
  if [[ -n "$_COMP_FEED" ]]; then
    _COMP_TITLES=$(echo "$_COMP_FEED" | python3 -c "
import sys, re, html
raw = sys.stdin.read()
items = re.findall(r'<item[^>]*>.*?</item>', raw, re.DOTALL)
kw = ['qms', 'iso', 'haccp', 'compliance', 'quality', 'automation', 'ai', 'workflow',
      'smartsheet', 'food safety', 'manufacturing', 'non-conformance', 'audit']
out = []
for item in items[:15]:
    m = re.search(r'<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>', item, re.DOTALL)
    if m:
        t = html.unescape(m.group(1).strip())
        if len(t) > 15 and any(k in t.lower() for k in kw):
            out.append(t)
if out:
    print('\n'.join(out[:8]))
" 2>/dev/null || echo "")
    [[ -n "$_COMP_TITLES" ]] && COMPLIANCE_INTEL_RAW="${COMPLIANCE_INTEL_RAW}${_COMP_TITLES}"$'\n'
  fi
done

COMPLIANCE_PROMPT_TMP=$(mktemp /tmp/compliance-intel-XXXXXX)
if [[ -n "$COMPLIANCE_INTEL_RAW" ]]; then
  cat > "$COMPLIANCE_PROMPT_TMP" << COMPLIANCEPROMPT
Today is ${DOW}, ${DATE_STR}.

Josh is selling AI-powered non-conformance classification workflows to SMB manufacturers, food producers, and logistics firms. Surface any relevant news or competitive moves.

Recent headlines related to compliance/QMS/AI:
${COMPLIANCE_INTEL_RAW}

Synthesise 3-4 signals across these focus areas:
1. QMS/ISO/HACCP automation developments
2. SMB compliance workflow AI tools (competitors, new entrants, pricing moves)
3. Smartsheet ecosystem updates (new AI features, integrations, pricing)

Format each as:
- [Topic]: [One sentence on the signal and its implication for Josh's QMS workflow sales]

Reply with ONLY the list. No preamble, no sign-off.
COMPLIANCEPROMPT
else
  cat > "$COMPLIANCE_PROMPT_TMP" << COMPLIANCEPROMPT
Today is ${DOW}, ${DATE_STR}.

Josh is selling AI-powered non-conformance classification workflows to SMB manufacturers, food producers, and logistics firms (Ascend LC, Favorite Logistics). Surface any relevant news or competitive moves.

No direct compliance/QMS headlines found in today's feeds. Using your training knowledge, surface 3-4 signals across:
1. QMS/ISO/HACCP automation — vendor moves, new tooling, buyer trends in SMB manufacturing and food production
2. SMB compliance workflow AI tools — new entrants, feature updates, pricing shifts that affect Josh's competitive position
3. Smartsheet ecosystem — AI Analyst updates, new integrations, or partner announcements relevant to compliance workflows

IMPORTANT: Generate the signals now from your training knowledge. Do not ask for more data. Do not ask clarifying questions. Just produce the output.

Format each as:
- [Topic]: [One sentence on the signal and its implication for closing SMB compliance deals]

Reply with ONLY the list. No preamble, no sign-off.
COMPLIANCEPROMPT
fi

COMPLIANCE_INTEL_TEXT=$(claude --print --model claude-haiku-4-5-20251001 < "$COMPLIANCE_PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$COMPLIANCE_PROMPT_TMP"
[[ -z "$COMPLIANCE_INTEL_TEXT" ]] && COMPLIANCE_INTEL_TEXT="Compliance vertical intelligence unavailable."
echo "  Compliance vertical intelligence generated"

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

# ── Generate SWOT analysis via Claude ─────────────────────────────────────────

SWOT_PROMPT_TMP=$(mktemp /tmp/swot-prompt-XXXXXX)
cat > "$SWOT_PROMPT_TMP" << SWOTPROMPT
Operational data for Amalfi AI (week ending ${DATE_STR}):

${SWOT_DATA}

Given this week's operational data, produce a spoken SWOT summary for Josh — one sentence per quadrant, casual and direct. No labels, no headings, just four sentences that flow together.

IMPORTANT: Generate it now. Do not ask for more data. Reply with ONLY the four sentences.
SWOTPROMPT

SWOT_TEXT=$(claude --print --model claude-haiku-4-5-20251001 < "$SWOT_PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$SWOT_PROMPT_TMP"
[[ -z "$SWOT_TEXT" ]] && SWOT_TEXT="SWOT data unavailable today."
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

email_rows = supa_get("email_queue?status=eq.sent&created_at=gte." + seven_ago + "&select=client,subject,body&order=created_at.desc&limit=10")
email_themes = []
for e in email_rows:
    client = e.get('client','').replace('_',' ')
    subject = (e.get('subject') or '').strip()
    if subject:
        email_themes.append(client + ': ' + subject)

out = []
if meetings:
    out.append("Recent meetings: " + ", ".join(meetings[:5]))
if email_themes:
    out.append("Recent email themes: " + ", ".join(email_themes[:5]))
print(" | ".join(out) if out else "No recent meetings or email data.")
CONTENTPY
)
echo "  Content data gathered"

# ── Generate content ideas ─────────────────────────────────────────────────────

CONTENT_PROMPT_TMP=$(mktemp /tmp/content-prompt-XXXXXX)
cat > "$CONTENT_PROMPT_TMP" << CONTENTPROMPT
Amalfi AI is a South African AI agency building automation platforms for SMBs in compliance (QMS/ISO), automotive services, and logistics.

Context: ${CONTENT_DATA}

Give 2 LinkedIn or short-form video angles for this week — one-line hooks only, no explanations.

IMPORTANT: Generate them now from your knowledge. Do not ask for more data. Reply with ONLY the 2 hooks, one per line.
CONTENTPROMPT

CONTENT_IDEAS=$(claude --print --model claude-haiku-4-5-20251001 < "$CONTENT_PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$CONTENT_PROMPT_TMP"
[[ -z "$CONTENT_IDEAS" ]] && CONTENT_IDEAS="Content ideas unavailable today."
echo "  Content ideas generated"

# ── AI Pulse — agent/automation news (last 48h) ───────────────────────────────

AI_PULSE_RAW=""

for _HN_QUERY in "AI+agents" "AI+automation" "LLM+agents"; do
  _HN_FEED=$(curl -s --max-time 10 "https://hnrss.org/newest?q=${_HN_QUERY}&points=10" 2>/dev/null || echo "")
  if [[ -n "$_HN_FEED" ]]; then
    _HN_TITLES=$(echo "$_HN_FEED" | python3 -c "
import sys, re, html
from datetime import datetime, timezone, timedelta
try:
    from email.utils import parsedate_to_datetime
    HAS_PARSEDATE = True
except ImportError:
    HAS_PARSEDATE = False
raw = sys.stdin.read()
items = re.findall(r'<item[^>]*>.*?</item>', raw, re.DOTALL)
cutoff = datetime.now(timezone.utc) - timedelta(hours=48)
out = []
for item in items[:20]:
    tm = re.search(r'<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>', item, re.DOTALL)
    pd = re.search(r'<pubDate[^>]*>(.*?)</pubDate>', item, re.DOTALL)
    if tm:
        t = html.unescape(tm.group(1).strip())
        if pd and HAS_PARSEDATE:
            try:
                pub = parsedate_to_datetime(pd.group(1).strip())
                if pub.tzinfo is None:
                    from datetime import timezone as tz
                    pub = pub.replace(tzinfo=tz.utc)
                if pub < cutoff:
                    continue
            except Exception:
                pass
        if len(t) > 15:
            out.append(t)
if out:
    print('\n'.join(out[:6]))
" 2>/dev/null || echo "")
    [[ -n "$_HN_TITLES" ]] && AI_PULSE_RAW="${AI_PULSE_RAW}${_HN_TITLES}"$'\n'
  fi
done

AI_PULSE_PROMPT_TMP=$(mktemp /tmp/ai-pulse-XXXXXX)
if [[ -n "$AI_PULSE_RAW" ]]; then
  cat > "$AI_PULSE_PROMPT_TMP" << AIPULSEPROMPT
Recent HN headlines (last 48h): ${AI_PULSE_RAW}

Pick the single most relevant AI agent/automation item for an SA AI agency founder. One sentence, spoken naturally.

IMPORTANT: Generate it now. Reply with ONLY that one sentence.
AIPULSEPROMPT
else
  cat > "$AI_PULSE_PROMPT_TMP" << AIPULSEPROMPT
Give one sentence on the most relevant AI agent or automation development in the last 48 hours for a South African AI agency founder. Generate from your knowledge. Do not ask for more data. Reply with ONLY that sentence.
AIPULSEPROMPT
fi

AI_PULSE_TEXT=$(claude --print --model claude-haiku-4-5-20251001 < "$AI_PULSE_PROMPT_TMP" 2>/dev/null || echo "")
rm -f "$AI_PULSE_PROMPT_TMP"
[[ -z "$AI_PULSE_TEXT" ]] && AI_PULSE_TEXT=""
echo "  AI Pulse generated"

# ── Generate comprehensive morning brief (all sections combined) ───────────────

PROMPT_TMP=$(mktemp /tmp/morning-brief-XXXXXX)
cat > "$PROMPT_TMP" << PROMPT
Write Josh's morning voice brief. Today is ${DOW}, ${DATE_STR}. Josh runs Amalfi AI, a South African AI agency.

DATA TO COVER:

BUSINESS:
- Snapshot: ${DASHBOARD_SNAPSHOT}
- Pending approvals: ${PENDING_TEXT}
- Demo requests (highest priority): ${DEMO_REQUESTS}
- Dev activity (24h): ${REPO_CHANGES}
- WhatsApp: ${WHATSAPP_SUMMARY}
- ${REMINDERS}
- ${OOO_STATUS}

SWOT THIS WEEK:
${SWOT_TEXT}

AI NEWS (pick the single most relevant):
${AI_NEWS_DIGEST}

SA MARKET INTEL:
${SA_INTEL_TEXT}

COMPLIANCE VERTICAL INTEL:
${COMPLIANCE_INTEL_TEXT}

AI PULSE:
${AI_PULSE_TEXT}

CONTENT IDEAS FOR THIS WEEK:
${CONTENT_IDEAS}

STYLE RULES:
- Spoken, casual, direct — like a smart colleague doing a full morning rundown
- Conversational opener — vary it each day ("Morning Josh", "Right, let's go", "So here is the run")
- Cover ALL sections above — business first, then SWOT summary, then market intel, then content angle
- If demo requests exist, lead with them and name the company — highest priority signal
- For AI news and SA intel: pick the ONE most relevant item from each, one sentence each
- For content ideas: mention ONE angle worth posting this week
- For SWOT: weave in the key strength and key threat naturally, one sentence each
- No bullet points, no headings — pure flowing speech
- End with one clear action item or question for Josh
- Target 300 to 400 words — this is a full morning briefing, not a quick note

Reply with ONLY the brief text. No quotes. No preamble.
PROMPT

BRIEF_TEXT=$(claude --print --model claude-haiku-4-5-20251001 < "$PROMPT_TMP" 2>/dev/null)
rm -f "$PROMPT_TMP"

if [[ -z "$BRIEF_TEXT" ]]; then
  BRIEF_TEXT="Morning Josh. Pending approvals: ${PENDING_TEXT}. Dev activity: ${REPO_CHANGES}. Check your queue and let me know your priority today."
fi

echo "  Brief generated ($(echo "$BRIEF_TEXT" | wc -w | tr -d ' ') words)"

# ── TTS via MiniMax ───────────────────────────────────────────────────────────

mkdir -p "$(dirname "$AUDIO_OUT")"

TTS_OK=false
if echo "$BRIEF_TEXT" | bash "$WORKSPACE/scripts/tts/minimax-tts-to-opus.sh" --out "$AUDIO_OUT" 2>/dev/null; then
  TTS_OK=true
  echo "  TTS: audio generated"
else
  echo "  TTS: failed, will send text fallback" >&2
fi

# ── Send voice note via Telegram ──────────────────────────────────────────────

if [[ "$TTS_OK" == "true" && -f "$AUDIO_OUT" ]]; then
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
  TEXT_MSG="🌅 Morning Brief — ${DOW} ${DATE_STR}

${BRIEF_TEXT}"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$TEXT_MSG")}" > /dev/null
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Text brief sent (TTS fallback)"
fi

# ── Send WhatsApp Inbox via Telegram ──────────────────────────────────────────

if [[ -f "$WORKSPACE/data/whatsapp-inbox.md" ]]; then
  # Strip instructional blockquote lines (lines starting with >) before sending
  WA_INBOX_BODY=$(grep -v '^>' "$WORKSPACE/data/whatsapp-inbox.md" | sed '/^[[:space:]]*$/{ /^\n*$/d; }' || cat "$WORKSPACE/data/whatsapp-inbox.md")
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
retainer_clients = {'ascend_lc', 'favorite_logistics'}
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

# ── Dependency Escalation Flags ───────────────────────────────────────────────

DEP_FLAG_FILE="$WORKSPACE/tmp/dependency-escalation-flags.txt"
if [[ -f "$DEP_FLAG_FILE" && -s "$DEP_FLAG_FILE" ]]; then
  DEP_FLAG_BODY=$(cat "$DEP_FLAG_FILE")
  DEP_FLAG_MSG="🔴 Dependency Escalation — ${DOW} ${DATE_STR}

${DEP_FLAG_BODY}

Review engagement terms and consider repricing or restructuring before next billing cycle."
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$DEP_FLAG_MSG")}" > /dev/null \
    || echo "  Dependency escalation Telegram send failed" >&2
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Dependency escalation flags sent"
fi

# ── New Client Prep Nudge ──────────────────────────────────────────────────────
# If there are leads in discovery/intro stages, remind Josh to run the paid audit

NEW_CLIENT_PREP=$(curl -s "${SUPABASE_URL}/rest/v1/leads?status=in.(discovery,intro_booked,audit_pending,prospect,new_prospect)&select=name,status,company&limit=10" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | python3 -c "
import json, sys
rows = json.loads(sys.stdin.read()) or []
if rows:
    lines = []
    for r in rows:
        name = r.get('name') or r.get('company') or 'Unknown'
        status = r.get('status', '')
        lines.append('• ' + name + ' (' + status + ')')
    print('\n'.join(lines))
else:
    print('')
" 2>/dev/null || echo "")

if [[ -n "$NEW_CLIENT_PREP" ]]; then
  PREP_MSG="📋 New Client Prep — ${DOW} ${DATE_STR}

Leads at discovery/intro stage:
${NEW_CLIENT_PREP}

Before scoping any of these, run the Automation Readiness Audit first.
Template: prompts/automation-readiness-audit.md

This is a paid deliverable (R3,500–R6,500). Do not scope work without it."
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$PREP_MSG")}" > /dev/null \
    || echo "  New client prep Telegram send failed" >&2
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") New client prep nudge sent ($(echo "$NEW_CLIENT_PREP" | wc -l | tr -d ' ') leads)"
fi

# ── Demo Request Priority Alert ───────────────────────────────────────────────
# Surface any unscheduled demo requests as a standalone Telegram nudge

if [[ -n "$DEMO_REQUESTS" ]]; then
  DEMO_ALERT="🎯 <b>Demo Requests — ${DOW} ${DATE_STR}</b>

${DEMO_REQUESTS}

Live demo is the SMB adoption catalyst. Schedule these before anything else today.

Pitch anchors for this demo: lead scraping — 1,000 contacts in 87 seconds (vs ~1 hour manually); email triage — 1,000 emails classified in ~60 seconds via parallel agents; proposal generation — full e-sign + Stripe proposal platform built in ~20 minutes. Lead with the task they currently do manually that wastes the most time, then show the 87-second run live.
Reply: /demo [name] to mark as scheduled."
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$DEMO_ALERT"),\"parse_mode\":\"HTML\"}" > /dev/null \
    || echo "  Demo alert Telegram send failed" >&2
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Demo request alert sent"
fi

# ── Non-Standard Verticals in Pipeline ───────────────────────────────────────
# Media, entertainment, broadcast prospects — demo status visibility for Josh + Faatimah

NONSTANDARD_VERTICALS=$(curl -s "${SUPABASE_URL}/rest/v1/leads?industry=in.(media,entertainment,broadcast,Media,Entertainment,Broadcast)&status=not.eq.closed_lost&select=name,first_name,last_name,company,industry,last_contacted_at,reply_received_at,updated_at,demo_done,demo_completed,reply_sentiment,tags&limit=20" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | python3 -c "
import json, sys
from datetime import datetime

rows = json.loads(sys.stdin.read()) or []
if not rows:
    print('')
    sys.exit(0)

lines = []
for r in rows:
    # Name resolution
    name = (r.get('name') or '').strip()
    if not name:
        fn = (r.get('first_name') or '').strip()
        ln = (r.get('last_name') or '').strip()
        name = (fn + ' ' + ln).strip()
    company = (r.get('company') or '').strip()
    display = (name + ' @ ' + company) if company else (name or company or 'Unknown')

    # Last contact date
    lc_raw = r.get('last_contacted_at') or r.get('reply_received_at') or r.get('updated_at') or ''
    if lc_raw:
        try:
            lc_dt = datetime.fromisoformat(lc_raw.replace('Z', '+00:00'))
            last_contact = lc_dt.strftime('%Y-%m-%d')
        except Exception:
            last_contact = lc_raw[:10]
    else:
        last_contact = 'unknown'

    # Demo status
    demo_done = r.get('demo_done') or r.get('demo_completed') or False
    tags = r.get('tags') or []
    sentiment = r.get('reply_sentiment') or ''
    if demo_done or 'demo_done' in tags or 'demo_completed' in tags:
        demo_status = 'yes'
    elif sentiment == 'demo_request' or 'demo_request' in tags or 'demo_pending' in tags:
        demo_status = 'pending'
    else:
        demo_status = 'no'

    lines.append(display + ' — last contact ' + last_contact + ' — demo: ' + demo_status)

print('\n'.join(lines))
" 2>/dev/null || echo "")

if [[ -n "$NONSTANDARD_VERTICALS" ]]; then
  NS_MSG="📺 Non-standard verticals in pipeline — ${DOW} ${DATE_STR}

${NONSTANDARD_VERTICALS}

Demo-led sales is the wedge. Faatimah + Josh co-presenter model — prioritise any demo-pending prospects above."
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$NS_MSG")}" > /dev/null \
    || echo "  Non-standard verticals Telegram send failed" >&2
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Non-standard verticals block sent"
fi

# ── Voice AI Demo Prep Block ──────────────────────────────────────────────────
# Fires when today's calendar contains a prospect meeting in:
# recruitment, property, legal, media/entertainment
# Motivated by: 'engagement friction is the primary demo risk'
#               'early-stage honesty accelerates trust'

VOICE_DEMO_PREP=$(python3 - <<VOICEDEMOPREP 2>/dev/null || echo ""
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

# Today's date range (UTC)
today_start = datetime.datetime.utcnow().strftime('%Y-%m-%dT00:00:00Z')
today_end   = datetime.datetime.utcnow().strftime('%Y-%m-%dT23:59:59Z')

cal_rows = supa_get(
    "calendar_events?start_at=gte." + today_start +
    "&start_at=lte." + today_end +
    "&select=title,description,start_at&order=start_at.asc&limit=20"
)

VERTICALS = {
    "recruitment": {
        "keywords": ["recruit", "hiring", "talent", "staffing", "hr manager", "people ops",
                     "candidate", "headhunt", "resourcing", "placement"],
        "roi": "candidate screening calls — reduce time-to-shortlist by handling first-round qualification automatically",
        "emoji": "🧑\u200d💼",
    },
    "property": {
        "keywords": ["property", "real estate", "estate agent", "letting", "landlord", "realty",
                     "proptech", "residential", "commercial property", "development", "buy-to-let"],
        "roi": "buyer qualification calls — pre-screen enquiries so agents only speak to motivated buyers",
        "emoji": "🏠",
    },
    "legal": {
        "keywords": ["legal", "law firm", "attorney", "solicitor", "advocate", "conveyancing",
                     "litigation", "counsel", "llb", "chambers", "barrister", "paralegal"],
        "roi": "client intake calls — capture matter details and qualify new enquiries before they reach a fee earner",
        "emoji": "⚖️",
    },
    "media": {
        "keywords": ["media", "entertainment", "broadcast", "production", "content creator",
                     "studio", "publisher", "streaming", "magazine", "radio", " tv ", "television",
                     "film", "podcast", "music label"],
        "roi": "audience engagement calls — handle listener/viewer inbound and talent enquiries at scale",
        "emoji": "🎬",
    },
}

INTERNAL_TERMS = ["standup", "1:1", "catch up", "catch-up", "team sync", "internal",
                  "amalfi", "sync call", "team meeting", "retro", "sprint"]

matched = []
seen_titles = set()
for e in cal_rows:
    title = (e.get("title") or "").strip()
    title_lc = title.lower()
    desc_lc  = (e.get("description") or "").lower()
    combined = title_lc + " " + desc_lc

    if any(t in combined for t in INTERNAL_TERMS):
        continue
    if title_lc in seen_titles:
        continue

    for vertical, meta in VERTICALS.items():
        if any(k in combined for k in meta["keywords"]):
            start_raw = e.get("start_at", "")
            time_str = ""
            try:
                dt = datetime.datetime.fromisoformat(start_raw.replace("Z", "+00:00"))
                # Convert UTC → SAST (+2)
                sast = dt + datetime.timedelta(hours=2)
                time_str = sast.strftime("%H:%M SAST")
            except Exception:
                pass
            matched.append({
                "title": title or "Meeting",
                "vertical": vertical,
                "meta": meta,
                "time_str": time_str,
            })
            seen_titles.add(title_lc)
            break

if not matched:
    print("")
else:
    blocks = []
    for m in matched:
        meta = m["meta"]
        time_display = (" at " + m["time_str"]) if m["time_str"] else ""
        block = (
            meta["emoji"] + " " + m["title"] + time_display + " [" + m["vertical"].title() + "]\n\n"
            "1. Early-stage honesty framing:\n"
            "   Acknowledge it's in development — SMB owners trust vendors who don't oversell. "
            "Lead with what it does reliably today, not a roadmap.\n\n"
            "2. Engagement prompt:\n"
            '   Ask them to say something to the system so they feel the interaction, not just watch. '
            "Let them drive the first input — removes the spectator dynamic.\n\n"
            "3. Top-of-funnel ROI (" + m["vertical"].title() + "):\n"
            "   " + meta["roi"][0].upper() + meta["roi"][1:] + "."
        )
        blocks.append(block)
    print("\n\n---\n\n".join(blocks))
VOICEDEMOPREP
)

if [[ -n "$VOICE_DEMO_PREP" ]]; then
  VOICE_DEMO_MSG="🎙️ Voice AI Demo Prep — ${DOW} ${DATE_STR}

${VOICE_DEMO_PREP}

Key reminders: engagement friction is the primary demo risk. Early-stage honesty accelerates trust."
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$VOICE_DEMO_MSG")}" > /dev/null \
    || echo "  Voice AI demo prep Telegram send failed" >&2
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Voice AI demo prep block sent"
fi

task_complete "$TASK_ID" "Morning brief sent"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Morning brief complete"
