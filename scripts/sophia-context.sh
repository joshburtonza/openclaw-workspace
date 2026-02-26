#!/bin/bash
# sophia-context.sh
# Builds Sophia's full context block for a given client before she responds.
# Pulls: email trail (inbound + outbound), GitHub commits, meeting notes, client notes.
#
# Usage: bash sophia-context.sh <client_slug>
#   client_slug: ascend_lc | favorite_logistics | race_technik
#
# Output: formatted plain-text context block, ready to inject into a prompt.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

CLIENT_SLUG="${1:-}"
if [[ -z "$CLIENT_SLUG" ]]; then
  echo "Usage: $0 <client_slug>" >&2
  exit 1
fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
MEETING_JOURNAL="$WS/memory/meeting-journal.md"
GITHUB_SCRIPT="$WS/sophia-github-context.sh"

# ── Client → metadata mapping ─────────────────────────────────────────────────
export CLIENT_SLUG
MAPPING=$(python3 - <<'PY'
import os
slug = os.environ['CLIENT_SLUG']
mapping = {
    'ascend_lc': {
        'name': 'Ascend LC',
        'journal_section': 'QMS-GUARD',
        'github_owner': 'joshburtonza',
        'github_repo': 'qms-guard',
    },
    'favorite_logistics': {
        'name': 'Favlog / FLAIR',
        'journal_section': 'FAVORITE-LOGISTICS',
        'github_owner': 'joshburtonza',
        'github_repo': 'favorite-flow-9637aff2',
    },
    'race_technik': {
        'name': 'Race Technik',
        'journal_section': 'CHROME-AUTO-CARE',
        'github_owner': 'joshburtonza',
        'github_repo': 'chrome-auto-care',
    },
}
import json
print(json.dumps(mapping.get(slug, {})))
PY
)

export MAPPING
CLIENT_NAME=$(python3 -c "import json,os; d=json.loads(os.environ['MAPPING']); print(d.get('name', os.environ['CLIENT_SLUG']))")
JOURNAL_SECTION=$(python3 -c "import json,os; d=json.loads(os.environ['MAPPING']); print(d.get('journal_section',''))")
GH_OWNER=$(python3 -c "import json,os; d=json.loads(os.environ['MAPPING']); print(d.get('github_owner',''))")
GH_REPO=$(python3 -c "import json,os; d=json.loads(os.environ['MAPPING']); print(d.get('github_repo',''))")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CLIENT CONTEXT: ${CLIENT_NAME} (${CLIENT_SLUG})"
echo "Built: $(date '+%A %d %B %Y %H:%M SAST')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Email trail (inbound + outbound, last 15) ──────────────────────────────
echo ""
echo "── EMAIL TRAIL (last 15) ──"
echo ""

export KEY SUPABASE_URL CLIENT_SLUG
python3 - <<'PY'
import urllib.request, json, os

url  = os.environ['SUPABASE_URL']
key  = os.environ['KEY']
slug = os.environ['CLIENT_SLUG']

req = urllib.request.Request(
    f"{url}/rest/v1/email_queue"
    f"?client=eq.{slug}"
    f"&select=from_email,subject,body,status,created_at,analysis"
    f"&order=created_at.desc&limit=15",
    headers={"apikey": key, "Authorization": f"Bearer {key}"},
)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        rows = json.loads(r.read())
except Exception as e:
    print(f"  (could not fetch email trail: {e})")
    rows = []

if not rows:
    print("  No emails on record for this client.")
else:
    for row in rows:
        status   = row.get('status', '?')
        subject  = row.get('subject', '(no subject)')
        from_e   = row.get('from_email', '')
        created  = (row.get('created_at') or '')[:16].replace('T', ' ')
        body     = (row.get('body') or '').strip()
        raw_anal = row.get('analysis') or {}
        if isinstance(raw_anal, str):
            try: raw_anal = json.loads(raw_anal)
            except Exception: raw_anal = {}
        analysis = raw_anal if isinstance(raw_anal, dict) else {}
        draft    = (analysis.get('draft_body') or '').strip()

        # Direction label
        if from_e and 'sophia' not in from_e.lower() and 'amalfiai' not in from_e.lower():
            direction = f"INBOUND from {from_e}"
        else:
            direction = f"OUTBOUND ({status})"

        print(f"[{created}] {direction}")
        print(f"  Subject: {subject}")

        # Show body for inbound, draft for outbound pending
        content = body or draft
        if content:
            preview = content[:300].replace('\n', ' ').strip()
            if len(content) > 300:
                preview += '…'
            print(f"  Preview: {preview}")
        print()
