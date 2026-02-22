DAILY HEARTBEAT - claude-haiku-4-5

1. CHECK ESCALATIONS:
   Query Supabase: SELECT count(*) FROM email_queue WHERE status='awaiting_approval'
   If any older than 1 hour: Telegram alert to Josh.

2. CHECK EMAIL BACKLOG:
   Count emails WHERE status IN ('pending', 'analyzing')
   Flag any older than 2 hours.

3. CHECK CLIENT REPOS (last 6 hours):
   cd /Users/henryburton/.openclaw/workspace-anthropic/chrome-auto-care && git log --oneline --since='6 hours ago'
   cd /Users/henryburton/.openclaw/workspace-anthropic/qms-guard && git log --oneline --since='6 hours ago'
   cd /Users/henryburton/.openclaw/workspace-anthropic/favorite-flow-9637aff2 && git log --oneline --since='6 hours ago'

4. GENERATE STATUS SUMMARY:
   claude -p --model claude-haiku-4-5 "Generate a concise system heartbeat report.
   Escalations pending: [count] | Email backlog: [count] | Recent commits: [list]
   Return: one short paragraph. If all clear say so. If issues list them clearly."

5. POST to Mission Control:
   /Users/henryburton/.openclaw/workspace-anthropic/notifications-bridge.sh "heartbeat" "Daily Heartbeat — [STATUS]" "[SUMMARY]" "Heartbeat" "[normal|high if issues]"

6. If issues found: also Telegram alert to Josh.

7. Log to Supabase audit_log: agent=Heartbeat, action=daily_heartbeat, status=success.