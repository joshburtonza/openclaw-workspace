# Email Response Scheduler — Prompt Reference

> **Note:** The active system prompt for Sophia's email drafting pipeline is
> `prompts/sophia-cron.md`. This file documents the over-promise language guard
> that was added to that prompt (2026-02-23, per Josh/Salah meeting).

---

## Over-Promise Language Guard

Added as **STEP 4b** in `prompts/sophia-cron.md`, immediately before the
database PATCH step.

### Flagged phrases → hedged replacements

| ❌ Over-promise          | ✅ Hedged replacement                     |
|--------------------------|-------------------------------------------|
| "will definitely"        | "we aim to"                               |
| "can automate everything"| "typically achieves significant automation"|
| "guaranteed"             | "targeting"                               |
| "100%"                   | "the goal is"                             |
| "fully automated"        | "largely automated"                       |
| "no manual work"         | "minimal manual overhead"                 |

### Scope creep detection

If the client's email implies work outside the agreed engagement scope,
the draft must open with a `[SCOPE NOTE]` block (before the greeting):

```
[SCOPE NOTE: Client request appears to include [brief description].
This falls outside the current engagement scope.
Josh/Salah to confirm before this is addressed in a reply.]
```

If no scope creep is detected: the block is omitted entirely.

---

## Proof-of-Value Framing (Prospect / Evaluation Follow-ups)

Added as a `★ PROOF-OF-VALUE FRAMING` rule in `prompts/sophia-cron.md` STEP 4, before the Calibration Retainer Pitch block.

**Signal source:** Research confirms SA mid-market buyers in evaluation/demo mode require education and proof-of-value, not generic relationship pings. Vertical-specific framing measurably outperforms generic AI agency positioning in this segment.

### Rule summary

When drafting a follow-up email to a **prospect** or a client whose profile indicates evaluation/demo/pilot status, Sophia must include exactly **one vertical-matched proof point** (metric, workflow outcome, or case study reference) naturally woven into the email body.

Verticals covered: Legal/compliance · Logistics/transport · Automotive · Recruitment/HR · Manufacturing · Property · General SMB fallback.

Does **not** apply to: `bd_partner` contacts or existing retainer clients.

---

## Context

**Source:** Meeting — Joshua / Salah
**Risk flagged:** Client expectations outpacing delivery reality
**Implemented:** `prompts/sophia-cron.md` Step 4b
