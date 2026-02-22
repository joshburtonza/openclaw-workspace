CLIENT SILENCE DETECTION — DB-BASED

Check for client silence using email_queue (NOT gog gmail — DB only).

━━━ QUERY LAST CONTACT PER CLIENT ━━━

For each active client, find the most recent email (any status except skipped):
   curl -s "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/email_queue?status=in.(sent,auto_pending,awaiting_approval,approved)&select=client,created_at,sent_at&order=created_at.desc" \
     -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" \
     -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

Fetch active client slugs dynamically (do not use a hardcoded list):
   curl -s "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/clients?select=slug,name&order=name.asc" \
     -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" \
     -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

Use the slug values returned as the active client list. Check silence for every slug in the response.

━━━ ALERT THRESHOLDS ━━━

Note: The 3-day follow-up cron handles proactive check-ins. This cron handles ALERTS ONLY for longer silences.

- 7-14 days: Send a Telegram notification to Josh (low urgency)
- 14+ days: Send urgent Telegram notification + log to audit_log as churn_risk

━━━ SEND TELEGRAM ALERTS ━━━

Read the chat_id from file (set when Josh last messaged the bot):
   JOSH_CHAT_ID=$(cat /Users/henryburton/.openclaw/workspace-anthropic/tmp/josh_private_chat_id 2>/dev/null || echo "1140320036")

For 7-14 day silence:
   curl -s -X POST "https://api.telegram.org/bot$(cat /Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler | grep TELEGRAM_BOT_TOKEN | cut -d= -f2)/sendMessage" \
     -H "Content-Type: application/json" \
     -d "{\"chat_id\":\"$JOSH_CHAT_ID\",\"text\":\"⚠️ [CLIENT_NAME] has been silent for [DAYS] days. The 3-day follow-up may have been held — check email queue.\"}"

For 14+ day silence:
   curl -s -X POST "https://api.telegram.org/bot$(cat /Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler | grep TELEGRAM_BOT_TOKEN | cut -d= -f2)/sendMessage" \
     -H "Content-Type: application/json" \
     -d "{\"chat_id\":\"$JOSH_CHAT_ID\",\"text\":\"🚨 CHURN RISK: [CLIENT_NAME] has been silent for [DAYS] days. Josh — direct outreach recommended.\"}"

━━━ HARD RULES ━━━
- NEVER use gog gmail search — use email_queue DB only.
- Do NOT send follow-up emails from this cron — that is handled by the 3-day follow-up cron.
- Only send Telegram alerts for 7+ day silences.