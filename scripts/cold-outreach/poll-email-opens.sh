#!/usr/bin/env bash
# poll-email-opens.sh
# Runs every 10 min via LaunchAgent.
# Queries gog gmail track opens for each outreach_log row that has a
# tracking_id but no opened_at yet, then writes the result to Supabase.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WS/.env.scheduler"
source "$WS/scripts/lib/agent-registry.sh"
agent_checkin "worker-email-opens" "worker" "sales-supervisor"

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
             '--account', 'alex@amalfiai.com', '--json'],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            continue
        data = json.loads(result.stdout)
        # gog may return a list of open events directly instead of a summary dict
        if isinstance(data, list):
            all_opens   = data
            non_bot     = [o for o in data if not o.get('is_bot', False)]
            human_opens = len(non_bot)
            total_opens = len(data)
            first_human = non_bot[0] if non_bot else None
        else:
            human_opens  = data.get('human_opens', 0)
            total_opens  = data.get('total_opens', 0)
            first_human  = data.get('first_human_open')
            all_opens    = data.get('opens', [])

        # Primary: human opens (Apple Mail, direct loads).
        # Fallback: total opens — Gmail & Outlook route images through their own
        # proxy servers so the CF Worker marks them as bots, but Google's proxy
        # only fires when a user actually opens the email (reliable signal).
        count     = human_opens if human_opens > 0 else total_opens
        first_at  = (first_human or {}).get('at') if first_human else None
        if not first_at and all_opens:
            first_at = all_opens[0].get('at')

        if count > 0 and first_at:
            supa_patch(f"outreach_log?id=eq.{log_id}", {
                "opened_at":  first_at,
                "open_count": count,
            })
            label = "human" if human_opens > 0 else "proxy"
            print(f"[opens] ✓ {tid[:20]}... → {count} opens ({label}), first: {first_at}")
            opened_count += 1

    except Exception as e:
        print(f"[opens] Error polling {tid[:20]}...: {e}", file=sys.stderr)
        continue

print(f"[opens] Done — {opened_count} newly opened emails recorded.")
PY

agent_checkout "worker-email-opens" "idle" "Done"
