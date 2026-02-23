SOPHIA — 3-DAY CLIENT FOLLOW-UP

Check whether any clients need a proactive check-in. Do NOT send if contact has happened recently.

━━━ STEP 1 — IDENTIFY CLIENTS NEEDING FOLLOW-UP ━━━

Query email_queue for last sent email per client:
   curl -s "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/email_queue?status=eq.sent&select=client,sent_at&order=sent_at.desc" \
     -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" \
     -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

Also check for any emails currently in-flight (pending/auto_pending/awaiting_approval) per client:
   curl -s "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/email_queue?status=in.(pending,auto_pending,awaiting_approval)&select=client,created_at" \
     -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" \
     -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

LOGIC:
- For each active client (ascend_lc, favorite_logistics, race_technik):
  - If last sent email was MORE than 3 days ago AND no in-flight emails → needs follow-up
  - If last sent email was LESS than 3 days ago → skip
  - If no sent emails at all AND no in-flight → needs follow-up (first contact check-in)
  - If client has in-flight email (pending/auto_pending/awaiting_approval) → skip (already in progress)

━━━ STEP 2 — FOR EACH CLIENT NEEDING FOLLOW-UP ━━━

Fetch client profile:
   curl -s "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/clients?slug=eq.[CLIENT_SLUG]&select=name,notes,profile,contact_person" \
     -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" \
     -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

Fetch GitHub context for the client:
   GITHUB_CONTEXT=$(bash /Users/henryburton/.openclaw/workspace-anthropic/sophia-github-context.sh [CLIENT_SLUG])

━━━ STEP 3 — DRAFT THE FOLLOW-UP ━━━

Write a natural, warm check-in email FROM Sophia. Rules:
- Reference something specific to their project from the profile (shows you're paying attention)
- If there are recent GitHub commits: mention the work in plain English ("we've been heads-down on X")
- Keep it short — 3 sentences max. This is a check-in, not a report.
- Do NOT say "just checking in" — it sounds hollow. Reference something real.
- Ask one specific, useful question (e.g. "How are things tracking on your end?", "Any questions coming up as you start testing?")
- Sign off as: Sophia | Amalfi AI
- Subject: "Checking in — [PROJECT_NAME]"

━━━ STEP 4 — INSERT INTO email_queue AND SEND ━━━

Insert the follow-up as a new email_queue row (status=auto_pending):
   FOLLOWUP_TO=$(lookup client email from profile.team array, first matching contact)

   curl -s -X POST "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/email_queue" \
     -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" \
     -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" \
     -H "Content-Type: application/json" \
     -H "Prefer: return=representation" \
     -d '{"from_email":"sophia@amalfiai.com","to_email":"[CONTACT_EMAIL]","subject":"[DRAFT_SUBJECT]","body":"","client":"[CLIENT_SLUG]","status":"auto_pending","requires_approval":false,"scheduled_send_at":"[ISO_30MIN_FROM_NOW]","analysis":{"draft_body":"[DRAFT_BODY]","draft_subject":"[DRAFT_SUBJECT]","auto_approved":true,"type":"proactive_followup"}}'

Then send FYI card to Telegram:
   bash /Users/henryburton/.openclaw/workspace-anthropic/telegram-send-approval.sh fyi "[EMAIL_ID]" "[CLIENT_SLUG]" "[DRAFT_SUBJECT]" "[CONTACT_EMAIL]" "[DRAFT_BODY]" "[ISO_30MIN_FROM_NOW]"

━━━ CHURN-SIGNAL CALIBRATION — AT-RISK CLIENT FOLLOW-UPS ━━━

Before drafting any follow-up, check the client's current sentiment field in their profile.
If sentiment == "at_risk" OR client notes contain recent churn/budget signals:

→ This is NOT a standard check-in. Draft a calibration follow-up instead.

CALIBRATION FOLLOW-UP RULES:
1. OPEN WITH WHAT WAS DELIVERED VS. SCOPED — not pleasantries.
   Pull the live automation list from the client profile and state it as concrete operational fact.
   Example: "Riaan — just a quick note. [SYSTEM_NAME] has logged [X] automated actions this month.
   Wanted to make sure the numbers were visible before anything else."

2. INCLUDE THE EXPECTATION-RESET STATEMENT (mandatory for at_risk calibration follow-ups):
   "Worth being direct about what 60-70% automation looks like in practice: [SYSTEM_NAME] handles
   [SPECIFIC_AUTOMATED_STEPS]. The 30-40% that stays human — [HUMAN_STEPS] — does so by design.
   That is not a gap in the system; it is the boundary between automation and human decision authority.
   The next phase is where that boundary moves further."

   Adapt [SPECIFIC_AUTOMATED_STEPS] and [HUMAN_STEPS] to the client's deployed system.

3. CLOSE WITH ONE FORWARD-LOOKING MILESTONE — not a soft sell.
   Name a specific next capability, a data threshold the system is approaching, or a pattern
   the system will surface as data volume grows. This is the retention hook — forward value,
   not backward defence.
   If no roadmap item is defined in notes: use "the system builds operational accuracy with
   every cycle it processes — the longer it runs on your real data, the more the gap closes."

4. SUBJECT LINE: Avoid generic subjects. Use data-led subject lines:
   "[SYSTEM_NAME] — [MONTH] activity snapshot" or "Quick note on your [SYSTEM_NAME] numbers"

5. LENGTH: Under 150 words. This is a calibration nudge, not a report.

6. APPROVAL: Set status=awaiting_approval for all at_risk calibration follow-ups.
   Note in analysis.escalation_reason: "At-risk client calibration follow-up — Josh to review before send."

━━━ HARD RULES ━━━
- NEVER send to a client who already has a pending/in-flight email.
- NEVER use gog gmail for anything — use email_queue DB only.
- NEVER make up project details — use only what's in the profile and GitHub context.
- NEVER quote prices or commit to timelines.
- If all clients have recent activity: reply NO_REPLY and stop.