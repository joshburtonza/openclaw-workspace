# Email Classifier — Inbound Signal Reference

> Maintained by: Amalfi AI internal systems
> Source: Meeting — Joshua / Salah (2026-02-23)
> Implementation: `sophia-email-detector.sh` (keyword scan at insertion time)

---

## Repricing / Formalization Signal (`repricing_trigger`)

**Research motivation:**
> "When a client tries to hire you, you've accidentally undersold yourself — use it as a repricing event, not a career decision."

When a client email contains employment or absorption language, it signals that the value being delivered exceeds the price being charged. The correct response is not to evaluate the offer as a career decision — it is to treat it as evidence of under-pricing and initiate a repricing conversation.

### Trigger keywords

| Keyword         | Signal                                      |
|-----------------|---------------------------------------------|
| `full-time`     | Client seeking dedicated/exclusive resource |
| `join us`       | Direct employment probe                     |
| `hire you`      | Direct employment probe                     |
| `in-house`      | Client exploring internalising the function |
| `exclusivity`   | Attempt to absorb or lock out other clients |
| `bring you on`  | Integration/absorption language             |
| `salary`        | Compensation discussion = employment framing|
| `employment`    | Explicit employment language                |
| `employee`      | Explicit employment language                |
| `hire`          | General hiring intent                       |
| `full time`     | Variant spelling                            |
| `in house`      | Variant spelling                            |
| `bring you on board` | Variant phrasing                      |
| `integrate your team` | Team-level absorption                |

### Detection location

`sophia-email-detector.sh` — runs at insertion time before any LLM classification.

Sets in `email_queue.analysis`:
- `repricing_trigger: true`
- `formalization_signal: true` (kept for backward compatibility with Mission Control)

### Routing behaviour

Handled in `prompts/sophia-cron.md` — **STEP 2b**:

1. Forces classification to **APPROVAL REQUIRED** (no auto-send)
2. Prepends `🚨 REPRICING EVENT DETECTED` banner to draft body before the greeting
3. Sets both `repricing_trigger` and `formalization_signal` flags in the PATCH payload
4. Sends approval card to Telegram (Approve / Adjust / Hold)

### Banner text (as of 2026-02-23)

```
🚨 REPRICING EVENT DETECTED
─────────────────────────────────────────────────────────────────
One or more keywords in this email suggest the client may be signalling
under-pricing. When a client tries to hire you, you've accidentally
undersold yourself — use this as a repricing event, not a career decision.
Do not treat as an employment offer. Review carefully before replying.
Do not commit to any exclusivity, employment terms, or operational
integration language. Contractor status preserves leverage — catch this
early and use it to reprice.
─────────────────────────────────────────────────────────────────
```

---

## Other Classifier Signals

### Churn / Budget risk (handled in STEP 3)

Keywords: `cancel`, `canceling`, `budget review`, `not sure it's worth`, `thinking about`, `value`, `reconsidering`, `unhappy`, `frustrated`, `urgent`, `asap`

→ Routes to APPROVAL REQUIRED with churn-retention flow (see `prompts/email/ascend_lc_retention.md` for Ascend LC).

### Over-promise language (handled in STEP 4b)

Scanned in draft body before finalisation. See `prompts/email-response-scheduler.md` for the full guard table.

---

## Adding New Keywords

To add a new repricing keyword:
1. Add the string (lowercase) to `REPRICING_KEYWORDS` list in `sophia-email-detector.sh`
2. Document it in the table above
3. No restart required — takes effect on next cron run
