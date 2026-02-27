#!/bin/bash
# notifications-bridge.sh
# Posts a notification to Supabase notifications table (replaces Discord posting)
# Usage: ./notifications-bridge.sh "TYPE" "TITLE" "BODY" "AGENT" "PRIORITY" [METADATA_JSON]
#
# TYPE options: email_inbound, email_sent, escalation, approval, heartbeat, outreach, repo, system, reminder
# PRIORITY options: urgent, high, normal, low

TYPE="${1:-system}"
TITLE="${2:-Notification}"
BODY="${3:-}"
AGENT="${4:-System}"
PRIORITY="${5:-normal}"
METADATA="${6:-{}}"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

# Escape strings for JSON
escape_json() {
  echo "$1" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().rstrip()))'
}

TITLE_ESC=$(escape_json "$TITLE")
BODY_ESC=$(escape_json "$BODY")

curl -s -X POST \
  "${SUPABASE_URL}/rest/v1/notifications" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d "{
    \"type\": \"${TYPE}\",
    \"title\": ${TITLE_ESC},
    \"body\": ${BODY_ESC},
    \"agent\": \"${AGENT}\",
    \"priority\": \"${PRIORITY}\",
    \"status\": \"unread\",
    \"metadata\": ${METADATA}
  }" > /dev/null 2>&1

echo "[notif] ${TYPE} | ${PRIORITY} | ${TITLE}"
