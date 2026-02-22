#!/usr/bin/env bash
# sophia-ooo-set.sh
# Set or clear Sophia's OOO mode from Telegram commands.
# Usage:
#   sophia-ooo-set.sh set "Travelling until Monday"
#   sophia-ooo-set.sh clear

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="$(dirname "$0")/../.env.scheduler"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

ACTION="${1:-}"
REASON="${2:-No reason given}"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="1140320036"
AVAIL_FILE="/Users/henryburton/.openclaw/workspace-anthropic/josh-availability.md"

if [[ "$ACTION" != "set" && "$ACTION" != "clear" ]]; then
  echo "Usage: sophia-ooo-set.sh set|clear [reason]" >&2
  exit 1
fi

tg_msg() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")}" \
    >/dev/null
}

if [[ "$ACTION" == "set" ]]; then
  # Write to Supabase system_config
  python3 - <<PY
import requests, json, datetime

URL = "${SUPABASE_URL}"
KEY = "${SUPABASE_KEY}"
REASON = """${REASON}"""

# Upsert system_config key=sophia_ooo
payload = {
    "key": "sophia_ooo",
    "value": json.dumps({
        "enabled": True,
        "reason": REASON,
        "set_at": datetime.datetime.utcnow().isoformat() + "Z",
    })
}

# Try update first
r = requests.patch(
    f"{URL}/rest/v1/system_config?key=eq.sophia_ooo",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
             "Content-Type": "application/json", "Prefer": "return=minimal"},
    json={"value": payload["value"]}, timeout=10
)

# If no rows patched, insert
if r.status_code == 200:
    count = r.headers.get("content-range","")
    # PostgREST returns 204 on success, check content-range for rows updated
    pass

# Simpler: use upsert
r2 = requests.post(
    f"{URL}/rest/v1/system_config",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
             "Content-Type": "application/json",
             "Prefer": "resolution=merge-duplicates,return=minimal"},
    json=payload, timeout=10
)
print(f"Supabase upsert: {r2.status_code}")
PY

  # Also update the markdown file for the bash OOO cache script
  TODAY=$(date +%Y-%m-%d)
  AVAIL_HEADER="# Josh Availability

## Current Status
**OOO** — ${REASON}

## OOO Schedule
| Date | Status | Notes |
|------|--------|-------|
| ${TODAY} | OOO | ${REASON} |"

  # Preserve existing history below the OOO Schedule table
  TAIL=$(awk '/^## How This Works/{found=1} found{print}' "$AVAIL_FILE" 2>/dev/null || true)

  printf '%s\n\n%s\n' "$AVAIL_HEADER" "$TAIL" > "$AVAIL_FILE"

  # Bust the per-day cache so sophia-ooo-cache.sh picks up the change immediately
  find /tmp -name "sophia-ooo-*" -delete 2>/dev/null || true

  tg_msg "⏸ OOO mode ON. Sophia is holding all drafts. Reason: ${REASON}"
  echo "OOO mode set."

elif [[ "$ACTION" == "clear" ]]; then
  python3 - <<PY
import requests, json

URL = "${SUPABASE_URL}"
KEY = "${SUPABASE_KEY}"

r = requests.post(
    f"{URL}/rest/v1/system_config",
    headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
             "Content-Type": "application/json",
             "Prefer": "resolution=merge-duplicates,return=minimal"},
    json={"key": "sophia_ooo", "value": json.dumps({"enabled": False})},
    timeout=10
)
print(f"Supabase upsert: {r.status_code}")
PY

  # Update availability file back to AVAILABLE
  cat > "$AVAIL_FILE" << 'MD'
# Josh Availability

## Current Status
**AVAILABLE** — Normal operations

## OOO Schedule
| Date | Status | Notes |
|------|--------|-------|

## How This Works

When Josh tells Alex he's OOO:
1. Alex updates this file with the dates and reason
2. Sophia reads this before generating responses
3. If OOO: Sophia holds non-urgent responses, escalation threshold RAISES (only truly urgent gets through)
4. If client emails during OOO: Sophia sends a warm holding response
5. Alex sends Josh a Telegram reminder the evening before OOO starts

## OOO Rules for Sophia
- Do NOT send draft responses without Josh approval during OOO periods
- Do NOT escalate routine stuff — only genuine emergencies
- If client asks urgent question during OOO: send holding response automatically (no approval needed for holding responses)
- Holding response template: "Hi [NAME], thanks for reaching out. Josh is currently unavailable but I wanted to let you know we received your message. We will come back to you first thing [NEXT_BUSINESS_DAY]. Have a great [DAY]!"

## Approval Threshold Changes
| Status | Escalation Trigger | Auto-hold responses |
|--------|-------------------|---------------------|
| Available | Normal (budget/churn/blocker/opportunity) | No |
| OOO | Only genuine emergencies (system down, contract issue) | Yes |
MD

  find /tmp -name "sophia-ooo-*" -delete 2>/dev/null || true

  tg_msg "✅ OOO mode OFF. Sophia is back to normal operations."
  echo "OOO mode cleared."
fi
