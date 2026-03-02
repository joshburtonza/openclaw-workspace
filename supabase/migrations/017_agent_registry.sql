-- Migration 017: Multi-Tier Agent Registry
-- Supports the Head of Snake → Supervisors → Workers orchestration architecture.
-- Every agent self-registers on each run. Head agent queries all registrations.
-- Commands flow downward; status/metrics flow upward.

-- ─────────────────────────────────────────────────────────────────────────────
-- Agent Registry
-- Every agent calls this table at the start (status=running) and end (status=idle/error)
-- of each run. This is the system's nervous system.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agent_registry (
  agent_id            TEXT PRIMARY KEY,
  tier                TEXT NOT NULL CHECK (tier IN ('head', 'supervisor', 'worker')),
  supervisor_id       TEXT,                          -- NULL for head agent
  display_name        TEXT NOT NULL,
  description         TEXT,
  domain              TEXT,                          -- 'intelligence'|'sales'|'csm'|'ops'|'finance'|'comms'
  status              TEXT NOT NULL DEFAULT 'idle'
                      CHECK (status IN ('idle', 'running', 'error', 'paused', 'disabled')),
  last_run_at         TIMESTAMPTZ,
  last_run_duration_ms INTEGER,
  last_result         TEXT,                          -- brief human-readable summary of last run
  next_run_at         TIMESTAMPTZ,                   -- expected next run (optional, set by agent)
  run_count_today     INTEGER NOT NULL DEFAULT 0,
  error_count_today   INTEGER NOT NULL DEFAULT 0,
  kpis                JSONB DEFAULT '{}',            -- agent-specific KPIs as key-value
  is_enabled          BOOLEAN NOT NULL DEFAULT true,
  machine             TEXT DEFAULT 'josh-macbook',  -- 'josh-macbook' | 'rt-macmini'
  created_at          TIMESTAMPTZ DEFAULT now(),
  updated_at          TIMESTAMPTZ DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Command Queue
