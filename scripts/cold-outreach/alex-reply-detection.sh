#!/usr/bin/env bash
# alex-reply-detection.sh
# Polls alex@amalfiai.com for replies from contacted leads.
# If a reply found: update lead status → replied, fire Telegram alert to Josh.
# Runs every 2 hours via LaunchAgent.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="7584896900"
ACCOUNT="alex@amalfiai.com"
LOG="$WS/out/alex-reply-detection.log"

mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
source "$WS/scripts/lib/task-helpers.sh"

if [[ -z "$SUPABASE_KEY" ]]; then
    log "ERROR: SUPABASE_SERVICE_ROLE_KEY not set — cannot proceed"
    exit 1
fi

log "=== Reply detection run ==="

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN CHAT_ID ACCOUNT

python3 - <<'PY'
import os, sys, json, subprocess, datetime, urllib.request, urllib.error

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SUPABASE_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
ACCOUNT      = os.environ['ACCOUNT']

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

def tg(text):
    if not BOT_TOKEN:
        return
    try:
        data = json.dumps({"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML"}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            data=data, headers={"Content-Type": "application/json"}, method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

# ── Fetch contacted leads (not yet marked replied) ─────────────────────────────

leads = supa_get(
    "leads?status=in.(contacted,sequence_complete)"
    "&reply_received_at=is.null"
    "&select=id,first_name,last_name,email,company,status"
    "&limit=500"
)

if not leads:
    print("No contacted leads to check.")
    sys.exit(0)

print(f"Checking {len(leads)} leads for replies...")

new_replies = []

for lead in leads:
    email = (lead.get('email') or '').strip()
    if not email:
        continue

    # Search alex's inbox for any email FROM this address
    result = subprocess.run(
        ['gog', 'gmail', 'search',
         f'from:{email}',
         '--account', ACCOUNT,
         '--max', '1'],
        capture_output=True, text=True, timeout=30,
    )

    if result.returncode != 0:
        # gog error — skip silently, don't block the run
        continue

    output = result.stdout.strip()
    if not output or 'no messages' in output.lower() or 'no results' in output.lower():
        continue

    # Reply found — update lead status
    print(f"  Reply from {email}")
    try:
        supa_patch(f"leads?id=eq.{lead['id']}", {
            "status":            "replied",
            "reply_received_at": now_utc(),
            "reply_sentiment":   "unknown",
        })
    except Exception as e:
        print(f"  [!] Supabase patch failed for {lead['id']}: {e}", file=sys.stderr)
        continue

    name    = f"{lead.get('first_name','')} {lead.get('last_name','') or ''}".strip()
    company = lead.get('company') or email
    new_replies.append({"name": name, "email": email, "company": company})

# ── Telegram alert ─────────────────────────────────────────────────────────────

if new_replies:
    count = len(new_replies)
    lines = [f"📥 <b>Alex — {count} new lead repl{'ies' if count > 1 else 'y'}!</b>\n"]
    for r in new_replies:
        lines.append(f"• <b>{r['name']}</b> @ {r['company']}")
    lines.append("\nOpen Mission Control → Alex CRM to review and qualify.")
    tg("\n".join(lines))

print(f"Done. New replies: {len(new_replies)}")
PY
