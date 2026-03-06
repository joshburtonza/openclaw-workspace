# CURRENT STATE — 2026-03-05 14:30 UTC
> Manual update after Hybrid Architecture overhaul. Next auto-gen overwrites at ~01:00 UTC.

## Architecture Summary
- **46 agents**: 16 API (tiered), 28 non-API, 2 infra
- **API budget**: 6 calls/hr via claude-gated (T1: 3, T2: 2, T3: 1)
- **No supervisors**: Head-agent orchestrates directly
- **Retry queue**: claude-task-worker processes rate-limited retries
- **Desktop awareness**: T3 agents back off when Josh active

## Agent Health
  ✅ telegram-poller (T1, KeepAlive)
  ✅ head-agent (T1, 5min)
  ✅ claude-task-worker (T1, 60s)
  ✅ sophia-cron (T1, 60min)
  ✅ meeting-digest (T2, 10min)
  ✅ research-implement (T2, 10min)
  ✅ research-digest (T2, 30min)
  ✅ meet-notes-poller (T2, 10min)
  ✅ sophia-followup (T3, daily 14:00)
  ✅ sophia-outbound (T3, 60min)
  ✅ memory-writer (T3, 30min)
  ✅ weekly-memory (T3, Sun 18:00)
  ✅ daily-repo-sync (T3, daily 09:00)
  ✅ morning-brief (T3, daily 07:30)
  ✅ alex-reply-detection (T3, 4hr)
  ✅ content-creator (T3, daily 05:00)
  ✅ calendar-sync (non-API, 30min)
  ✅ rt-token-sync (non-API, 30min)
  ✅ rt-monitor (non-API, 1hr)
  ✅ data-os-sync (non-API, daily 02:00)
  ✅ agent-status-updater (non-API, 30min)
  ✅ activity-tracker (non-API, 5min)
  ✅ email-response-scheduler (non-API, 5min)
  ✅ alex-outreach (non-API, 30min)
  ✅ apollo-sourcer (non-API, Mon+Thu 08:00)
  ✅ enrich-leads (non-API, 30min)
  ✅ nightly-ops (non-API, 22:00+03:00)
  ✅ finance-poller (non-API, 07:00+18:00)
  ✅ finance-report (non-API, monthly 1st)
  ✅ fnb-email-poller (non-API, 10min)
  ✅ retainer-tracker (non-API, monthly 5th)
  ✅ statement-reminder (non-API, monthly 12th)
  ✅ pending-nudge (non-API, 09:00+15:00)
  ✅ git-backup (non-API, 6hr)
  ✅ reminder-poller (non-API, 5min)
  ✅ whatsapp-capture (non-API, daily 06:00)
  ✅ whatsapp-inbound-notifier (non-API, 5min)
  ✅ email-opens-poller (non-API, 5min)
  ✅ error-monitor (non-API, 10min)
  ✅ video-poller (non-API, 4x daily)
  ✅ tiktok-live-reminder (non-API, Mon/Wed/Fri)
  ✅ read-ai-sync (non-API)
  ✅ discord-morning-nudge (non-API)
  ✅ weekly-client-reports (T3, Tue 09:30)
  ✅ salah-weekly-brief (T3, Mon 08:30)
  ✅ aos-value-report (T3, monthly 1st)
  ✅ socks-tunnel (infra, KeepAlive)
  ✅ pinchtab (infra, KeepAlive)
  ✅ discord-community-bot (infra, KeepAlive)

## Removed Agents (in disabled-openclaw/)
  ⬜ telegram-watchdog (replaced by self-healing in poller)
  ⬜ telegram-health-check (merged into morning-brief)
  ⬜ weekly-memory-digest (merged into weekly-memory)
  ⬜ write-current-state (merged into nightly-ops)
  ⬜ salah-morning-brief (merged into morning-brief)
  ⬜ morning-content-ideas (merged into content-creator)
  ⬜ nightly-session-flush (renamed to nightly-ops)
  ⬜ 6x domain supervisors (removed — head-agent direct)
  ⬜ heartbeat, silence-detection, agent-toggle-daemon, qms-merge-1am, claude-startup, nightly-github-sync

## Email Queue
  auto_pending: 1
  awaiting_approval: 3
  rejected: 17
  sent: 20
  skipped: 9

## Pending Approvals / Auto-Sends
  ⚡ [race_technik] Checking in — Chrome Auto Care (auto_pending)
  ⏳ [ascend_lc] Ascend LC (QMS Guard) weekly progress report (awaiting_approval)
  ⏳ [favorite_logistics] Favorite Logistics (FLAIR) weekly progress report (awaiting_approval)
  ⏳ [race_technik] Race Technik (Chrome Auto) weekly progress report (awaiting_approval)

## OOO Status
  Josh available

## Repo Status
  workspace: dirty (architecture changes uncommitted)
  mission-control-hub: clean
  qms-guard: 1 behind
  favorite-flow: 6 behind

## Key Config Files
  agent-roles.json: config/agent-roles.json (46 agents, single source of truth)
  agent-priorities.conf: ~/.openclaw/config/agent-priorities.conf (tier budgets)
  claude-gated: ~/.openclaw/bin/claude-gated (6-layer API wrapper with tiers)

## Today's Changes
- Hybrid Architecture Chunks 1-5 complete (priority tiers, agent cleanup, merges, roles registry)
- Audit pass: sophia-outbound schedule fixed (15→60min), retry queue wired, head-agent synced with roles.json
- CLAUDE.md refreshed for new architecture
- telegram-claude-gateway.sh: HF images now preserved in media/generated/
- rt-monitor deployed: SSH health monitor for RT Mac Mini via Tailscale, 1hr interval, auto-restart + Supabase task + Telegram alerts
- rt-token-sync launchctl label bug fixed (com.amalfiai → com.raceai)
- Broken RT Mac Mini sophia agents disabled (scripts didn't exist there)
- Workspace + repos synced and clean
- AOS mandate confirmed: owns all client systems including remote machines
