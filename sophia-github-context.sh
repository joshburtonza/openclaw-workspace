#!/bin/bash
# sophia-github-context.sh
#
# Fetches recent GitHub commits for a client's repos and formats them
# in plain, human-readable English — suitable for Sophia to reference
# when explaining progress to non-technical clients.
#
# Usage: bash sophia-github-context.sh [CLIENT_SLUG]
#   CLIENT_SLUG: ascend_lc | favorite_logistics
#   If omitted: prints context for ALL clients.
#
# Output: plain text block per client with recent commits

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

TARGET_SLUG="${1:-}"

# ── Fetch client repos from DB (profile JSONB) ────────────────────────────────
# Falls back to hardcoded map if profile column doesn't exist yet
if [[ -n "$TARGET_SLUG" ]]; then
  FILTER="slug=eq.${TARGET_SLUG}&"
else
  FILTER=""
fi

CLIENTS_JSON=$(curl -s "${SUPABASE_URL}/rest/v1/clients?${FILTER}select=slug,name,profile&status=eq.active" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}")

# If profile column not yet migrated, fall back gracefully
if echo "$CLIENTS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if isinstance(d,list) else 1)" 2>/dev/null; then
  : # OK, it's a list
else
  # Treat as error — use fallback below
  CLIENTS_JSON="[]"
fi

# ── Process each client ────────────────────────────────────────────────────────
export CLIENTS_JSON TARGET_SLUG
python3 - <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timezone, timedelta

CLIENTS_JSON = os.environ["CLIENTS_JSON"]

# Hardcoded repo map — fallback when DB profile not yet populated
REPO_FALLBACK = {
    "ascend_lc": {
        "name": "Ascend LC",
        "repos": [{"owner": "joshburtonza", "name": "qms-guard"}],
    },
    "favorite_logistics": {"name": "Favorite Logistics", "repos": []},
}

try:
    clients = json.loads(CLIENTS_JSON)
except Exception:
    clients = []

# If DB returned empty (not yet populated), use fallback
if not clients:
    fallback_slugs = [os.environ.get("TARGET_SLUG", "")] if os.environ.get("TARGET_SLUG") else list(REPO_FALLBACK.keys())
    clients = []
    for s in fallback_slugs:
        if s in REPO_FALLBACK:
            fb = REPO_FALLBACK[s]
            clients.append({"slug": s, "name": fb["name"], "profile": {"github_repos": fb["repos"]}})

SINCE = (datetime.now(timezone.utc) - timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ")

def human_readable_commit(msg):
    """
    Convert a raw git commit message into friendly plain English.
    Strips ticket refs, capitalises, removes jargon where possible.
    """
    import re
    # Remove common prefixes: feat:, fix:, chore:, refactor: etc.
    msg = re.sub(r'^(feat|fix|chore|refactor|docs|style|test|perf|ci|build|wip)(\([\w\-]+\))?:\s*', '', msg, flags=re.IGNORECASE)
    # Remove issue references like #123
    msg = re.sub(r'\s*#\d+', '', msg)
    # Capitalise
    msg = msg.strip()
    if msg:
        msg = msg[0].upper() + msg[1:]
    return msg

output_parts = []

for client in clients:
    slug = client.get("slug", "")
    name = client.get("name", slug)
    profile = client.get("profile") or {}
    repos = profile.get("github_repos", [])

    if not repos:
        continue

    client_lines = [f"=== {name} — Recent Development ==="]
    any_commits = False

    for repo_info in repos:
        owner = repo_info.get("owner", "")
        repo = repo_info.get("name", "")
        if not owner or not repo:
            continue

        # Use GitHub REST API (public repos need no auth)
        try:
            result = subprocess.run(
                ["curl", "-s", "--max-time", "15",
                 f"https://api.github.com/repos/{owner}/{repo}/commits?per_page=20&since={SINCE}"],
                capture_output=True, text=True, timeout=20
            )
            data = json.loads(result.stdout or "[]")
            raw_commits = []
            if isinstance(data, list):
                for item in data:
                    msg = (item.get("commit") or {}).get("message", "")
                    if msg:
                        raw_commits.append(msg.split("\n")[0].strip())
            else:
                raw_commits = []
        except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception):
            raw_commits = []

        if not raw_commits:
            continue

        # Filter out merge commits and noise
        commits = []
        for c in raw_commits:
            first_line = c.split("\n")[0].strip()
            if first_line.lower().startswith("merge"):
                continue
            readable = human_readable_commit(first_line)
            if readable and readable not in commits:
                commits.append(readable)

        if commits:
            any_commits = True
            client_lines.append(f"\nRepo: {owner}/{repo} (last 7 days)")
            for i, c in enumerate(commits[:10], 1):
                client_lines.append(f"  {i}. {c}")

    if any_commits:
        output_parts.append("\n".join(client_lines))

if output_parts:
    print("\n\n".join(output_parts))
else:
    print("(no recent commits in the last 7 days)")
PY
