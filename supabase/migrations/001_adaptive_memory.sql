-- ============================================================
-- Amalfi OS: Adaptive Memory Layer
-- Run in Supabase SQL Editor
-- ============================================================

-- 1. Living model of each person the system touches
CREATE TABLE IF NOT EXISTS user_models (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           text NOT NULL UNIQUE,
  user_type         text NOT NULL CHECK (user_type IN ('owner', 'client', 'lead')),
  communication     jsonb NOT NULL DEFAULT '{}',   -- tone, length, formality, preferred_channel
  decision_patterns jsonb NOT NULL DEFAULT '{}',   -- approval rate, response speed, what triggers rejection
  goals             jsonb NOT NULL DEFAULT '{}',   -- current priorities, blockers, milestones
  relationship      jsonb NOT NULL DEFAULT '{}',   -- trust_level, sentiment_history, last_contact, days_since_contact
  preferences       jsonb NOT NULL DEFAULT '{}',   -- timing, topics, format, channels
  flags             jsonb NOT NULL DEFAULT '{}',   -- at_risk, hot, stalling, champion, do_not_contact
  raw_observations  text[] NOT NULL DEFAULT '{}',  -- timestamped free-text from memory-writer
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- 2. Every human signal logged here for the memory-writer to process
CREATE TABLE IF NOT EXISTS interaction_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  timestamp   timestamptz NOT NULL DEFAULT now(),
  actor       text NOT NULL,         -- 'josh' | 'sophia' | 'alex' | 'system'
  user_id     text NOT NULL,         -- who this is about
  signal_type text NOT NULL,         -- see signal taxonomy below
  signal_data jsonb NOT NULL DEFAULT '{}',  -- raw context (email_id, subject, draft excerpt, etc)
  notes       text,                  -- free-text inference added by memory-writer
  processed   boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS interaction_log_unprocessed ON interaction_log (processed, timestamp)
  WHERE processed = false;
CREATE INDEX IF NOT EXISTS interaction_log_user ON interaction_log (user_id, timestamp DESC);

-- 3. Per-agent learned context — each agent has its own lens on users
CREATE TABLE IF NOT EXISTS agent_memory (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent         text NOT NULL,          -- 'sophia' | 'alex' | 'coach' | 'conductor' | 'intel'
  scope         text NOT NULL,          -- 'global' | user_id | client_slug
  memory_type   text NOT NULL,          -- 'style_learned' | 'pattern' | 'rule' | 'observation' | 'preference'
  content       text NOT NULL,          -- the learned fact / rule / observation
  confidence    float NOT NULL DEFAULT 0.5 CHECK (confidence >= 0 AND confidence <= 1),
  reinforced_at timestamptz NOT NULL DEFAULT now(),
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS agent_memory_lookup ON agent_memory (agent, scope, memory_type);

-- ── Signal taxonomy (reference — enforced in application, not DB) ─────────────
-- email_approved      Josh approved a Sophia/Alex draft
-- email_rejected      Josh rejected a draft
-- email_adjusted      Josh requested changes
-- email_held          Josh put on hold (awaiting_approval)
-- email_sent          Email actually delivered
-- reply_received      Client/lead replied to an outbound email
-- reply_positive      Reply classified positive
-- reply_interested    Reply shows buying intent
-- reply_objection     Reply is an objection
-- reminder_done       Josh marked a reminder done
-- reminder_snoozed    Josh snoozed a reminder
-- reminder_dismissed  System auto-dismissed a stale reminder
-- task_completed      A task was completed (by Claude or Josh)
-- task_created        New task queued
-- meeting_analysed    Meeting notes processed → debrief sent
-- payment_received    Client paid
-- payment_missed      Invoice overdue, not paid
-- client_silence      No contact for >N days
-- brief_sent          Morning brief delivered

-- ── Seed: Josh's starting user model ────────────────────────────────────────
INSERT INTO user_models (user_id, user_type, communication, goals, preferences, relationship)
VALUES (
  'josh',
  'owner',
  '{"style": "direct", "length": "concise", "formality": "casual-professional", "preferred_channel": "telegram"}',
  '{"primary": "grow Amalfi AI MRR", "current_mrr": 0, "target_mrr": 50000, "clients": ["ascend_lc", "favorite_logistics", "race_technik"]}',
  '{"timezone": "SAST", "active_hours": "08:00-18:00", "brief_time": "07:30"}',
  '{"trust_level": "owner", "engagement": "high"}'
)
ON CONFLICT (user_id) DO NOTHING;

-- ── Seed: starting agent memories ────────────────────────────────────────────
INSERT INTO agent_memory (agent, scope, memory_type, content, confidence) VALUES
('sophia', 'global', 'rule',        'Never use hyphens in any written output',                          1.0),
('sophia', 'global', 'rule',        'Always draft first, show to Josh, wait for explicit send approval', 1.0),
('sophia', 'global', 'rule',        'All outbound emails from sophia@amalfiai.com, HTML only',          1.0),
('alex',   'global', 'rule',        'Outbound emails from alex@amalfiai.com via gog',                  1.0),
('alex',   'global', 'preference',  'GPT-4o for email generation — warmth and quality matter',          1.0),
('conductor', 'global', 'rule',     'Strategic decisions → Claude Opus 4.6',                            1.0),
('conductor', 'global', 'rule',     'Client-facing output → GPT-4o',                                    1.0),
('conductor', 'global', 'rule',     'Memory updates → Claude Haiku (cheap + fast)',                     1.0)
ON CONFLICT DO NOTHING;
