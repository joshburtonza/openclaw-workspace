WEEKLY MEMORY UPDATE - claude-sonnet-4-6

1. READ recent daily logs (last 7 days):
   cat /Users/henryburton/.openclaw/workspace-anthropic/memory/2026-02-18.md (and previous days)

2. EXTRACT insights using Sonnet 4.6:
   claude -p --model claude-sonnet-4-6 "From these daily logs extract important long-term learnings:
   [LOG_CONTENT]
   
   Categories: key decisions, client context, system lessons, Josh preferences, follow-ups.
   Return concise one-liners per category. Only things worth remembering long-term."

3. APPEND to MEMORY.md under relevant sections. Remove anything outdated.

4. COMMIT:
   cd /Users/henryburton/.openclaw/workspace-anthropic
   git add MEMORY.md
   git commit -m 'Weekly memory update'
   git push

5. Log to Supabase audit_log: agent=Memory Bot, action=memory_curate, status=success.

6. Post to Discord #📚-documents: 'Weekly memory curated.'