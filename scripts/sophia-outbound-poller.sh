#!/bin/bash
# sophia-outbound-poller.sh
# Polls task_queue for pending sophia_outbound_intro tasks and processes one per run.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
API_KEY="${SUPABASE_SERVICE_ROLE_KEY}"

# ── Fetch one pending task ────────────────────────────────────────────────────

export TASK_RAW=$(curl -s \
  "${SUPABASE_URL}/rest/v1/task_queue?task_type=eq.sophia_outbound_intro&status=eq.pending&select=*&order=created_at.asc&limit=1" \
  -H "apikey: ${API_KEY}" -H "Authorization: Bearer ${API_KEY}")

export TASK_DATA=$(python3 - <<'PY'
import json, os
rows = json.loads(os.environ['TASK_RAW'])
if not rows:
    print('')
else:
    r = rows[0]
    payload = r.get('payload') or {}
    print(r['id'] + '|' + payload.get('lead_id',''))
PY
)

if [[ -z "$TASK_DATA" ]]; then
  exit 0
fi

TASK_ID=$(echo "$TASK_DATA" | cut -d'|' -f1)
LEAD_ID=$(echo "$TASK_DATA" | cut -d'|' -f2)

if [[ -z "$LEAD_ID" ]]; then
  echo "[sophia-outbound-poller] Task $TASK_ID has no lead_id in payload — skipping"
  exit 0
fi

echo "[sophia-outbound-poller] Claiming task $TASK_ID for lead $LEAD_ID"

# ── Claim the task ────────────────────────────────────────────────────────────

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
curl -s -X PATCH "${SUPABASE_URL}/rest/v1/task_queue?id=eq.${TASK_ID}" \
  -H "apikey: ${API_KEY}" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"status\":\"processing\",\"started_at\":\"${NOW}\"}" \
  > /dev/null

# ── Run outbound script ───────────────────────────────────────────────────────

if bash "${WS}/scripts/sophia-outbound-lead.sh" "$LEAD_ID" "$TASK_ID"; then
  echo "[sophia-outbound-poller] Task $TASK_ID complete"
else
  echo "[sophia-outbound-poller] Task $TASK_ID failed — marking error"
  curl -s -X PATCH "${SUPABASE_URL}/rest/v1/task_queue?id=eq.${TASK_ID}" \
    -H "apikey: ${API_KEY}" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"status\":\"error\",\"result\":{\"error\":\"sophia-outbound-lead.sh failed\"}}" \
    > /dev/null
fi
