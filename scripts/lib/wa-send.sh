#!/usr/bin/env bash
# wa-send.sh — send a WhatsApp message via the local gateway API
#
# Usage:
#   source scripts/lib/wa-send.sh
#   wa_send "+27812705358" "Hello Josh"
#   wa_send "Race Technik" "Your booking is confirmed"   # partial group name
#
# Or standalone:
#   bash scripts/lib/wa-send.sh "+27812705358" "Hello"

WA_API="http://127.0.0.1:3001/send"

wa_send() {
  local to="$1"
  local message="$2"
  if [[ -z "$to" || -z "$message" ]]; then
    echo "wa_send: usage: wa_send <to> <message>" >&2
    return 1
  fi
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'to':sys.argv[1],'message':sys.argv[2]}))" "$to" "$message" 2>/dev/null)
  local response
  response=$(curl -s -X POST "$WA_API" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --max-time 10 2>/dev/null)
  if echo "$response" | grep -q '"ok":true'; then
    return 0
  else
    echo "wa_send error: $response" >&2
    return 1
  fi
}

# Standalone mode
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  wa_send "$1" "$2"
fi
