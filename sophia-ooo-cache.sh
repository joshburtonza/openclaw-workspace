#!/bin/bash
# sophia-ooo-cache.sh
# Returns "true" or "false" for Sophia's OOO mode.
# Checks Supabase system_config first (authoritative), falls back to markdown.
# Caches result for 15 minutes so we don't hammer Supabase on every email.

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
# Load service role key from env file
ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
AVAIL_FILE="/Users/henryburton/.openclaw/workspace-anthropic/josh-availability.md"

CACHE_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/sophia-ooo-cache"
mkdir -p "$(dirname "$CACHE_FILE")"

# Cache expires after 15 minutes
if [[ -f "$CACHE_FILE" ]]; then
  CACHE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
  if [[ "$CACHE_AGE" -lt 900 ]]; then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

OOO_MODE="false"

# ── 1. Check Supabase system_config (most reliable) ───────────────────────────
SUPA_RESULT=$(curl -s \
  "${SUPABASE_URL}/rest/v1/system_config?key=eq.sophia_ooo&select=value" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  --max-time 5 2>/dev/null || echo "")

if [[ -n "$SUPA_RESULT" ]]; then
  ENABLED=$(python3 -c "
import json, sys
try:
  rows = json.loads('''${SUPA_RESULT}'''.replace(\"'\",\"'\"))
  if rows:
    val = rows[0].get('value')
    if isinstance(val, str):
      val = json.loads(val)
    print('true' if val.get('enabled') else 'false')
  else:
    print('false')
except:
  print('false')
" 2>/dev/null || echo "false")
  OOO_MODE="$ENABLED"
fi

# ── 2. Fallback: check markdown file ──────────────────────────────────────────
if [[ "$OOO_MODE" == "false" && -f "$AVAIL_FILE" ]]; then
  TODAY=$(date +%Y-%m-%d)
  while IFS='|' read -r _ date status notes _; do
    date_clean=$(echo "$date" | xargs)
    status_clean=$(echo "$status" | xargs | tr '[:upper:]' '[:lower:]')
    parsed_date=$(echo "$date_clean" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    if [[ "$parsed_date" == "$TODAY" ]]; then
      if echo "$status_clean" | grep -qiE '^(ooo|out of office|unavailable)$'; then
        OOO_MODE="true"
        break
      fi
    fi
  done < <(grep '|' "$AVAIL_FILE")

  # Check current status header
  if grep -q "^\*\*OOO\*\*" "$AVAIL_FILE" 2>/dev/null; then
    OOO_MODE="true"
  fi
fi

echo "$OOO_MODE" > "$CACHE_FILE"
echo "$OOO_MODE"
