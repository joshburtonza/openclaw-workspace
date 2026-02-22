# Sophia Email Pipeline — Architecture & Rules

**Last updated:** 2026-02-21
**Status:** Fully operational — hallucination fix + tiered autonomy + deep client profiles

---

## How It Works (End to End)

```
Client email arrives
        ↓
sophia-csm-supabase-bridge.sh  ← inserts row → email_queue (status=pending)
        ↓
mission-control-integration.ts  ← polls every 5s for status=pending
  → analyzeEmailWithSophia()    ← writes draft to analysis.draft_body
  → sets status=awaiting_approval (complex) or status=approved (routine)
        ↓
telegram-send-approval.sh       ← sends Telegram card to Josh (if awaiting_approval)
telegram-callback-poller.sh     ← Josh taps Approve → PATCH status=approved
        ↓
email-response-scheduler.sh     ← LaunchAgent, runs every 30s
  → reads status=approved rows via service role key
  → gog gmail send (from: sophia@amalfiai.com, cc: josh + salah)
  → PATCH status=sent, sent_at, analysis.gmail_message_id
```

---

## Process Ownership (DO NOT OVERLAP)

| Process | File | Owns | Must NOT touch |
|---|---|---|---|
| Sophia analysis | `mission-control-integration.ts` | `pending` → `awaiting_approval`/`approved` | `approved` rows |
| Telegram approval | `telegram-callback-poller.sh` | `awaiting_approval` → `approved` | - |
| Email sending | `email-response-scheduler.sh` | `approved` → `sending` → `sent` | - |

**Critical rule: `mission-control-integration.ts` must NEVER process `status=approved` rows.** The bash scheduler owns that step. If you add a send loop back into `mission-control-integration.ts`, it will steal rows and silently swallow emails (marks them `sent` without actually sending via gog).

---

## Credentials

- **Anon key** (public-safe, used by frontend + Telegram scripts): in `.env` and hardcoded in shell scripts
- **Service role key** (bypasses RLS, used only by scheduler): stored in `.env.scheduler`
  Path: `/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler`
  **Never commit this file** (already in `.gitignore` via `.env.*`)

The scheduler loads `.env.scheduler` at startup and uses `API_KEY` (service role key) for all Supabase calls. Without it, RLS blocks SELECT on `status=approved` rows and the scheduler sees an empty queue.

---

## Status Lifecycle

```
pending → analyzing → awaiting_approval → approved → sending → sent
                                        ↘ approved (auto-approved routine)
                                                              ↘ error_send_failed
```

A `sent` row is only valid if it has **both** `sent_at` (timestamp) **and** `analysis.gmail_message_id` (from gog output). If `status=sent` but `sent_at=null` — the row was NOT actually sent. Something set the status incorrectly.

---

## How to Send a Test Email

```bash
# 1. Insert test row (status=approved, pointed at Josh)
curl -s -X POST "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/email_queue" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" -H "Prefer: return=representation" \
  -d '{
    "from_email": "josh@amalfiai.com",
    "to_email": "josh@amalfiai.com",
    "subject": "Pipeline test",
    "status": "approved",
    "analysis": {"draft_subject": "Pipeline test", "draft_body": "Test body."}
  }'

# 2. Run scheduler (or wait 30s for LaunchAgent)
bash email-response-scheduler.sh

# 3. Confirm: row should have status=sent, sent_at set, gmail_message_id in analysis
```

Or just run: `bash test-email-pipeline.sh`

---

## Key Files

