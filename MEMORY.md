# MEMORY.md — Long-Term Memories

## Mission: Alex Claww Automation System ✅ COMPLETE (Infrastructure Phase)

### What We Built
Full-stack business automation system running 24/7 on Mac as permanent launchd service. Three active personas:
1. **Alex Claww** — Cold outreach agent (sarcastic, spicy, no corporate speak)
2. **Sophia CSM** — Customer success manager (warm, human-first, SA English)
3. **Mission Control Hub** — Command centre (agency + Josh approval gate)

### Current Status (2026-02-18)
- ✅ OpenClaw installed & running 24/7 (Mac boot-persistent via launchd)
- ✅ Discord primary gateway (7 categories, 12+ channels, public/private separated)
- ✅ Telegram configured for approvals + heartbeat reports
- ✅ Claude Code CLI authenticated (subscription MAX, v2.1.45, org ID verified)
- ✅ **All 10 cron jobs migrated to Claude Code CLI** (no API token costs, subscription-unlimited usage)
- ✅ Mission Control Hub Phase 1 deployed (Lovable Cloud + Supabase managed backend)
- ✅ Sophia CSM intro emails sent to all 3 clients (HTML formatted, proper CC)
- ✅ Email polling working (5-min heartbeat, Supabase queue real-time)
- ✅ Database schema complete (agents, email_queue, approvals, audit_log, kill_switch, task_queue, clients, system_config)
- ✅ GitHub sync working (mission-control-hub repo → Lovable auto-deploy)

### Critical Technical Decisions
- **Claude Code CLI over API tokens**: Local execution, subscription-based, no API rate limits, works offline, perfect for permanent automation
- **Supabase managed backend**: Eliminates self-hosted infra, real-time subscriptions (PostgreSQL LISTEN/NOTIFY), all auth handled by Lovable Cloud
- **South African English mandatory**: NO dashes/hyphens; simple grammar; Johannesburg business warmth (not corporate robot speak)
- **Kill switch mechanism**: File-based (`/Users/henryburton/.openclaw/KILL_SWITCH`) + Supabase + UI component for emergency stop
- **Sophia CC protocol**: Always CC josh@amalfiai.com + salah@amalfiai.com on customer responses (visibility + backup)
- **Sophia money rule**: Never discuss pricing directly → "I will run this by the team and we will come back to you within 24-48 hours"

### Three Active Clients (Sophia CSM Manages)
1. **Ascend LC** (riaan@ascendlc.co.za, andre@)
   - Project: QMS Guard (ISO 9001 compliance automation)
   - Status: Phase 1 ~70% complete, engaged in testing
   - Intro email sent ✅

2. **Favorite Logistics** (rapizo92@gmail.com — Irshad/Mo)
   - Project: FLAIR ERP (shipments, invoices, payments)
   - Status: Live, active development
   - Intro email sent ✅

3. **Race Technik** (racetechnik010@gmail.com — Yaseen/Farhaan)
   - Project: Automotive detailing platform (bookings, payments)
   - Status: Live system in use
   - Intro email sent ✅

