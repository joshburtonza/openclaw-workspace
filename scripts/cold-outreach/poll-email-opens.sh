#!/usr/bin/env bash
# poll-email-opens.sh
# Runs every 10 min via LaunchAgent.
# Queries gog gmail track opens for each outreach_log row that has a
# tracking_id but no opened_at yet, then writes the result to Supabase.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
LOG="$WS/out/email-opens.log"
mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

log "=== Open poller run ==="

export SUPABASE_URL SUPABASE_KEY

python3 - << 'PY'
import os, sys, json, subprocess
import urllib.request, urllib.error

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SUPABASE_KEY']

def supa_get(path):
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())

def supa_patch(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()

# Fetch all outreach_log rows with a tracking_id but not yet opened.
# Limit to last 500 (any older than ~3 weeks aren't worth polling).
try:
    rows = supa_get(
        "outreach_log"
        "?select=id,tracking_id,lead_id"
        "&tracking_id=not.is.null"
        "&opened_at=is.null"
        "&order=sent_at.desc"
        "&limit=500"
    )
except Exception as e:
    print(f"[opens] Supabase query failed — migration 016 likely not applied yet: {e}")
    sys.exit(0)

if not rows:
    print("[opens] Nothing to poll.")
    sys.exit(0)

print(f"[opens] Polling {len(rows)} emails with tracking_ids...")
opened_count = 0

for row in rows:
    tid = row['tracking_id']
    log_id = row['id']
    try:
        result = subprocess.run(
            ['gog', 'gmail', 'track', 'opens', tid,
             '--account', 'alex@amalfiai.com', '--json', '--results-only'],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            continue
        data = json.loads(result.stdout)
        human_opens = data.get('human_opens', 0)
        first_human = data.get('first_human_open')

        if human_opens > 0 and first_human:
            opened_at = first_human.get('at') or first_human.get('opened_at')
            supa_patch(f"outreach_log?id=eq.{log_id}", {
                "opened_at":  opened_at,
                "open_count": human_opens,
            })
            print(f"[opens] ✓ {tid[:20]}... → {human_opens} human opens, first: {opened_at}")
            opened_count += 1

    except Exception as e:
        print(f"[opens] Error polling {tid[:20]}...: {e}", file=sys.stderr)
        continue

print(f"[opens] Done — {opened_count} newly opened emails recorded.")
PY
