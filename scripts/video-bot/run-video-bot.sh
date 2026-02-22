#!/usr/bin/env bash
set -euo pipefail

# Video Bot runner: generate scripts + INSERT into Supabase tasks.
# Goal: make "7am Daily Morning Video Scripts" actually populate Mission Control Content.

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

MODEL="claude-sonnet-4-6"

log_status() {
  if [[ -x "$ROOT/alex-status.sh" ]]; then
    bash "$ROOT/alex-status.sh" "$@" || true
  fi
}

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

# PostgREST filters
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

insert_task() {
  local title="$1"
  local desc="$2"
  local tags_json="$3"

  curl -sS -X POST "$SUPABASE_URL/rest/v1/tasks" \
    -H "apikey: $SUPABASE_KEY" \
    -H "Authorization: Bearer $SUPABASE_KEY" \
    -H 'Content-Type: application/json' \
    -H 'Prefer: return=minimal' \
    -d "{\"title\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$title"),\"description\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$desc"),\"priority\":\"normal\",\"status\":\"todo\",\"assigned_to\":\"Josh\",\"created_by\":\"Video Bot\",\"tags\":$tags_json}" \
    >/dev/null
}

main() {
  export SUPABASE_URL SUPABASE_KEY

  log_status start "Video Bot: generating scripts"

  local day youtube_day
  day="$(date +%A)"
  youtube_day=false
  [[ "$day" == "Monday" || "$day" == "Thursday" ]] && youtube_day=true

  # Idempotency: if scripts already exist today, do nothing.
  local existing
  existing=$(supa_get_today_count || echo "0")
  if [[ "$existing" -ge 4 ]]; then
    log_status done "Video Bot: scripts already present for today ($existing)"
    exit 0
  fi

  # Generate JSON so we can parse reliably.
  local json
  json=$(claude -p --model "$MODEL" "You are Video Bot for Josh Burton (Amalfi AI, South Africa).\n\nGenerate content scripts in STRICT JSON only. No commentary.\n\nRules:\n- 4 TikTok scripts every day\n- Also 2 YouTube scripts only if today is Monday or Thursday (today is: $day; youtube_day=$youtube_day)\n- South African English, warm, direct, no corporate speak\n- No dashes or hyphens in the writing\n- TikTok uses Callaway Method: hook, 6 to 10 lines, dopamine hits, payoff\n\nReturn JSON with shape:\n{\n  \"tiktoks\": [{\"title\": string, \"category\": string, \"hook\": string, \"script_lines\": [string], \"payoff\": string}],\n  \"youtubes\": [{\"title\": string, \"hook\": string, \"sections\": [{\"heading\": string, \"points\": [string]}], \"cta\": string, \"thumbnail\": string}]\n}\n\nConstraints:\n- Ensure at least 1 TikTok is from categories 7, 8, or 9:\n  7 Make it make sense\n  8 What I told my telemarketer\n  9 The OpenClaw Build Series\n\nCategories list:\n1 AI agency automation\n2 Client success systems\n3 Building in public\n4 Cold outreach sales\n5 Killing debt\n6 Personal brand\n7 Make it make sense\n8 What I told my telemarketer\n9 The OpenClaw Build Series\n")

  # Validate and insert
  python3 - <<'PY'
import json, sys, os, textwrap

data=sys.stdin.read()
try:
    obj=json.loads(data)
except Exception as e:
    raise SystemExit(f"Failed to parse JSON from Claude: {e}\nRaw:\n{data[:800]}")

def ins(title, desc, tags):
    import subprocess
    cmd=[
        'bash','-lc',
        f"insert_task {json.dumps(title)} {json.dumps(desc)} '{json.dumps(tags)}'"
    ]
    # use parent shell function via env - we call through bash -lc with function exported? not available.

# We'll just emit a shell-friendly plan and let bash loop insert.

out=[]
for t in obj.get('tiktoks',[])[:4]:
    title='[TikTok] '+t.get('title','').strip()
    cat=t.get('category','').strip()
    hook=t.get('hook','').strip()
    lines=t.get('script_lines',[]) or []
    payoff=t.get('payoff','').strip()
    body='CATEGORY: '+cat+"\nHOOK: "+hook+"\n\nSCRIPT:\n"+"\n".join([f"Line {i+1}: {l}" for i,l in enumerate(lines)])
    if payoff:
        body += "\n\nPAYOFF: "+payoff
    out.append({'title': title, 'desc': body, 'tags': ['tiktok','content']})

for y in (obj.get('youtubes',[]) or [])[:2]:
    title='[YouTube] '+y.get('title','').strip()
    hook=y.get('hook','').strip()
    sections=y.get('sections',[]) or []
    cta=y.get('cta','').strip()
    thumb=y.get('thumbnail','').strip()
    parts=["HOOK: "+hook, ""]
    for s in sections:
        parts.append(s.get('heading','').strip())
        for p in s.get('points',[]) or []:
            parts.append('- '+str(p).strip())
        parts.append('')
    if cta:
        parts.append('CTA: '+cta)
    if thumb:
        parts.append('THUMBNAIL: '+thumb)
    out.append({'title': title, 'desc': "\n".join(parts).strip(), 'tags': ['youtube','content']})

print(json.dumps(out))
PY
  <<<"$json" \
  | python3 - <<'PY'
import json, sys, subprocess
items=json.load(sys.stdin)
for it in items:
    title=it['title']
    desc=it['desc']
    tags=it['tags']
    # call the bash insert_task function by executing this script itself with a special env
    # simpler: call curl directly here
    import os, requests
    url=os.environ['SUPABASE_URL']+'/rest/v1/tasks'
    key=os.environ['SUPABASE_KEY']
    payload={
        'title': title,
        'description': desc,
        'priority': 'normal',
        'status': 'todo',
        'assigned_to': 'Josh',
        'created_by': 'Video Bot',
        'tags': tags,
    }
    r=requests.post(url, headers={'apikey':key,'Authorization':f'Bearer {key}','Content-Type':'application/json','Prefer':'return=minimal'}, json=payload)
    r.raise_for_status()
print(f"inserted {len(items)}")
PY

  log_status done "Video Bot: scripts generated and inserted"
}

main "$@"
