#!/usr/bin/env bash
set -euo pipefail

# Video Bot runner: generate scripts + INSERT into Supabase tasks.
# Goal: make "7am Daily Morning Video Scripts" actually populate Mission Control Content.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"

# Load secrets
ENV_FILE="$ROOT/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${SUPABASE_ANON_KEY:-}}"

MODEL="claude-sonnet-4-6"

export SUPABASE_URL SUPABASE_KEY

supa_get_today_count() {
  # Counts Video Bot scripts created today (local day, SAST)
  python3 - <<'PY'
import datetime, os, requests
from urllib.parse import urlencode

SUPABASE_URL=os.environ['SUPABASE_URL']
KEY=os.environ['SUPABASE_KEY']

# SAST day window
SAST=datetime.timezone(datetime.timedelta(hours=2))
now=datetime.datetime.now(SAST)
start=now.replace(hour=0, minute=0, second=0, microsecond=0)
end=start+datetime.timedelta(days=1)

qs = urlencode([
  ('select','id'),
  ('created_by','eq.Video Bot'),
  ('created_at',f'gte.{start.isoformat()}'),
  ('created_at',f'lt.{end.isoformat()}'),
])
url=f"{SUPABASE_URL}/rest/v1/tasks?{qs}"
resp=requests.get(url, headers={'apikey':KEY,'Authorization':f'Bearer {KEY}'}, timeout=20)
resp.raise_for_status()
print(len(resp.json()))
PY
}

main() {
  local day youtube_day
  day="$(date +%A)"
  youtube_day=false
  [[ "$day" == "Monday" || "$day" == "Thursday" ]] && youtube_day=true

  # Daily marker — one-shot agent, runs once per day. Mark attempted immediately
  # so any error-monitor restart or accidental re-run is a no-op.
  local MARKER_DIR="$ROOT/tmp/video-bot"
  local MARKER_FILE="$MARKER_DIR/done-$(date +%Y-%m-%d).txt"
  mkdir -p "$MARKER_DIR"
  if [[ -f "$MARKER_FILE" ]]; then
    echo "Video Bot: already ran today (marker exists) — skipping"
    exit 0
  fi
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") attempt" > "$MARKER_FILE"

  # Idempotency: if scripts already exist today, do nothing.
  local existing
  existing=$(supa_get_today_count || echo "0")
  if [[ "$existing" -ge 4 ]]; then
    echo "Video Bot: scripts already present for today ($existing) — skipping"
    exit 0
  fi

  echo "Video Bot: generating scripts for $day (youtube_day=$youtube_day)..."

  # Load system prompt from file + add today's instructions
  SYSTEM_PROMPT_FILE="$ROOT/scripts/video-bot/video-bot-system.md"
  PROMPT_TMP=$(mktemp /tmp/video-bot-prompt-XXXXXX)
  cat > "$PROMPT_TMP" <<PROMPT
$(cat "$SYSTEM_PROMPT_FILE")

## TODAY'S TASK

Today is $day. Generate:
- 4 TikTok scripts (at least 1 from categories 7, 8, or 9)
$(if $youtube_day; then echo "- 2 YouTube scripts (today is a YouTube day)"; else echo "- No YouTube scripts today (YouTube is Mon + Thu only)"; fi)

Make every script different in tone and category. Do not repeat categories across the 4 TikToks. Mix it up.

Return JSON with this exact shape:
{
  "tiktoks": [{"title": string, "category": string, "hook": string, "script_lines": [string], "payoff": string}],
  "youtubes": [{"title": string, "hook": string, "sections": [{"heading": string, "points": [string]}], "cta": string, "thumbnail": string}]
}

If no YouTube scripts today, return "youtubes": [].
PROMPT

  # Run Claude — use stdin redirect (not arg passing — avoids quoting failures)
  unset CLAUDECODE
  local json
  json=$(/Users/henryburton/.openclaw/bin/claude-gated --print \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    < "$PROMPT_TMP" 2>/dev/null)
  rm -f "$PROMPT_TMP"

  if [[ -z "$json" ]]; then
    echo "Video Bot: Claude returned empty response — token may be expired, skipping today" >&2
    exit 0  # Exit 0: marker file already written, won't retry today. No error-monitor spin loop.
  fi

  # Strip markdown fences if Claude added them anyway
  json=$(echo "$json" | python3 -c '
import sys, re
t = sys.stdin.read().strip()
t = re.sub(r"^[`]{3}json\s*", "", t)
t = re.sub(r"^[`]{3}\s*", "", t)
t = re.sub(r"[`]{3}\s*$", "", t)
print(t.strip())
')

  # Parse JSON → build insert list → insert into Supabase
  # Pass json via env var to avoid stdin conflict with heredoc
  export VIDEO_BOT_JSON="$json"
  python3 - <<'PY'
import json, sys, os, requests

SUPABASE_URL=os.environ['SUPABASE_URL']
KEY=os.environ['SUPABASE_KEY']

data=os.environ.get('VIDEO_BOT_JSON','')
try:
    obj=json.loads(data)
except Exception as e:
    raise SystemExit(f"Failed to parse JSON from Claude: {e}\nRaw:\n{data[:800]}")

items=[]

for t in obj.get('tiktoks',[])[:4]:
    title='[TikTok] '+t.get('title','').strip()
    cat=t.get('category','').strip()
    hook=t.get('hook','').strip()
    lines=t.get('script_lines',[]) or []
    payoff=t.get('payoff','').strip()
    body='CATEGORY: '+cat+'\nHOOK: '+hook+'\n\nSCRIPT:\n'+'\n'.join([f'Line {i+1}: {l}' for i,l in enumerate(lines)])
    if payoff:
        body += '\n\nPAYOFF: '+payoff
    items.append({'title': title, 'desc': body, 'tags': ['tiktok','content']})

for y in (obj.get('youtubes',[]) or [])[:2]:
    title='[YouTube] '+y.get('title','').strip()
    hook=y.get('hook','').strip()
    sections=y.get('sections',[]) or []
    cta=y.get('cta','').strip()
    thumb=y.get('thumbnail','').strip()
    parts=['HOOK: '+hook, '']
    for s in sections:
        parts.append(s.get('heading','').strip())
        for p in s.get('points',[]) or []:
            parts.append('- '+str(p).strip())
        parts.append('')
    if cta:
        parts.append('CTA: '+cta)
    if thumb:
        parts.append('THUMBNAIL: '+thumb)
    items.append({'title': title, 'desc': '\n'.join(parts).strip(), 'tags': ['youtube','content']})

url=SUPABASE_URL+'/rest/v1/tasks'
inserted=0
for it in items:
    payload={
        'title': it['title'],
        'description': it['desc'],
        'priority': 'normal',
        'status': 'todo',
        'assigned_to': 'Josh',
        'created_by': 'Video Bot',
        'tags': it['tags'],
    }
    r=requests.post(url, headers={'apikey':KEY,'Authorization':f'Bearer {KEY}','Content-Type':'application/json','Prefer':'return=minimal'}, json=payload)
    r.raise_for_status()
    inserted+=1
    print(f"  Inserted: {it['title']}")

print(f"Video Bot: done — {inserted} scripts inserted into Supabase tasks")
PY
}

main "$@"