-- Head agent → supervisors → workers. Agents check this table at start of each run.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agent_commands (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  from_agent_id TEXT NOT NULL,
  to_agent_id   TEXT NOT NULL,
  command       TEXT NOT NULL,
  -- 'run_now'     — trigger an immediate run
  -- 'pause'       — stop running until 'resume' command
  -- 'resume'      — resume normal schedule
  -- 'set_priority' — change next_run_at (payload: {"next_run_at": "..."})
  -- 'custom'      — arbitrary instruction in payload.instruction
  payload       JSONB DEFAULT '{}',
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'ack', 'done', 'failed', 'expired')),
  expires_at    TIMESTAMPTZ DEFAULT (now() + interval '1 hour'),
  created_at    TIMESTAMPTZ DEFAULT now(),
  ack_at        TIMESTAMPTZ,
  done_at       TIMESTAMPTZ,
  result        TEXT
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Agent Metrics (hourly/daily KPI snapshots)
-- Agents write metrics snapshots here for trending and dashboard display.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agent_metrics (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  agent_id    TEXT NOT NULL REFERENCES agent_registry(agent_id) ON DELETE CASCADE,
  period      TEXT NOT NULL,                    -- '2026-03-02' (daily) or '2026-03-02T09' (hourly)
  metrics     JSONB NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ DEFAULT now()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Indexes
-- ─────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS agent_registry_tier_idx      ON agent_registry(tier);
CREATE INDEX IF NOT EXISTS agent_registry_supervisor_idx ON agent_registry(supervisor_id);
CREATE INDEX IF NOT EXISTS agent_registry_domain_idx    ON agent_registry(domain);
CREATE INDEX IF NOT EXISTS agent_registry_status_idx    ON agent_registry(status);
CREATE INDEX IF NOT EXISTS agent_commands_to_agent_idx  ON agent_commands(to_agent_id, status);
CREATE INDEX IF NOT EXISTS agent_commands_created_idx   ON agent_commands(created_at DESC);
CREATE INDEX IF NOT EXISTS agent_metrics_agent_idx      ON agent_metrics(agent_id, period DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- Auto-update updated_at on agent_registry
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION update_agent_registry_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS agent_registry_updated_at ON agent_registry;
CREATE TRIGGER agent_registry_updated_at
  BEFORE UPDATE ON agent_registry
  FOR EACH ROW EXECUTE FUNCTION update_agent_registry_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- Expire old commands (auto-cleanup)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION expire_agent_commands()
RETURNS void AS $$
BEGIN
  UPDATE agent_commands
  SET status = 'expired'
  WHERE status = 'pending'
    AND expires_at < now();
END;
$$ LANGUAGE plpgsql;

-- ─────────────────────────────────────────────────────────────────────────────
-- Seed: initial agent registry entries (all known agents)
-- Status starts as 'idle' — agents will update on first run
-- ─────────────────────────────────────────────────────────────────────────────

-- HEAD
INSERT INTO agent_registry (agent_id, tier, supervisor_id, display_name, description, domain, machine)
VALUES
  ('head-agent', 'head', NULL, 'Head of Snake', 'Master orchestrator — full system visibility, strategic decisions, Telegram escalation', 'all', 'josh-macbook')
ON CONFLICT (agent_id) DO NOTHING;

-- SUPERVISORS
INSERT INTO agent_registry (agent_id, tier, supervisor_id, display_name, description, domain, machine) VALUES
  ('intel-supervisor',   'supervisor', 'head-agent', 'Intelligence Supervisor', 'Manages research, meetings, memory, and briefing workers', 'intelligence', 'josh-macbook'),
  ('sales-supervisor',   'supervisor', 'head-agent', 'Sales Supervisor',        'Manages lead sourcing, enrichment, outreach, and reply tracking', 'sales', 'josh-macbook'),
  ('csm-supervisor',     'supervisor', 'head-agent', 'CSM Supervisor',          'Manages Sophia email CSM, client health monitoring, outbound', 'csm', 'josh-macbook'),
  ('ops-supervisor',     'supervisor', 'head-agent', 'Operations Supervisor',   'Manages task worker, error monitoring, repo sync, backups', 'ops', 'josh-macbook'),
  ('finance-supervisor', 'supervisor', 'head-agent', 'Finance Supervisor',      'Manages financial snapshots, P&L, retainer health, value reports', 'finance', 'josh-macbook'),
  ('comms-supervisor',   'supervisor', 'head-agent', 'Comms Supervisor',        'Monitors Telegram/Discord health, pending nudges, watchdog', 'comms', 'josh-macbook')
ON CONFLICT (agent_id) DO NOTHING;

-- INTELLIGENCE WORKERS
INSERT INTO agent_registry (agent_id, tier, supervisor_id, display_name, description, domain, machine) VALUES
  ('worker-meet-notes',      'worker', 'intel-supervisor', 'Meeting Notes Worker',  'Processes Gemini Notes emails, fetches Drive transcripts, runs Opus meeting analysis', 'intelligence', 'josh-macbook'),
  ('worker-research-digest', 'worker', 'intel-supervisor', 'Research Digest Worker','Processes research_sources queue, extracts intel, creates tasks', 'intelligence', 'josh-macbook'),
  ('worker-morning-brief',   'worker', 'intel-supervisor', 'Morning Brief Worker',  'Generates daily morning brief at 07:30 SAST', 'intelligence', 'josh-macbook'),
  ('worker-memory-writer',   'worker', 'intel-supervisor', 'Memory Writer Worker',  'Updates user_models and agent_memory from interaction_log', 'intelligence', 'josh-macbook'),
  ('worker-activity-tracker','worker', 'intel-supervisor', 'Activity Tracker Worker','5-minute workspace snapshot, activity-log.jsonl', 'intelligence', 'josh-macbook')
ON CONFLICT (agent_id) DO NOTHING;

-- SALES WORKERS
INSERT INTO agent_registry (agent_id, tier, supervisor_id, display_name, description, domain, machine) VALUES
  ('worker-lead-sourcer',    'worker', 'sales-supervisor', 'Lead Sourcer Worker',   'Apollo.io search, sources new quality leads into Supabase', 'sales', 'josh-macbook'),
  ('worker-lead-enricher',   'worker', 'sales-supervisor', 'Lead Enricher Worker',  'Hunter.io + LinkedIn enrichment, updates lead columns', 'sales', 'josh-macbook'),
  ('worker-outreach-sender', 'worker', 'sales-supervisor', 'Outreach Sender Worker','Sends Alex 3-step email sequences, logs to outreach_log', 'sales', 'josh-macbook'),
  ('worker-reply-detector',  'worker', 'sales-supervisor', 'Reply Detector Worker', 'Monitors alex@amalfiai.com for replies, updates lead status + sentiment', 'sales', 'josh-macbook'),
  ('worker-email-opens',     'worker', 'sales-supervisor', 'Email Opens Worker',    'Polls CF Worker tracking for email opens, updates opened_at in Supabase', 'sales', 'josh-macbook')
ON CONFLICT (agent_id) DO NOTHING;

-- CSM WORKERS
INSERT INTO agent_registry (agent_id, tier, supervisor_id, display_name, description, domain, machine) VALUES
  ('worker-sophia-cron',     'worker', 'csm-supervisor', 'Sophia CSM Worker',     'Sophia automated CSM email touchpoints', 'csm', 'josh-macbook'),
  ('worker-sophia-context',  'worker', 'csm-supervisor', 'Sophia Context Worker', 'Enriches Sophia context before emails', 'csm', 'josh-macbook'),
  ('worker-sophia-followup', 'worker', 'csm-supervisor', 'Sophia Followup Worker','Sophia email followup scheduling', 'csm', 'josh-macbook'),
  ('worker-sophia-outbound', 'worker', 'csm-supervisor', 'Sophia Outbound Worker','Sophia outbound client acquisition emails', 'csm', 'josh-macbook'),
  ('worker-client-monitor',  'worker', 'csm-supervisor', 'Client Monitor Worker', 'Monitors client repos, flags overdue tasks, surfaces blockers', 'csm', 'josh-macbook')
ON CONFLICT (agent_id) DO NOTHING;

-- OPS WORKERS
INSERT INTO agent_registry (agent_id, tier, supervisor_id, display_name, description, domain, machine) VALUES
  ('worker-task-implementer', 'worker', 'ops-supervisor', 'Task Implementer Worker','Claude Code autonomous task worker — picks up tasks, implements, commits', 'ops', 'josh-macbook'),
  ('worker-error-monitor',    'worker', 'ops-supervisor', 'Error Monitor Worker',  'Checks *.err.log files, sends Telegram alerts on errors', 'ops', 'josh-macbook'),
  ('worker-daily-repo-sync',  'worker', 'ops-supervisor', 'Repo Sync Worker',      'Daily git pull on all 4 client repos', 'ops', 'josh-macbook'),
  ('worker-git-backup',       'worker', 'ops-supervisor', 'Git Backup Worker',     'Nightly workspace git backup', 'ops', 'josh-macbook'),
  ('worker-agent-status',     'worker', 'ops-supervisor', 'Agent Status Worker',   'Agent status updater, writes to agent_registry', 'ops', 'josh-macbook')
ON CONFLICT (agent_id) DO NOTHING;

-- FINANCE WORKERS
INSERT INTO agent_registry (agent_id, tier, supervisor_id, display_name, description, domain, machine) VALUES
  ('worker-data-os-sync',    'worker', 'finance-supervisor', 'Data OS Sync Worker',   'Nightly data aggregation → dashboard.json', 'finance', 'josh-macbook'),
  ('worker-monthly-pnl',     'worker', 'finance-supervisor', 'Monthly P&L Worker',    'Monthly P&L report generation', 'finance', 'josh-macbook'),
  ('worker-retainer-tracker','worker', 'finance-supervisor', 'Retainer Tracker Worker','Retainer health monitoring', 'finance', 'josh-macbook'),
  ('worker-aos-value-report', 'worker', 'finance-supervisor', 'AOS Value Report Worker','AOS value delivered report', 'finance', 'josh-macbook')
ON CONFLICT (agent_id) DO NOTHING;

-- COMMS WORKERS
INSERT INTO agent_registry (agent_id, tier, supervisor_id, display_name, description, domain, machine) VALUES
  ('worker-telegram-josh',    'worker', 'comms-supervisor', 'Telegram Josh Worker',   'Josh Telegram gateway — KeepAlive, routes to Claude Sonnet', 'comms', 'josh-macbook'),
  ('worker-telegram-salah',   'worker', 'comms-supervisor', 'Telegram Salah Worker',  'Salah Telegram gateway — KeepAlive', 'comms', 'josh-macbook'),
  ('worker-discord-bot',      'worker', 'comms-supervisor', 'Discord Bot Worker',     'Discord community bot — KeepAlive', 'comms', 'josh-macbook'),
  ('worker-pending-nudge',    'worker', 'comms-supervisor', 'Pending Nudge Worker',   'Daily pending items reminder to Josh/Salah', 'comms', 'josh-macbook'),
  ('worker-telegram-watchdog','worker', 'comms-supervisor', 'Telegram Watchdog Worker','Monitors Telegram poller health, restarts if dead', 'comms', 'josh-macbook')
ON CONFLICT (agent_id) DO NOTHING;
