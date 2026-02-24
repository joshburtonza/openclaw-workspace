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

⚠️ MOAT REMINDER: The skills built for this client ([MONTHS_ACTIVE] months of
training against their real operational data) cannot be replicated quickly. An
internal hire would need 3–4 months and R60–100k+ to reach the same baseline —
with no institutional knowledge of the edge cases already handled. The retainer is
ongoing evolution of a compounding system, not just support. Reframe this as a
cost-of-switching conversation.
```

The Telegram card includes the specific signals that triggered the flag
(e.g. "3 emails with integration-pressure keywords in last 30 days" or
"month 5 of retainer with escalating volume (4 → 9 emails)"), plus the moat
framing summary with [MONTHS_ACTIVE] substituted for the actual months on retainer.

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

5. **Skills library moat argument** — Frame the proprietary automation layer built
   for this client's specific vertical as infrastructure that cannot be quickly
   replicated by an internal hire. The argument: the skills built for this client
   (non-conformance classification for their specific document formats, their email
   thread patterns, their supplier data structures) are the product of
   [MONTHS_ACTIVE] months of training against their real operational data. An
   internal hire starting from scratch would need 3–4 months and R60–100k+ to reach
   the same baseline — and would have no institutional knowledge of the edge cases
   the system has already encountered. The retainer is not just support; it is
   ongoing evolution of a system that compounds with usage. Use this framing to
   reframe internalisation risk as a cost-of-switching conversation, not a
   capability discussion.

---

---

## Vertical Expansion Pitch Trigger (QMS clients)

**Source:** Meeting: Ascend LC / Amalfi AI

When a client whose `notes` field contains `qms` (case-insensitive) crosses
**60 days on retainer** (measured from the earliest paid/invoiced `income_entries`
record), a Telegram nudge is sent to Josh identifying the three adjacent verticals
confirmed in meeting research:

1. **logistics/supply chain** — goods-in and delivery exception NCRs
2. **professional services** — ISO-certified engineering/consulting firms
3. **property/construction** — snag lists and defect sign-offs

**Pitch template included in nudge:**

> The QR→form→agent→approval pipeline we built for [client] is near-transferable
> to [vertical] — want me to draft a 3-sentence cold pitch?

**Deduplication:** once fired, the nudge is suppressed for 30 days to avoid
repeated alerts on subsequent monthly runs. History stored in
`tmp/vertical-expansion-nudge.json`.

**Rationale:** operationalises the prototype-to-retainer funnel research signal —
60 days is enough runway to have proven the pipeline; adjacent verticals identified
share the same QR→form→agent→approval architecture and are near-zero rework to
adapt.

---

## Approval Rules

Payment chase emails: always require Josh's approval (`status = awaiting_approval`).
Internalisation risk alerts: sent directly to Telegram as informational flags —
no email queued automatically. Josh decides on the response.
Vertical expansion nudges: sent directly to Telegram as informational flags —
no email queued automatically. Josh decides whether to draft the cold pitch.
