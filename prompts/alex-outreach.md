# Alex Outreach — Prompt Logic Reference

Script: `scripts/cold-outreach/run-alex-outreach.sh`

---

## Value Proposition Anchor

Use this concrete ROI benchmark in the opening value proposition — **replace any vague "save time" or "improve efficiency" language** with this specific claim:

> "Operators using our stack reclaim 60–70% of repetitive admin time within 90 days."

This is the primary conversion anchor. Integrate it naturally into the email — do not quote it verbatim. Pair it with the vertical-specific outcome hook below.

**⚠️ Note for Josh:** Validate the 60–70% figure against your actual client results before first send. If your data supports a different range, update this file with the verified number.

Source: Meeting: Notes: Meeting Jan 15, 2026 at 9:14 AM SAST; AIOS research ("60-70% automation as the pitch number")

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
| `media_entertainment` | media, entertainment, broadcast, television, tv channel, lifestyle channel, streaming, publishing, magazine, events, advertising sales, sponsorship | ad sales pipeline automated, subscription acquisition on autopilot, and event promotion handled without manual outreach |
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

### Media & Entertainment Variant

When the detected vertical is `media_entertainment`, **lead the hook with the two primary pain anchors** — ad sales pipeline and subscription acquisition — before mentioning event promotion:

> "Adapt this reference (do not copy verbatim): *ad sales pipeline automated so reps spend time closing, not chasing, subscription acquisition running on autopilot, and event promotion outreach handled without manual follow-up.*"

**Three use-case anchors to reference (in order of priority):**
1. **Ad sales pipeline automation** — TV/media sales teams waste time on manual prospecting and follow-up; position Amalfi AI's voice agent as the outbound layer that qualifies advertisers before human reps engage.
2. **Subscription acquisition** — lifestyle/streaming channels need continuous subscriber pipeline; position outbound voice agent as the acquisition channel that replaces cold-call teams.
3. **Event promotion** — media companies run recurring events (launches, screenings, live shows); position voice agent as the outbound reminder and RSVP capture layer.

**Step 1 framing guidance:** After self-intro, drop in the ad sales hook first ("I notice you run [ad-supported / subscription] content — a lot of media teams we talk to are looking to…"), then pivot to audit CTA.

**Rationale:** TV channels and media companies are a non-obvious vertical — they have structured sales pipelines (ad sales, sponsorship, subscriptions) but rarely associate them with voice automation. Naming the specific pipeline removes the "that's not for us" objection early.

Source: Meeting: Notes: "Voice Assistant Meeting" Jan 22, 2026

---

## SA Enterprise Proof-Point Positioning

**Lead with a named operational problem — not 'AI transformation'.**

Research from the AleadX/Two Rivers mining engagement confirms that problem-first positioning is what converts SA enterprise prospects into procurement meetings. The winning frame is not "we do AI automation" — it is "we know what this specific problem costs you and we've already solved it for someone like you."

### Instruction to Claude

When composing step 1 outreach to any prospect in the `industrial`, `logistics`, or similarly operationally-complex vertical, apply the following three-part proof-point structure **inside the email body**, before the demo/audit CTA:

**1. Name one high-cost operational problem specific to their vertical.**
Do not use generic language. Identify the single most costly recurring failure mode in their sector — the kind of problem that has a name internally, costs real money per incident, and is accepted as unavoidable. Examples by vertical:

| Vertical | Named problem |
|---|---|
| Mining / resources | "Fall of ground" incidents and associated production stoppages; manual shift reporting delays that obscure safety signals |
| Logistics / freight | Manual booking errors causing missed SLAs; dispatcher-to-driver handoff failures at peak volume |
| Industrial / manufacturing | Compliance reporting backlogs; unplanned downtime traced to missed maintenance triggers |
| Legal / property | Contract intake bottlenecks; manual document routing that delays deal close |

Frame it as: *"Most [vertical] operators we speak to are dealing with [named problem] — and it's usually not flagged until it's already cost them [concrete consequence: production hours, SLA penalties, compliance exposure]."*

**2. Reference that SA enterprises in similar sectors are already live with AI solutions.**
Use the Two Rivers / mining engagement as the template signal. Do not name the client. The framing is:

> *"We're already live with operations in the SA resources sector — the tooling is deployed locally, not dependent on overseas infrastructure."*

Adapt the sector reference to match the prospect's vertical (e.g. "SA logistics operators", "SA processing plants", "SA legal practices"). The goal is to neutralise the "AI isn't ready for our environment" assumption before the prospect raises it.

**3. Pre-empt the 'AI isn't ready locally' objection.**
SA enterprise buyers — particularly in mining, resources, and heavy industry — default to scepticism about AI reliability in local/remote operational environments. Address this in one sentence, matter-of-factly, not defensively:

> *"The infrastructure runs on-site — no cloud dependency, no latency from overseas data centres."*

or (if cloud is acceptable for the vertical):

> *"The stack is configured for the SA regulatory and connectivity environment — it's not a plug-in from overseas."*

Only one of these sentences is needed. Choose based on what you know about the prospect's operational context. If no information is available, use the on-site framing as the safer default for industrial verticals.

### Placement in Email

Insert the proof-point block as a single flowing paragraph **between the self-intro and the CTA** — do not use bullet points in the email itself. The paragraph should read as earned insight, not a credentials list. Three sentences maximum: problem name → SA live reference → local-readiness signal.

Source: Meeting: Meet Meeting / Dec 9 (AleadX/Two Rivers engagement debrief)

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