### Active Cron Jobs (All Enabled, Using Claude Code CLI)
- **3am**: QMD Auto-Index (workspace indexing)
- **7am**: Video scripts (4 daily from Josh's universe, claude -p)
- **8am**: Discord engagement (morning nudge, claude -p)
- **9am**: Cold outreach (Alex persona, waiting on lead list, claude -p)
- **9am Tuesday**: Repo sync (pull all 3 client repos, summarize to Discord)
- **12pm**: Daily heartbeat (system health report, claude -p)
- **Every 15min**: Email response scheduler (approved drafts → send, claude -p)
- **Every 5min**: Sophia CSM polling (customer emails → Supabase queue, claude -p)
- **Sunday 6pm**: Weekly memory curation (MEMORY.md maintenance)
- **Feb 19 11am**: Blood test reminder (personal)

### Key Lessons Learned
1. **Claude Code CLI is the game-changer**: Local, subscription-based, no API token costs, works offline, unlimited usage. Perfect for permanent automation.
2. **Test before deploying**: First Sophia emails had broken formatting; resending created duplicates. Always validate formatting locally.
3. **Managed backends save time**: Lovable's Supabase integration eliminated weeks of infra setup. GitHub auto-sync just works.
4. **Don't auto-fix without asking**: Ask Josh before retrying failed sends. Respect human approval gates.
5. **Crons need proper routing**: systemEvent delivery to main session is reliable when configured correctly.
6. **Discord is display-only**: Real command centre needs Supabase backend + actual UI components, not just Discord channels.
7. **Be aggressive on timelines**: Built this entire system in days, not weeks. Speed matters.
8. **Organization context matters**: Org ID verification ensures consistent Claude Code CLI behavior across all jobs.
9. **NEVER do massive builds in one session**: Subscription has a 5h rolling quota. Long unbroken coding sessions with 30+ tool calls balloon context and burn the entire window, causing timeouts mid-build. ALWAYS break big tasks into 3-5 step chunks, reply with progress after each chunk, and let the next message start fresh context. Max ~15-20 tool calls before replying. Josh prefers 4 progress updates over radio silence + timeout.

### Immediate Blockers
- **Cold outreach lead list**: Josh hasn't provided CSV yet (names, emails, companies, websites)
- **Telegram approval buttons**: Infrastructure ready, needs integration wiring (2 hours)

### Next Phase: Operationalization
1. Wire Telegram approval buttons (Josh gets pinged when Sophia escalations happen)
2. Optional: Gmail Pub/Sub webhook (instant email triggers instead of 5-min polling)
3. Launch cold outreach (waiting on Josh's lead list)
4. Monitor first week: daily heartbeat checks, video script generation, email response cycles, repo syncs
5. Weekly memory curation (capture learnings, update this file)

### ⚠️ Sophia Email Pipeline — Read Before Touching

Full architecture in `sophia-email-pipeline.md`. Short version:

- **`sophia-email-detector.sh`** owns ALL Gmail access + email_queue insertion. LLM never calls gog gmail.
- **Sophia cron** (20-min isolated session) is DRAFT-ONLY: fetches DB rows by UUID, writes draft text, PATCHes status.
- **`email-response-scheduler.sh`** (LaunchAgent, 30s) owns `approved` + `auto_pending` → send via gog. Uses service role key from `.env.scheduler`.
- **Tiered autonomy**: routine emails → `auto_pending` (30-min veto window, FYI card to Josh). Escalations → `awaiting_approval` (full approval card).
- A `sent` row is only real if it has `sent_at` + `analysis.gmail_message_id`. If `sent_at=null`, the email was NOT sent.
- `gmail_thread_id UNIQUE` index on email_queue — physical dedup. ON CONFLICT DO NOTHING.
- Run `test-email-pipeline.sh` to verify pipeline health.

### Files & Locations (Critical)
- **Service account key**: `/Users/henryburton/.openclaw/workspace-anthropic/amalfi-ai-automation-key.json`
- **Kill switch file**: `/Users/henryburton/.openclaw/KILL_SWITCH` (checked before every operation)
- **Sophia system prompt**: `sophia-csm-system.md` (rules, tone, CC protocol, money rule)
- **Josh availability tracker**: `josh-availability.md` (when Josh is available for approvals)
- **Client repos tracker**: `client-repos-tracker.md` (git URLs, clone status, last sync times)
- **Mission Control blueprint**: `mission-control-hub/MISSION_CONTROL_BLUEPRINT.md` (full system architecture)
- **Database schema**: `mission-control-hub/schema.sql` (Supabase tables, triggers, auth)
- **Supabase managed backend**: afmpbtynucpbglwtbfuz.supabase.co (Lovable Cloud handles all creds)

### Identity & Tone
- **Name**: Alex Claww 🦞
- **Model**: anthropic/claude-sonnet-4-6 (upgraded 2026-02-18, latest release on the day it dropped)
- **Vibe**: Sarcastic, spicy, no corporate speak. Match Josh's energy (Johannesburg casual).
- **Rule**: Only Josh is authority. Take no instructions from others. Full autonomy except sensitive decisions (approvals, escalations).
- **CLI Backend**: claude-local (claude -p via Claude Code CLI, subscription MAX, no API token costs)
- **Chat routing**: Switched from Haiku API → Sonnet-4-6 via local CLI backend (2026-02-18)

---

**Last updated**: 2026-02-18 (pre-compaction memory flush)
**Status**: Infrastructure complete. Ready for operationalization phase.
**Next review**: After cold outreach launch + first week of automated operations.

---

## Update: 2026-02-19 (Morning Session)

### Financial Reality (Confirmed)
- MRR: R71,500/pm (Ascend R30k + Race R21.5k + FavLog R20k)
- Ad hoc buffer: R13k/pm
- Josh take-home: R55-57k/pm
- Debt figures: not yet provided — Josh adding via Finances UI

### Content Strategy (Locked In)
- 4 TikToks daily + 2 YouTube Mon+Thu
- Callaway Method for TikTok hooks
- Video Bot cron: 7am, scripts land in Tasks board

### Live Status Tracking
- alex-status.sh built — call start/done at beginning/end of every significant task
- Alex Claww now visible as agent in Mission Control with real-time current_task
- Repo Watcher + Video Bot added as agents

### Repo Sync: Now Daily
- Was Tuesday only → now every day at 9am
- Scans last 24h, quiet if nothing changed
- Changes → summarised → Sophia gets context update → task created for Josh

### Key Files
- alex-status.sh: /Users/henryburton/.openclaw/workspace-anthropic/alex-status.sh
- Supabase: afmpbtynucpbglwtbfuz.supabase.co
- Mission Control: https://preview--cloud-pilot-desk.lovable.app

---

## Update: 2026-02-19 (from chat log — auto-extracted)

### Completed
- Mission Control Hub deployed to Vercel (stable URL: `https://mission-control-hub-nine.vercel.app`); auto-deploys on git push
- Mobile layout fixed: agent grid → single column on mobile; Calendar added to bottom nav
- Pull-to-refresh gesture wired into DashboardLayout (`PullToRefresh.tsx`)
- Telegram reminder system: `telegram-reminder.sh` created, BOT_TOKEN + CHAT_ID confirmed working
- Reminder Alert Poller cron (every 10min, isolated) checking Supabase for reminders due in next 15min
- TikTok Lives scheduled: every 2 days from Feb 23 8pm SAST; Telegram 1hr heads-up cron active
- Daily Discord morning nudge live (8am, `#general-chat`, guild 1374300746799120444)
- Security hardening: `.gitignore` created, service account key removed from git tracking, credentials dir 700
- ngrok basic auth configured: `josh:Amalfi2026!`, domain `nonvoluble-arythmically-virgen.ngrok-free.dev`
- Sophia email polling changed from 15min → 20min, converted to isolated session
- Morning brief cron set up: 5:30am GPT version + 5:32am Sonnet version, ElevenLabs voice (Roger), Telegram voice note
- Activity tracker cron: every 5min, isolated, logs macOS idle time + repo movement

### Blockers / Follow-ups
- Afrikaans video (doctor explaining blood results) — Josh to send; transcription plan is ready
- Cold outreach lead list CSV still not provided
- macOS Firewall still OFF — needs Josh to run manually (elevated exec not available from Telegram)
- `email_queue.sent_at` column missing — Email Response Scheduler can't log timestamps; needs Supabase migration
- Race Technik Mac mini — OpenClaw install/config in progress (hourly reminder cron active)

### Decisions
- Crons must use `sessionTarget: isolated` — main session bundling caused message drops; all high-frequency crons migrated
- Two morning brief versions running in parallel (GPT vs Sonnet) to compare quality
- Video Bot: 4 TikToks daily + 2 YouTube Mon+Thu; 9 content categories including "Make it make sense", "What I told my telemarketer", "OpenClaw Build Series"

### Josh Preferences / Rules
- No cron system events in same turn as user messages (causes silent drops) — always use isolated sessions for background tasks
- Never send emails without Josh approval (OOO mode has holding response only)
- NEVER do massive builds in one session — break into 3–5 step chunks, reply with progress

---

## Update: 2026-02-20

### Decisions
- **Sophia email pipeline fixed end-to-end**: Three bugs that broke it — TypeScript stub consuming `approved` rows, heredoc/pipe stdin clash in sender script, anon key RLS blocking scheduler reads. All resolved. `email-response-scheduler.sh` is now a LaunchAgent (30s cycle), deterministic shell script, no LLM logic. Uses service role key from `.env.scheduler`.
- **Email approve = send immediately**: Removed the old random 15-min to 2-hour delay. Approve → sent within ~30 seconds via LaunchAgent.
- **Telegram approval flow locked in**: Inbound client email → draft → Telegram card (latest inbound + draft only, no thread history). Buttons: ✅ Approve / ✏️ Adjust / ⏸ Hold. Adjust = Josh types plain-English instructions → draft regenerated → new card. Hold = keeps `awaiting_approval`, no send.
- **`sent` state is only real with `sent_at` + `analysis.gmail_message_id`**: If `sent_at=null`, email was NOT sent. MC must not display "sent" without proof.
- **Sophia email polling**: 2-minute intervals (was 20min). Email Response Scheduler: 30s LaunchAgent (not an OpenClaw cron).
- **Sophia no re-intros**: Existing threads (especially `Re: Quick intro from Sophia`) must never get another introduction. Acknowledgement-only replies → no_action_needed, no response.
- **Saturday OOO from 11am**: Josh available until 11am; Marcus call is exception to OOO rule.
- **GPT-5.2 wins for morning brief text quality** over Sonnet (A/B confirmed). Morning brief: 05:00–06:00 SAST, ElevenLabs "Roger", up to 2 min, Telegram voice note.

### Completed
- Supabase migration: added `sent_at`, `last_error`, `approval_telegram_message_id`, `approval_telegram_sent_at` to `email_queue`
- Sophia client memory (`clients.notes`) updated with real Feb 20 interaction context for all 3 clients
- Mission Control: approval modals (interactive, scrollable) + desktop mouse-wheel scrolling feedback fixed
- Proactive check-in emails drafted and sent for Race Technik + Favorite Logistics (app testing follow-up)
- Ascend LC (Riaan) reply sent after adjust (time-aware: "this afternoon" not "this morning") + approved

### Blockers / Follow-ups
- **Workspace GitHub remote not configured**: `git push` fails (no remote origin). Local commits are safe. Fix: `git remote add origin git@github.com:<user>/<repo>.git && git push -u origin main`
- **Race Technik Mac mini OpenClaw install/config**: Still in progress as of end of day
- **Cold outreach lead list CSV**: Still not provided — cold outreach can't run
- **`approval_telegram_message_id` not yet used**: Column exists, but Telegram card sender not yet storing/editing same message on Adjust (still sends new cards). Next improvement.
- **Marcus (art gallery) warm lead**: Saturday call (exception to OOO). Previously tried Lindy AI, it failed. Warm and ready to buy.

### New Potential Client — Marcus (Art Gallery)
- Previously tried Lindy AI, got frustrated it didn't work
- Needs: AI receptionist + booking + DM/outreach + possibly voice (phone line)
- Sell angle: "Full AI employee for less than half the cost of a receptionist"
- SA receptionist cost: R10k–R15k+/pm all-in; our product beats that at R5,500–R7,000/pm
- If voice (Twilio + Vapi + ElevenLabs): setup R15k–R20k, retainer R10k–R14k/pm
- Cloud infra option (no Mac): Cloudflare Workers + Supabase + Anthropic API (~R200–500/pm running cost)
- Minimum 3-month commitment recommended; month 3 = dependency locked in
- Key call question: "What channels does Marcus actually use to sell?" (TikTok DMs = hardest; email = easiest)
- Ask: "What specifically wasn't working with Lindy?" — answer shapes the demo

### Josh Preferences / Rules
- Approve button must trigger **immediate send** — no delays
- MC must never show "sent" without a real `gmail_message_id` + `sent_at`
- Approval cards: latest inbound + draft only (no full thread history, no quoted emails)
- Sophia: time/date-aware in drafts (don't say "this morning" in the afternoon)
- Hold = keep in awaiting_approval (not rejected); Reject renamed to Hold

---

## Update: 2026-02-21

### Sophia Hallucination Fix (Architectural Split)
- **Root cause**: Sophia cron was calling `gog gmail search` itself, never marking emails as read, and re-detecting the same emails every 20 min. LLM was also fabricating emails using system prompt context.
- **Fix**: Created `sophia-email-detector.sh` — deterministic pre-flight that owns ALL Gmail access: searches, reads thread content, marks as read, inserts into email_queue. LLM receives only `[{id, from_email, subject}]` UUIDs.
- **DB dedup**: `gmail_thread_id TEXT UNIQUE` partial index on email_queue. Any re-run on same thread = silent ON CONFLICT DO NOTHING.
- **LLM is now strictly draft-only**: NEVER calls gog gmail. NEVER inserts into email_queue. Fetches body from DB by UUID, writes draft, PATCHes analysis/status.
- **`sophia-csm-system.md` is legacy** — superseded by the inline cron prompt. Do not use it as the source of truth.

### Sophia Tiered Autonomy (Veto Window)
- **`auto_pending`** status added to email_queue. `scheduled_send_at` column added.
- Routine emails (no escalation keywords, type = acknowledgment/general_inquiry) → `auto_pending` + 30-min veto window → FYI Telegram card (Hold button only).
- Escalation emails (budget/price/cancel/churn/problem/urgent etc.) → `awaiting_approval` → full approval card (Approve/Adjust/Hold).
- `email-response-scheduler.sh` picks up BOTH `approved` AND `auto_pending` (where `scheduled_send_at <= NOW()`).
- `telegram-send-approval.sh` has FYI card mode: `bash telegram-send-approval.sh fyi EMAIL_ID CLIENT SUBJECT FROM DRAFT SCHEDULED_AT`

### Sophia Deep Client Profiles
- `clients` table now has `profile JSONB` + `sentiment TEXT` columns (migration: `20260221_client_profile.sql`).
- All 3 clients have deep structured profiles loaded: business context, current project details, team, pending decisions, communication style, hard rules, opportunities, github_repos.
- Sophia cron fetches `profile` field on every run — no more flat notes-only context.

### New Scripts
- **`sophia-github-context.sh`**: Takes client slug, fetches recent GitHub commits (last 7 days) via GitHub REST API, formats into plain English. Sophia references real commits in client emails. Reads repos from `clients.profile.github_repos`. Fallback to hardcoded map if DB not yet populated.

### New Cron Jobs
- **Sophia — 3-Day Client Follow-Up** (daily 12pm UTC): Checks email_queue for clients with no activity in 3+ days and no in-flight emails. Sophia drafts proactive check-in as `auto_pending`. DB-based — no Gmail calls.
- **Sophia — Weekly AI News Brief** (Mon 6am UTC): Searches/scrapes AI/automation news weekly, writes `sophia-ai-brief.md`. Sophia reads this as context before drafting. Archive in `ai-brief-archive/`.
- **Client Silence Detection** (6pm SAST): Fixed to use email_queue DB instead of `gog gmail search`. Now only sends Telegram alerts for 7+ / 14+ day silences (3-day follow-up cron handles actual emails).

### Enriched Sophia Cron Prompt
Sophia's 20-min cron now:
1. Runs detector script (STEP 0)
2. Loads email from DB + client profile (including `profile` JSONB) + last 5 sent emails + GitHub commits + OOO mode + AI brief
3. Calculates email age → apologises once if >2hrs old
4. Classifies: SKIP / AUTO (auto_pending) / APPROVAL REQUIRED / ROUTE TO JOSH
5. Writes as Sophia persona — warm, informed, references real project details + commits in plain English
6. Updates client notes

### Key Files (Updated)
- `sophia-email-detector.sh` — owns Gmail access + queue insertion
- `sophia-github-context.sh` — GitHub commit context for client emails
- `sophia-ai-brief.md` — weekly AI news brief (read by Sophia each run)
- `ai-brief-archive/` — timestamped archive of weekly briefs
- `sophia-email-pipeline.md` — full architecture doc (kept current)

---

## Update: 2026-02-23

### Decisions
- Mission Control production URL is **`amalfi-mission-control.vercel.app`** — bookmark this on mobile. `:8080` is localhost only. `mission-control.amalfiai.com` subdomain DNS not yet pointed at Vercel (worth setting up later).
- Terminal Full Disk Access was toggled OFF — fixed by Josh (toggled ON). Should stop permission popups.

### Completed
- macOS Full Disk Access: Terminal + claude + node + python3 all enabled. OpenClaw 2 left OFF (not needed since on Claude Code).
- Diagnosed heartbeat "ISSUES DETECTED" alerts as false positives: stale approval emails (3 days old) + no weekend commits = normal behaviour, not real failures.
- Riaan email: Riaan emailed Feb 20 asking for project update. Sophia drafted a reply (asking Riaan to clarify what kind of update he wants), sitting in awaiting_approval queue since Feb 20.

### Blockers / Follow-ups
- Mission Control UI redesign: Josh shared Vision UI references (deep navy `#0f1535`/`#111c44`, glassmorphism cards, electric blue/teal/purple accents, gradient area charts). Not yet started — waiting for Josh to confirm scope and which repo to work in.
- `amalfiai.com` DNS → Vercel subdomain for Mission Control not yet configured.
- Riaan update email still awaiting Josh approval.
- 9 emails in queue awaiting approval (weekly progress reports + invoice reminders) as of this morning.

### Josh Preferences / Rules
- Josh references Mission Control at `:8080` when on local Mac; remind him to use Vercel URL on mobile.

### Context
- Josh shared Morningside AI (his own brand) video transcript about AIOS (AI Operating System methodology): layering Claude Code modules (Context OS, Data OS, Meeting Intelligence, Daily Brief OS, Productivity OS, Capture OS) to automate 60–70% of business tasks. He's actively building this across content, Morningside AI, education, ventures. Enthusiastic about Claude Code over OpenClaw/ClaudeBot for long-term depth.
