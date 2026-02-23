# Alex Outreach — Prompt Logic Reference

Script: `scripts/cold-outreach/run-alex-outreach.sh`

---

## Vertical ROI Framing

Cold outreach uses **outcome hooks** matched to the prospect's industry vertical.
Generic "AI automation" language is replaced with a concrete, vertical-specific result.

### Industry Detection

The `detect_industry(lead)` function inspects `tags` + `notes` for industry keywords:

| Vertical | Tag/notes keywords | Outcome hook |
|---|---|---|
| `recruitment` | hr & staffing, human resources, staffing, recruitment | CV screening in under 30 seconds |
| `legal_property` | law firms, legal services, legal, attorneys, real estate, property | contract intake processed without manual triage |
| `logistics` | logistics, supply chain, transportation, freight, courier, dispatch | booking and dispatch flow without the back-and-forth |
| `industrial` | mining, mining operations, industrial, manufacturing, plant, processing, heavy industry, resources, minerals, metallurgy, smelting, refinery | compliance reporting and shift data captured automatically, no manual entry |
| `general` | (no match) | *(no hook injected)* |

### How the Hook Is Used

In **step 1** (initial cold email), after the self-intro and before the free audit CTA:

> "Before moving to the audit offer, drop in one concrete outcome example specific to their industry — one sentence, natural, not a bullet. Adapt this reference (do not copy verbatim): *[hook]*"

Claude adapts the reference to sound natural in context rather than quoting it verbatim.

Steps 2 and 3 (follow-up / graceful close) are not altered — they are short by design.

### Demo-Offer CTA Variant (Industrial / Data-Heavy Verticals)

When the detected vertical is `industrial` (or any data-heavy vertical where technical validation is the norm), **replace the standard free-audit CTA** in step 1 with the demo-offer CTA:

> "I can walk you through a live demo of how we've built this for [analogous vertical] — 20 minutes is enough to see if it fits."

**When to apply:** vertical is `industrial`. May also be applied to `logistics` at Claude's discretion when notes suggest heavy operational/data complexity (e.g. fleet telematics, plant integration, SCADA connectivity).

**Analogous vertical substitution:** Fill `[analogous vertical]` with a relatable reference industry — e.g. for mining prospects use "processing plant operations" or "resources logistics"; for manufacturing use "industrial plant scheduling". Never leave the placeholder literal.

**Rationale:** Enterprise buyers in SA mining/industrial verticals typically request a comprehensive technical overview early — single-meeting validation is the norm, not long procurement cycles. Pre-empting the demo request positions Amalfi AI as ready, not reactive.

---

## Email Sequence

| Step | Trigger | Notes |
|---|---|---|
| 1 | New lead, no prior contact | Full intro + vertical hook + free audit CTA |
| 2 | 4+ days since step 1, no reply | Short follow-up, different angle, no "just checking in" |
| 3 | 9+ days since step 2, no reply | Graceful close, door left open |

---

## Signal Rationale

> "Vertical depth beats horizontal breadth — agencies building deep in one vertical will outcompete generalists as buyers become more sophisticated."
> "Professional services clients need outcome framing — sell ROI not features."

Source: Meeting: The Future (2026)
