#!/bin/bash
# SOPHIA CSM → SUPABASE EMAIL QUEUE BRIDGE
# Called by 5-min cron polling job to POST emails to Supabase for real-time dashboard visibility

# Usage: ./sophia-csm-supabase-bridge.sh "from_email" "subject" "body" "client_name"

FROM_EMAIL="$1"
SUBJECT="$2"
BODY="$3"
CLIENT="$4"
TO_EMAIL="sophia@amalfiai.com"

# Supabase credentials (from .env)
SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

# Determine client code from email
case "$FROM_EMAIL" in
  riaan@ascendlc.co.za|andre@ascendlc.co.za)
    CLIENT_CODE="ascend_lc"
    ;;
  rapizo92@gmail.com)
    CLIENT_CODE="favorite_logistics"
    ;;
  *)
    CLIENT_CODE="unknown"
    ;;
esac

# POST to Supabase REST API
curl -s -X POST \
  "${SUPABASE_URL}/rest/v1/email_queue" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"from_email\": \"${FROM_EMAIL}\",
    \"to_email\": \"${TO_EMAIL}\",
    \"subject\": \"${SUBJECT}\",
    \"body\": \"${BODY}\",
    \"client\": \"${CLIENT_CODE}\",
    \"status\": \"pending\"
  }" > /dev/null 2>&1

echo "📨 Email queued: $FROM_EMAIL → $CLIENT_CODE"
