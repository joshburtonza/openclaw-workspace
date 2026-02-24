# RACE TECHNIK WEEKLY REPORT — TEMPLATE SPEC

Used by: `scripts/weekly-reports/generate-weekly-client-reports.sh`
Client: race_technik (Josh / Farhaan)
Repo: chrome-auto-care
Schedule: Monday 07:00 (launchagent: weekly-client-reports)

---

## Report Structure (section order)

1. **What we shipped last week** — git commit log for the past 7 days.

2. **Scope & Expectations** ← MANDATORY (retainer language)

3. **Automation Pipeline Status** ← RACE TECHNIK SPECIFIC — 6-stage service automation milestone tracker.

4. **What we are doing next week**

5. **Risks or blockers**

6. **Decisions needed**

---

## Automation Pipeline Status — 6-Stage Checklist

The service automation stack for Race Technik follows a fixed 6-stage delivery pipeline.
Each stage maps to a specific operational hand-off in the workshop workflow.
Status is derived automatically from recent repo activity in `chrome-auto-care`.

| # | Stage | Description | Detection Keywords |
|---|-------|-------------|--------------------|
| 1 | Booking Intake | Customer books via web/walk-in form; job enters the system | booking, walk-in, walkin, intake |
| 2 | Job Card Creation | Job card generated from booking; assigned to vehicle/service type | job card, job track, job-card, stage |
| 3 | Technician Briefing | Technician receives scoped job brief via staff dashboard | technician, staff brief, briefing |
| 4 | Status Updates | Push notifications / status changes keep customer informed in real time | status update, notification, push, webhook |
| 5 | Invoice | Payment flow triggered on job completion; Yoco integration | invoice, payment, yoco |
| 6 | Follow-Up Review Request | Automated review/feedback request sent post-service | review, follow-up, followup |

### Status definitions

- ✅ **live** — functionality shipped (appears in git history, not just this week)
- 🔄 **in-progress** — actively worked on this week (appears in last-7-days commits)
- ⏳ **pending** — not yet started or no matching commits found

### Rationale

Research finding (Farhaan Race Technik Meeting, Jan 27 2026): *"The service business automation
stack is predictable and reusable — surfacing this visually in the weekly report keeps Josh and
Farhaan anchored to delivery progress and prevents scope drift."*

The Automation Pipeline Status section makes each delivery stage explicit in every report,
giving the client a clear view of what is live vs what is still being built, reducing
expectation mismatches and scoping disputes over the remaining pipeline.

---

## Keywords used for stage detection (git log subject lines)

The generation script runs `git log` against `chrome-auto-care` and pattern-matches subject
lines to assign a status to each stage. The patterns are intentionally broad to catch common
commit message variations.
