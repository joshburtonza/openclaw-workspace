# Josh Availability

## Current Status
**AVAILABLE** — Normal operations

## OOO Schedule
| Date | Status | Notes |
|------|--------|-------|

## How This Works

When Josh tells Alex he's OOO:
1. Alex updates this file with the dates and reason
2. Sophia reads this before generating responses
3. If OOO: Sophia holds non-urgent responses, escalation threshold RAISES (only truly urgent gets through)
4. If client emails during OOO: Sophia sends a warm holding response ("Josh is unavailable today, I will follow up first thing tomorrow")
5. Alex sends Josh a Telegram reminder the evening before OOO starts

## OOO Rules for Sophia
- Do NOT send draft responses without Josh approval during OOO periods
- Do NOT escalate routine stuff — only genuine emergencies
- If client asks urgent question during OOO: send holding response automatically (no approval needed for holding responses)
- Holding response template: "Hi [NAME], thanks for reaching out. Josh is currently unavailable but I wanted to let you know we received your message. We will come back to you first thing [NEXT_BUSINESS_DAY]. Have a great [DAY]!"

## Approval Threshold Changes
| Status | Escalation Trigger | Auto-hold responses |
|--------|-------------------|---------------------|
| Available | Normal (budget/churn/blocker/opportunity) | No |
| OOO | Only genuine emergencies (system down, contract issue) | Yes |
| Weekend | Reduced (high priority only) | Yes for routine |

## Contact in Emergency
If Josh is OOO and something truly urgent comes in:
- Telegram alert to Josh regardless
- Sophia sends holding response
- Log in Mission Control as urgent escalation
