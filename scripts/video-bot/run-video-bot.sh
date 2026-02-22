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

  # Idempotency: if scripts already exist today, do nothing.
  local existing
  existing=$(supa_get_today_count || echo "0")
  if [[ "$existing" -ge 4 ]]; then
    echo "Video Bot: scripts already present for today ($existing) — skipping"
    exit 0
  fi

  echo "Video Bot: generating scripts for $day (youtube_day=$youtube_day)..."

  # Write prompt to temp file (stdin redirect — avoids quoting issues)
  PROMPT_TMP=$(mktemp /tmp/video-bot-prompt-XXXXXX)
  cat > "$PROMPT_TMP" <<PROMPT
You are Video Bot for Josh Burton (Amalfi AI, South Africa).

Generate content scripts in STRICT JSON only. No commentary, no markdown fences, just raw JSON.

Rules:
- 4 TikTok scripts every day
- Also 2 YouTube scripts only if today is Monday or Thursday (today is: $day; youtube_day=$youtube_day)
- South African English, warm, direct, no corporate speak
- No dashes or hyphens in the writing
- TikTok uses Callaway Method: hook, 6 to 10 lines, dopamine hits, payoff

Return JSON with shape:
{
  "tiktoks": [{"title": string, "category": string, "hook": string, "script_lines": [string], "payoff": string}],
  "youtubes": [{"title": string, "hook": string, "sections": [{"heading": string, "points": [string]}], "cta": string, "thumbnail": string}]
}

Constraints:
- Ensure at least 1 TikTok is from categories 7, 8, or 9:
  7 Make it make sense
  8 What I told my telemarketer
  9 The OpenClaw Build Series

Categories list:
1 AI agency automation
2 Client success systems
3 Building in public
4 Cold outreach sales
5 Killing debt
6 Personal brand
7 Make it make sense
8 What I told my telemarketer
9 The OpenClaw Build Series
PROMPT

  # Run Claude — use stdin redirect (not arg passing — avoids quoting failures)
  unset CLAUDECODE
  local json
  json=$(claude --print \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    < "$PROMPT_TMP" 2>/dev/null)
  rm -f "$PROMPT_TMP"

  if [[ -z "$json" ]]; then
    echo "Video Bot: Claude returned empty response" >&2
    exit 1
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