| File | Purpose |
|---|---|
| `sophia-email-detector.sh` | Owns ALL Gmail access: search, read, mark-as-read, insert into email_queue |
| `email-response-scheduler.sh` | Sender — gog gmail send (picks up `approved` + `auto_pending` past window) |
| `telegram-send-approval.sh` | Approval card (Approve/Adjust/Hold) + FYI card (Hold only) for auto_pending |
| `telegram-callback-poller.sh` | Handles Josh's approve/hold/adjust taps |
| `sophia-github-context.sh` | Fetches recent commits from GitHub, formats as plain English for client emails |
| `sophia-ooo-cache.sh` | Josh availability check (15-min cache) |
| `.env.scheduler` | Service role key (secret, never commit) |
| `test-email-pipeline.sh` | Automated pipeline health check |
| `sophia-ai-brief.md` | Weekly AI news brief (written by cron, read by Sophia) |
| `sophia-csm-system.md` | ⚠️ LEGACY — superseded by inline cron prompt |

## Cron Jobs (Sophia-related)

| Cron | Schedule | Purpose |
|---|---|---|
| `46a4afb6` — 20-Min Email Polling | every 20 min | Main Sophia loop: detect → classify → draft → notify |
| `f1e2d3c4` — 3-Day Follow-Up | daily 12pm UTC | Proactive check-ins for silent clients |
| `a1b2c3d4` — Weekly AI Brief | Mon 6am UTC | Researches + writes `sophia-ai-brief.md` |
| `b972e349` — Silence Detection | daily 6pm SAST | Telegram alerts for 7+/14+ day silences (DB-based) |

---

## Architectural Split (2026-02-21) — LLM is Draft-Only

**Rule**: The LLM (Sophia cron) NEVER touches Gmail and NEVER inserts into email_queue.

| What | Owner |
|------|-------|
| Detect unread emails (`gog gmail search`) | `sophia-email-detector.sh` |
| Read thread content (`gog gmail thread get`) | `sophia-email-detector.sh` |
| Mark as read (`gog gmail thread modify --remove UNREAD`) | `sophia-email-detector.sh` |
| Insert into `email_queue` | `sophia-email-detector.sh` |
| Dedup (DB-level) | `gmail_thread_id UNIQUE` constraint |
| Write draft text | LLM only |
| PATCH `analysis` / `status` | LLM only |
| Send Telegram card | LLM only |

**Why**: The LLM was fabricating inbound emails using system prompt context (client names, project names). Moving all Gmail access and queue insertion to deterministic bash eliminates the hallucination attack surface entirely.

**Migration required**: Run `20260221_gmail_thread_id.sql` in Supabase SQL Editor to add `gmail_thread_id TEXT` column with partial unique index.

---

## What Went Wrong (2026-02-21) — Hallucination Fix

**Bug**: Sophia cron used `gog gmail search is:unread` but never marked emails as read after processing. Every 20-min run re-detected the same unread email and created a new draft. The LLM also did the "no emails found" check in natural language — unreliable.

**Fix**:
1. Created `sophia-email-detector.sh` — deterministic pre-flight: searches Gmail, deduplicates against email_queue (24h window), **marks emails as read immediately**, outputs JSON array of new emails.
2. Updated Sophia cron (`46a4afb6` in `cron/jobs.json`) to call the detector script first. If output is `[]`, reply NO_REPLY and stop — the LLM never sees historical context and cannot hallucinate.
3. LLM now only drafts when EMAILS_JSON has actual content from the script. Hard rules prevent referencing emails not in EMAILS_JSON.

**Key file**: `sophia-email-detector.sh`

---

## What Went Wrong (2026-02-20) — For Reference

Three bugs were fixed in one session:

1. **`mission-control-integration.ts` had a `TODO` stub** — called `sendApprovedEmail()` which set `status=sent` without calling gog. Ran every 5s, always beat the 30s scheduler.
2. **`echo "$ROWS" | python3 - <<'PY'`** — heredoc overrides the pipe for stdin, so `open(0).read()` returned empty string. Fixed by exporting ROWS as env var.
3. **Anon key blocked by RLS** — scheduler now uses service role key from `.env.scheduler`.

These bugs combined meant the approval pipeline had **never successfully sent a single email via scheduler** since it was built.
