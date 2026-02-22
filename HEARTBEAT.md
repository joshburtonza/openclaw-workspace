# HEARTBEAT.md - Proactive Task Checks

Run this checklist every 30 minutes during business hours.

## Quick Checks (Always)

### 1. TASK BOARD STATUS
- [ ] Any URGENT tasks pending?
  - If yes → Post to Telegram: "🚨 URGENT: [task titles]"
- [ ] Any tasks stuck in progress for >2 hours?
  - If yes → Ask in Discord: "This task been running a while... need help?"
- [ ] Completed 5+ tasks today?
  - If yes → Post celebratory message to #general

### 2. EMAIL ESCALATIONS
- [ ] Any emails awaiting approval for >1 hour?
  - If yes → Ping Josh on Telegram: "Approval needed: [client] - [subject]"
- [ ] High-priority email (Ascend LC, Race Technik) in queue?
  - If yes → Post to #📨-csm-responses: "Priority email in queue"

### 3. SYSTEM HEALTH
- [ ] Kill switch status = RUNNING?
  - If not → Alert to Discord ops channel
- [ ] Any failed cron jobs in last hour?
  - If yes → Post error to #⚙️-operations

### 4. CLIENT REPOS
- [ ] Any recent commits (last 6 hours) from clients?
  - If yes → Mention in Discord for Sophia context
- [ ] QMS Guard, FLAIR, or Chrome Auto-Care updated?
  - If yes → Log to task board as "Review [client] updates"

## Selective Checks (Rotate These)

### Morning (7am-12pm)
- Video scripts generated at 7am? Check #🎬-video-scripts
- Cold outreach sending? Check #📤-sales-outreach for today's summary
- Daily heartbeat ran at 12pm? Verify Supabase audit_log

### Afternoon (12pm-6pm)
- Email polling catching customer inbound? (target: <2 min response time)
- Any tasks blocked? Raise to Josh
- Memory updates queued for tonight?

### Evening (6pm-11pm)
- Repo sync done? (if Tuesday 9am ran)
- Final task board review before night
- Anything overdue for tomorrow?

## Actions

**When escalating to Josh:** Use Telegram (not Discord) for time-sensitive
**When logging for audit:** Always include: WHO, WHAT, WHEN, STATUS
**When updating tasks:** Check both web dashboard AND database for consistency

## Automation Note

This checklist runs via heartbeat cron job. Copy any urgent findings into the Task Board so they persist. Heartbeat is for proactive scanning; Task Board is for persistent tracking.
