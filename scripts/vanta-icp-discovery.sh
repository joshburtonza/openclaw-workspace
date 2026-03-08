#!/usr/bin/env bash
# vanta-icp-discovery.sh
# Sends ICP discovery questions to the Vanta Studios WhatsApp group.

WS="/Users/henryburton/.openclaw/workspace-anthropic"
LOG="$WS/out/vanta-icp-discovery.log"
GATEWAY_API="http://localhost:3001/send"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
log "vanta-icp-discovery starting"

MESSAGE="Hi Marcus and Lee! Sophia here from Amalfi AI.

Your lead generation pipeline is live and running daily discovery. Before we activate outreach, I want to make sure we are targeting exactly the right people for Vanta Studios.

Could you help me with a few quick questions?

1. Who is your ideal client? For example, are you targeting wedding photographers, portrait photographers, commercial photographers, or brands looking to hire a space?

2. What area are you focused on? Cape Town only, all of SA, or broader?

3. What tone works best when reaching out to potential clients? Warm and creative, professional and direct, or something else?

4. Do you have any existing photographer contacts or leads we should add to the pipeline to get things started?

These answers will shape the whole outreach strategy so the more detail the better. No rush at all."

PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'to': 'Vanta Studios', 'message': sys.argv[1]}))
" "$MESSAGE")

HTTP_STATUS=$(curl -s -o /tmp/vanta-icp-send.log -w "%{http_code}" \
  -X POST "$GATEWAY_API" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; then
  log "ICP discovery message sent to Vanta Studios group"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WS/tmp/vanta-icp-sent.flag"
else
  log "FAILED — HTTP $HTTP_STATUS — $(cat /tmp/vanta-icp-send.log)"
fi

log "done"
