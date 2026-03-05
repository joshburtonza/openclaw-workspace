#!/usr/bin/env bash
set -euo pipefail

# Content Ideas Bot: generate LinkedIn posts + TikTok scripts for Josh + Salah
# Fires daily at 7:15am SAST (after Video Bot at 7am)
# Inserts into Supabase tasks, visible in Mission Control

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"

# Load secrets
ENV_FILE="$ROOT/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-${SUPABASE_ANON_KEY:-}}"

MODEL="claude-sonnet-4-6"

export SUPABASE_URL SUPABASE_KEY

# ── Daily marker (one-shot, no re-runs) ──────────────────────────────────────
MARKER_DIR="$ROOT/tmp/content-ideas"
MARKER_FILE="$MARKER_DIR/done-$(date +%Y-%m-%d).txt"
mkdir -p "$MARKER_DIR"
if [[ -f "$MARKER_FILE" ]]; then
  echo "Content Ideas: already ran today — skipping"
  exit 0
fi
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") attempt" > "$MARKER_FILE"

# ── Load recent context for richer, timely content ───────────────────────────
MEMORY=$(cat "$ROOT/memory/MEMORY.md" 2>/dev/null | head -200 || echo "")
STATE=$(cat "$ROOT/CURRENT_STATE.md" 2>/dev/null | head -100 || echo "")
YESTERDAY_LOG=$(cat "$ROOT/memory/$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d).md" 2>/dev/null | head -150 || echo "")
TODAY=$(date '+%A, %d %B %Y')

# ── Generate for each person ─────────────────────────────────────────────────
generate_for() {
  local person="$1"
  local system_file="$2"
  local assigned_to="$3"
  local tag="$4"

  echo "Content Ideas: generating for $person..."

  PROMPT_TMP=$(mktemp /tmp/content-ideas-XXXXXX)
  cat > "$PROMPT_TMP" <<PROMPT
$(cat "$system_file")

## RECENT CONTEXT (use this for timely, specific content)

Today is $TODAY.

### What has been happening at Amalfi AI recently:
$MEMORY

### Current system state:
$STATE

### What happened yesterday:
$YESTERDAY_LOG

## TODAY'S TASK

Generate 3 LinkedIn post drafts AND 3 TikTok script drafts for $person.

Each piece must be from a DIFFERENT category. Make them varied in tone and topic.

Use the recent context above to make at least 1 LinkedIn post AND 1 TikTok about something SPECIFIC that happened this week (a feature shipped, a client interaction, a system update, etc). The others can be more evergreen but still grounded in real experience.

Return JSON with this exact shape:
{
  "posts": [
    {
      "category": "string (which category from the list above)",
      "hook": "string (the first 1-2 lines that show before see more)",
      "body": "string (the full post body including hook, with line breaks as newlines)",
      "closer": "string (the closing line or question)"
    }
  ],
  "tiktoks": [
    {
      "category": "string (which category from the list above)",
      "hook": "string (the first 1-2 seconds, pattern interrupt)",
      "script": "string (6-10 lines, each a sentence to say on camera, separated by newlines)",
      "payoff": "string (the final memorable line)"
    }
  ]
}
PROMPT

  unset CLAUDECODE
  local json
  json=$(/Users/henryburton/.openclaw/bin/claude-gated --print \
    --dangerously-skip-permissions \
    --model "$MODEL" \
    < "$PROMPT_TMP" 2>/dev/null) || json=""
  rm -f "$PROMPT_TMP"

  if [[ -z "$json" ]]; then
    echo "Content Ideas: Claude returned empty for $person — skipping" >&2
    return
  fi

  # Strip markdown fences if present
  json=$(echo "$json" | python3 -c '
import sys, re
t = sys.stdin.read().strip()
t = re.sub(r"^[`]{3}json\s*", "", t)
t = re.sub(r"^[`]{3}\s*", "", t)
t = re.sub(r"[`]{3}\s*$", "", t)
print(t.strip())
')

  # Parse and insert into Supabase tasks
  export CONTENT_JSON="$json"
  export CONTENT_PERSON="$person"
  export CONTENT_ASSIGNED="$assigned_to"
  export CONTENT_TAG="$tag"
  python3 - <<'PY'
import json, os, requests

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_KEY']
person = os.environ['CONTENT_PERSON']
assigned = os.environ['CONTENT_ASSIGNED']
tag = os.environ['CONTENT_TAG']

data = os.environ.get('CONTENT_JSON', '')
try:
    obj = json.loads(data)
except Exception as e:
    raise SystemExit(f"Failed to parse JSON for {person}: {e}\nRaw:\n{data[:800]}")

url = SUPABASE_URL + '/rest/v1/tasks'
headers = {
    'apikey': KEY,
    'Authorization': f'Bearer {KEY}',
    'Content-Type': 'application/json',
    'Prefer': 'return=minimal',
}
inserted = 0

# Insert LinkedIn posts
for p in obj.get('posts', [])[:3]:
    category = p.get('category', '').strip()
    hook = p.get('hook', '').strip()
    body = p.get('body', '').strip()
    closer = p.get('closer', '').strip()

    title = f'[LinkedIn] {hook[:80]}'
    desc = f'CATEGORY: {category}\n\nHOOK:\n{hook}\n\nBODY:\n{body}\n\nCLOSER:\n{closer}'

    payload = {
        'title': title,
        'description': desc,
        'priority': 'normal',
        'status': 'todo',
        'assigned_to': assigned,
        'created_by': 'Content Bot',
        'tags': ['linkedin', 'content', tag],
    }
    r = requests.post(url, headers=headers, json=payload)
    r.raise_for_status()
    inserted += 1
    print(f"  Inserted for {person}: {title[:60]}")

# Insert TikTok scripts
for t in obj.get('tiktoks', [])[:3]:
    category = t.get('category', '').strip()
    hook = t.get('hook', '').strip()
    script = t.get('script', '').strip()
    payoff = t.get('payoff', '').strip()

    title = f'[TikTok] {hook[:80]}'
    desc = f'CATEGORY: {category}\n\nHOOK:\n{hook}\n\nSCRIPT:\n{script}\n\nPAYOFF:\n{payoff}'

    payload = {
        'title': title,
        'description': desc,
        'priority': 'normal',
        'status': 'todo',
        'assigned_to': assigned,
        'created_by': 'Content Bot',
        'tags': ['tiktok', 'content', tag],
    }
    r = requests.post(url, headers=headers, json=payload)
    r.raise_for_status()
    inserted += 1
    print(f"  Inserted for {person}: {title[:60]}")

print(f"Content Ideas: {inserted} items inserted for {person} (LinkedIn + TikTok)")
PY
}

# ── Run for both ─────────────────────────────────────────────────────────────
generate_for "Josh" "$ROOT/scripts/content-ideas/josh-content-system.md" "Josh" "josh"
generate_for "Salah" "$ROOT/scripts/content-ideas/salah-content-system.md" "Salah" "salah"

echo "Content Ideas: done for $(date +%Y-%m-%d)"
