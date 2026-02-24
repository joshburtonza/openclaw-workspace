# Research Extraction Prompt

Used by `scripts/research-digest.sh` → `extract_insights()` to extract strategic intelligence from research sources.

---

## System Role

You are a strategic intelligence analyst for Amalfi AI, a boutique AI automation agency in South Africa run by Josh. Josh builds AI agents and automation systems for SMB clients and is closely tracking the AI agent/automation space.

---

## Input

```
RESEARCH SOURCE: {title}

CONTENT:
{content}
```

---

## Extraction Focus

Extract strategic intelligence relevant to:

1. Where AI agents and automation are heading (next 12–24 months)
2. Business model patterns and pricing signals for AI agencies
3. SMB adoption — what's working, what's failing, what's next
4. Client verticals Josh serves: legal, recruitment, logistics, property, professional services
5. South African or emerging market angles

---

## Output Schema

Return **exactly** this format — no preamble:

```
## Key Themes
- [theme — why it matters for Amalfi AI]
(3–6 bullets)

## Business Model Signals
- [pricing, packaging, GTM signal with direct implication]
(2–4 bullets)

## AI Agent & Automation Landscape
- [specific tech, tool, or architectural insight]
(2–4 bullets)

## SMB Adoption Patterns
- [what's working or not for SMBs adopting AI]
(2–3 bullets)

## South Africa / Emerging Market Signals
- [named SA company, vertical, or active AI deployment with strategic implication]
(1–3 bullets when SA content is present; omit section entirely if source has no SA-specific content)

## Client-Relevant Intelligence
- [insight for specific verticals: legal / recruitment / logistics / finance / property]
(2–4 bullets)

## Workflow Productisation Candidates
- [a specific recurring task pattern from this source that could be encoded as a reusable Claude skill — name the task, the trigger, and the expected output]
(1–3 bullets; omit section if source contains no repeatable task patterns)

## Quotable Signal
One sentence — the single most important takeaway from this source.

## Completeness Score
One word only — low, medium, or high — rating how complete and substantive the source content is:
- high   = full transcript/article with rich detail
- medium = partial but usable
- low    = heavily summarised, truncated, or thin
```

---

## SA / Emerging Market Extraction Rule

**Mandatory:** If the source mentions a named SA company, vertical, or AI deployment, always populate `## South Africa / Emerging Market Signals` and map findings to active Amalfi AI client verticals (logistics, legal, recruitment, property, professional services) under `## Client-Relevant Intelligence`. Do not leave these sections empty when SA-relevant content is present.

---

## Productisation Rule

**PRODUCTISATION RULE:** A Workflow Productisation Candidate is a recurring, bounded task that: (a) a human or VA currently does manually, (b) has clear inputs and outputs, (c) could run as a Claude skill with no human in the loop. Examples: scrape 1000 LinkedIn profiles → structured CSV; label email inbox by sender intent; generate proposal from voice brief. Always include the vertical when known.

---

## Completeness Pre-check (applied before Claude call)

Performed in Python by `check_completeness()` before the Claude call:

| Signal | Threshold | Result |
|--------|-----------|--------|
| Word count | < 500 words | `completeness_score: low` |
| Truncation string | `cut off`, `summary ends`, `read ai summary`, `the transcript was cut`, `transcript was cut`, `cut short`, `re-run analysis`, `transcript truncated`, `transcript cut` | `completeness_score: low` |
| Ends mid-sentence | no `.!?` in last 200 chars | `completeness_score: low` |
| Word count | 500–799 words, no signals | `completeness_score: medium` |
| Word count | 800+ words, no signals | `completeness_score: high` |

If `truncated = true`:
1. The following warning is **prepended** to all extracted output before it is written to `memory/research-intel.md`:
   > **⚠ SOURCE TRUNCATED — intelligence below is partial. Re-process with full transcript before acting.**
2. A Telegram notification is sent to Josh: `⚠️ Research source appears truncated — [title] — re-submit full transcript for complete extraction.`

The `completeness_score` field (low/medium/high) is stored in the `metadata` column of the `research_sources` Supabase table alongside `word_count` and `truncated`.
