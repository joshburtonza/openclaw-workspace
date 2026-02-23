# Retainer Tracker — Health Report Format & Risk Flags

**Trigger:** Runs on the 5th of each month via `scripts/retainer-tracker.sh`.
Checks for missing retainer payments and evaluates internalisation risk signals
for each active client.

**Source:** Meeting: Joshua / Salah — SMBs formalising AI relationships is a
maturation pattern requiring proactive boundary-setting.

---

## Report Sections

### 1. Payment Status
For each active client, checks whether a payment has been logged in `income_entries`
for the current month. Missing payments trigger a chase email draft via Sophia and
a Telegram approval card for Josh.

### 2. Internalisation Risk Flag

Evaluates each active client against two triggers:

**Trigger 1 — Integration-pressure keywords in email traffic**
If a client has 2 or more emails in the last 30 days (from `email_queue`) whose
subject or body contains any of the following keywords, the flag is raised:

> in-house, in house, bring it in, internal team, hire someone, build internally,
> own the system, take over, our own developer, train our, training our,
> documentation so we, handover, hand over, self-sufficient, independent,
> build ourselves, our developer, our team can, we can handle, no longer need,
> manage it ourselves, keep it internal, reduce dependency

**Trigger 2 — Month 4+ of retainer with escalating request volume**
If a client has been on retainer for 4 or more months (measured from earliest
paid/invoiced `income_entries` record) AND email volume in the last 30 days
exceeds the prior 30-day period, the flag is raised.

---

## Flag Output Format

When either trigger fires, the following message is emitted in the health report
and sent as a Telegram alert to Josh:

```
[INTERNALISATION RISK] Client may be building internal dependency — review scope
boundaries and consider proposing a structured retainer renewal that reinforces
consultant positioning.
```

The Telegram card includes the specific signals that triggered the flag
(e.g. "3 emails with integration-pressure keywords in last 30 days" or
"month 5 of retainer with escalating volume (4 → 9 emails)").

---

## Response Playbook

When an INTERNALISATION RISK flag fires, Josh should consider:

1. **Review the flagged emails** — identify whether the client is casually curious
   or actively planning to internalise (tone matters more than keywords).

2. **Proactive scope conversation** — before the client raises it, position a
   structured retainer renewal that frames ongoing consultant involvement as
   *complementary* to their internal capability, not a replacement for it.

3. **Reinforce consultant positioning** — remind the client of the ongoing
   maintenance burden, version drift, and edge-case accumulation that will occur
   without active monitoring. Use the retainer-pitch framing (loss-aversion over
   upsell).

4. **Consider a tiered handover offer** — rather than all-or-nothing, propose a
   reduced-scope retainer that covers monitoring + quarterly reviews while letting
   the client manage day-to-day. This keeps the relationship and creates a
   re-entry point.

---

## Approval Rules

Payment chase emails: always require Josh's approval (`status = awaiting_approval`).
Internalisation risk alerts: sent directly to Telegram as informational flags —
no email queued automatically. Josh decides on the response.