PY

# ── 2. GitHub commits (last 14 days) ─────────────────────────────────────────
echo ""
echo "── GITHUB COMMITS (last 14 days) ──"
echo ""

if [[ -n "$GH_OWNER" && -n "$GH_REPO" ]]; then
    SINCE=$(python3 -c "from datetime import datetime,timezone,timedelta; print((datetime.now(timezone.utc)-timedelta(days=14)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    export GH_OWNER GH_REPO SINCE
    python3 - <<'PY'
import urllib.request, json, os, re

owner = os.environ['GH_OWNER']
repo  = os.environ['GH_REPO']
since = os.environ['SINCE']

def humanise(msg):
    msg = re.sub(r'^(feat|fix|chore|refactor|docs|style|test|perf|ci|build|wip)(\([\w\-]+\))?:\s*', '', msg, flags=re.IGNORECASE)
    msg = re.sub(r'\s*#\d+', '', msg).strip()
    return (msg[0].upper() + msg[1:]) if msg else msg

try:
    req = urllib.request.Request(
        f"https://api.github.com/repos/{owner}/{repo}/commits?per_page=20&since={since}",
        headers={"User-Agent": "sophia-context/1.0"},
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        commits = json.loads(r.read())
except Exception as e:
    print(f"  (could not fetch commits: {e})")
    commits = []

seen = set()
count = 0
for c in commits:
    msg = ((c.get('commit') or {}).get('message') or '').split('\n')[0].strip()
    if not msg or msg.lower().startswith('merge'):
        continue
    h = humanise(msg)
    if h and h not in seen:
        seen.add(h)
        date = (((c.get('commit') or {}).get('author') or {}).get('date') or '')[:10]
        print(f"  [{date}] {h}")
        count += 1
    if count >= 15:
        break

if count == 0:
    print("  No commits in the last 14 days.")
PY
else
    echo "  (no GitHub repo configured for this client)"
fi

# ── 3. Meeting notes ──────────────────────────────────────────────────────────
echo ""
echo "── MEETING NOTES ──"
echo ""

if [[ -f "$MEETING_JOURNAL" && -n "$JOURNAL_SECTION" ]]; then
    export MEETING_JOURNAL JOURNAL_SECTION
    python3 - <<'PY'
import os, re

path    = os.environ['MEETING_JOURNAL']
section = os.environ['JOURNAL_SECTION']

with open(path, 'r') as f:
    content = f.read()

# Find the ## SECTION-NAME block and extract everything up to the next ## heading
pattern = rf'(?m)^## {re.escape(section)}\s*\n(.*?)(?=\n^## |\Z)'
match = re.search(pattern, content, re.DOTALL | re.MULTILINE)

if match:
    block = match.group(1).strip()
    if block:
        print(block)
    else:
        print("  (section found but no content)")
else:
    print(f"  (no meeting notes found for section: {section})")
    print("  Tip: add a '## " + section + "' section to memory/meeting-journal.md")
PY
else
    echo "  (meeting journal not found or no section mapping)"
fi

# ── 4. Client profile notes ───────────────────────────────────────────────────
echo ""
echo "── CLIENT PROFILE & NOTES ──"
echo ""

export KEY SUPABASE_URL CLIENT_SLUG
python3 - <<'PY'
import urllib.request, json, os

url  = os.environ['SUPABASE_URL']
key  = os.environ['KEY']
slug = os.environ['CLIENT_SLUG']

req = urllib.request.Request(
    f"{url}/rest/v1/clients?slug=eq.{slug}&select=name,notes,profile,sentiment,updated_at",
    headers={"apikey": key, "Authorization": f"Bearer {key}"},
)
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        rows = json.loads(r.read())
except Exception as e:
    print(f"  (could not fetch client profile: {e})")
    rows = []

if not rows:
    print("  Client not found in DB.")
else:
    c = rows[0]
    print(f"  Sentiment: {c.get('sentiment', 'unknown')}")
    print(f"  Last updated: {(c.get('updated_at') or '')[:10]}")
    notes = (c.get('notes') or '').strip()
    if notes:
        print(f"\n  Notes:\n{notes[:800]}")
        if len(notes) > 800:
            print("  … (truncated)")
PY

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
