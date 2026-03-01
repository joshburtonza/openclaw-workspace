#!/usr/bin/env bash
# salah-weekly-brief.sh
# Weekly voice note for Salah — covers: AI news, recruitment/staffing industry news,
# new or incoming clients, client sentiment across the portfolio.
# Runs every Monday at 08:30 SAST.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"
unset CLAUDECODE

BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
CHAT_ID="${TELEGRAM_SALAH_CHAT_ID:-8597169435}"
KEY="${SUPABASE_SERVICE_ROLE_KEY}"
SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
BRAVE_KEY="${BRAVE_API_KEY:-}"

LOG="$WORKSPACE/out/salah-weekly-brief.log"
AUDIO_OUT="$WORKSPACE/media/outbound/salah-weekly-brief.opus"
mkdir -p "$WORKSPACE/out" "$(dirname "$AUDIO_OUT")"

log() { echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" | tee -a "$LOG"; }

tg_send_text() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' <<< "$1"),\"parse_mode\":\"HTML\"}" \
    > /dev/null 2>&1 || true
}

log "Salah weekly brief starting"

# ── Step 1: Fetch live business data ─────────────────────────────────────────
export KEY SUPABASE_URL OPENAI_API_KEY BRAVE_KEY

BUSINESS_DATA=$(python3 << 'PYEOF'
import json, urllib.request, os, datetime

KEY = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
headers = {'apikey': KEY, 'Authorization': 'Bearer ' + KEY}

def get(path):
    try:
        req = urllib.request.Request(SUPABASE_URL + '/rest/v1/' + path, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception:
        return []

# Clients
clients = get('clients?select=name,status,monthly_amount&order=created_at.desc')
active  = [c for c in clients if c.get('status') == 'active']
recent  = [c for c in clients if c.get('status') in ('active','onboarding')][:5]

# Email queue — how are client comms going
emails = get('email_queue?select=client,status,sentiment&order=created_at.desc&limit=100')
by_client = {}
for e in emails:
    c = e.get('client','unknown')
    if c not in by_client: by_client[c] = []
    by_client[c].append(e.get('sentiment') or e.get('status',''))

# CRM pipeline
leads = get('leads?select=status,ai_score,company,first_name,last_name&limit=500')
won   = [l for l in leads if l.get('status') == 'won']
hot   = [l for l in leads if (l.get('ai_score') or 0) >= 70 and l.get('status') not in ('won','unsubscribed')]

# Open tasks
tasks = get("tasks?status=in.(todo,in_progress)&order=priority.desc&limit=10")

out = {
    'active_clients': len(active),
    'client_names': [c['name'] for c in active],
    'recent_clients': [c['name'] for c in recent],
    'client_email_sentiment': {k: list(set(v))[:3] for k,v in by_client.items() if k != 'unknown'},
    'won_leads': len(won),
    'hot_prospects': [f"{l.get('first_name','')} {l.get('last_name','')} @ {l.get('company','?')} (score {l.get('ai_score','?')})" for l in hot[:3]],
    'open_tasks': len(tasks),
    'top_tasks': [t['title'] for t in tasks[:3]],
}
print(json.dumps(out))
PYEOF
)

# ── Step 2: Fetch AI + industry news via Brave ────────────────────────────────
AI_NEWS=""
STAFFING_NEWS=""

if [[ -n "$BRAVE_KEY" ]]; then
    log "Fetching AI news..."
    AI_RESP=$(curl -sf \
      "https://api.search.brave.com/res/v1/news/search?q=artificial+intelligence+AI+news+this+week&count=5&freshness=pw" \
      -H "Accept: application/json" -H "Accept-Encoding: gzip" \
      -H "X-Subscription-Token: ${BRAVE_KEY}" --compressed 2>/dev/null || echo "")

    STAFFING_RESP=$(curl -sf \
      "https://api.search.brave.com/res/v1/news/search?q=recruitment+staffing+industry+news+this+week&count=5&freshness=pw" \
      -H "Accept: application/json" -H "Accept-Encoding: gzip" \
      -H "X-Subscription-Token: ${BRAVE_KEY}" --compressed 2>/dev/null || echo "")

    if [[ -n "$AI_RESP" ]]; then
        AI_NEWS=$(echo "$AI_RESP" | python3 -c "
import json,sys,os
try:
    d = json.loads(sys.stdin.read())
    results = d.get('results', [])
    lines = []
    for r in results[:5]:
        lines.append(r.get('title','') + ' — ' + r.get('description','')[:120])
    print('\n'.join(lines))
except: pass
" 2>/dev/null || true)
    fi

    if [[ -n "$STAFFING_RESP" ]]; then
        STAFFING_NEWS=$(echo "$STAFFING_RESP" | python3 -c "
import json,sys,os
try:
    d = json.loads(sys.stdin.read())
    results = d.get('results', [])
    lines = []
    for r in results[:5]:
        lines.append(r.get('title','') + ' — ' + r.get('description','')[:120])
    print('\n'.join(lines))
except: pass
" 2>/dev/null || true)
    fi
fi

# ── Step 3: GPT-4o generates the brief script ────────────────────────────────
log "Generating brief text with GPT-4o..."

export BUSINESS_DATA AI_NEWS STAFFING_NEWS

BRIEF_TEXT=$(python3 << 'PYEOF'
import json, os, urllib.request

OPENAI_KEY    = os.environ.get('OPENAI_API_KEY','')
BUSINESS_DATA = os.environ.get('BUSINESS_DATA','{}')
AI_NEWS       = os.environ.get('AI_NEWS','(unavailable)')
STAFFING_NEWS = os.environ.get('STAFFING_NEWS','(unavailable)')

try:
    biz = json.loads(BUSINESS_DATA)
except Exception:
    biz = {}

prompt = f"""You are writing a short, warm weekly briefing for Salah — co-founder of Amalfi AI, a South African AI agency.

Salah is NOT technical. Write everything in plain, natural spoken English — like a smart colleague giving a Monday morning update. No jargon. No bullet points in the voice script — it needs to flow naturally when read aloud.

This will be converted to audio and sent as a voice note, so write it as spoken words, not a document.

Cover all four areas below. Keep it under 350 words total. Warm and energetic tone.

BUSINESS DATA:
- Active clients: {biz.get('active_clients', '?')} — {', '.join(biz.get('client_names', []))}
- Hot prospects (score 70+): {', '.join(biz.get('hot_prospects', [])) or 'none this week'}
- Deals won this month: {biz.get('won_leads', 0)}
- Client email sentiments: {json.dumps(biz.get('client_email_sentiment', {}))}
- Open tasks: {biz.get('open_tasks', 0)} — top: {', '.join(biz.get('top_tasks', []))}

AI NEWS THIS WEEK:
{AI_NEWS or '(search unavailable — skip this section)'}

RECRUITMENT & STAFFING INDUSTRY NEWS:
{STAFFING_NEWS or '(search unavailable — skip this section)'}

Structure the voice note like this:
1. Friendly Monday greeting to Salah
2. What's happening in AI this week (plain language, why it matters to us)
3. What's happening in the recruitment and staffing space (trends, shifts, our opportunity)
4. Our client situation — how many active, who's new or coming on board, overall vibe
5. Quick close — anything hot in the pipeline, what to watch this week

Write the full spoken script now. No headers, no lists — just natural speech."""

if not OPENAI_KEY:
    print("Good morning Salah. Your weekly brief is ready but the AI news fetch was unavailable this week. Check back on the business dashboard for client updates.")
else:
    data = json.dumps({
        'model': 'gpt-4o',
        'messages': [{'role': 'user', 'content': prompt}],
        'max_tokens': 600,
        'temperature': 0.75,
    }).encode()
    req = urllib.request.Request(
        'https://api.openai.com/v1/chat/completions',
        data=data,
        headers={'Authorization': f'Bearer {OPENAI_KEY}', 'Content-Type': 'application/json'},
        method='POST'
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            resp = json.loads(r.read())
            print(resp['choices'][0]['message']['content'].strip())
    except Exception as e:
        print(f"Brief generation failed: {e}")
PYEOF
)

if [[ -z "$BRIEF_TEXT" ]]; then
    log "Brief text empty — sending text fallback"
    tg_send_text "Good morning Salah — your weekly brief could not be generated this week. Check Mission Control for the latest."
    exit 1
fi

log "Brief text: ${BRIEF_TEXT:0:200}..."

# ── Step 4: Convert to voice ──────────────────────────────────────────────────
TTS_OK="false"
if bash "$WORKSPACE/scripts/tts/openai-tts.sh" "$BRIEF_TEXT" "$AUDIO_OUT" 2>/dev/null; then
    TTS_OK="true"
    log "TTS succeeded (OpenAI)"
elif echo "$BRIEF_TEXT" | bash "$WORKSPACE/scripts/tts/minimax-tts-to-opus.sh" --out "$AUDIO_OUT" 2>/dev/null; then
    TTS_OK="true"
    log "TTS succeeded (MiniMax fallback)"
else
    log "TTS failed — sending as text"
fi

# ── Step 5: Send ──────────────────────────────────────────────────────────────
if [[ "$TTS_OK" == "true" && -f "$AUDIO_OUT" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendVoice" \
      -F "chat_id=${CHAT_ID}" \
      -F "voice=@${AUDIO_OUT}" \
      > /dev/null 2>&1 || true
    log "Voice note sent to Salah"
else
    # Send as text if TTS failed
    tg_send_text "<b>Your weekly brief</b>\n\n${BRIEF_TEXT}"
    log "Text brief sent to Salah (TTS unavailable)"
fi
