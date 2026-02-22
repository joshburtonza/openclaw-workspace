# QMS Guard Weekly Progress Report (Ascend LC)

## What we shipped last week
- Security improvement: scheduled tasks endpoint is now protected so only authorised system calls can trigger workflow jobs.
- Workflow improvements: simplified approval flow and tightened form validation to prevent incomplete submissions.
- Edith improvements: Edith now opens in a modal for easier editing without losing context.
- New settings tools: Clause Management and Data Cleanup utilities added for admins.

## What we are doing next week
- Stabilise the NC workflow end to end (create → classify → verify → approve → close).
- Review Clause Management data model with you and confirm clause structure.
- Continue polishing Edith user experience and validation.

## Risks or blockers
- We need confirmation on your preferred clause naming and numbering conventions.
- If any workflow steps are still unclear, we want feedback so we can simplify further.

## Decisions needed
- Confirm how you want clauses grouped (by section, standard, department).
- Confirm who should receive workflow notifications at each stage.
