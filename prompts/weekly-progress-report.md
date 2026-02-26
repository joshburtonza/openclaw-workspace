# WEEKLY PROGRESS REPORT — PROMPT / TEMPLATE SPEC

Used by: `scripts/weekly-reports/generate-weekly-client-reports.sh`
Clients: ascend_lc, favorite_logistics, race_technik
Schedule: Monday 07:00 (launchagent: weekly-client-reports)

---

## Report Structure (section order)

1. **What we shipped last week** — git commit log for the past 7 days, formatted as bullet list.

2. **Scope & Expectations** ← MANDATORY — added per Joshua/Salah meeting (2026-02-23)

   Template:

   ```
   **Delivered this week:**
   <mirror of shipped bullet list>

   **Out of scope / deferred:**
   <relationship-type-specific deferred items — see below>

   Agent automations are performing as scoped — edge cases outside the defined scope may require manual review.
   ```

   Deferred copy by relationship type:
   - **retainer**: "Custom integrations, third-party data migrations, and manual data entry tasks are outside the current sprint scope. Any items not completed this week have been carried to the next sprint backlog."
   - **bd_partner**: "Items outside our agreed joint pipeline scope are not included in this report. Any deferred items have been flagged for our next co-ordination session."

3. **What we are doing next week** — priorities and planned work.

4. **Risks or blockers** — open dependencies or items needing client input.

5. **Decisions needed** — action items for the client to confirm.

---

## Rationale

Research finding (AIOS / SMB adoption): *"Expectation management is a product feature — SMB clients conflate 'AI can do this' with 'it will do this reliably on day one.'"*

The Scope & Expectations section makes the boundary between what is automated and what requires human review explicit in every report, reducing cancellation risk and scoping disputes.
