-- ─────────────────────────────────────────────────────────────────────────────
-- 008_crm_ai_analysis.sql
-- Adds AI analysis columns to leads table for AOS lead scoring.
-- Stores structured Claude analysis: fit score, headline, opportunities, risks.
--
-- Run in: Supabase Dashboard → SQL Editor
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE leads
  ADD COLUMN IF NOT EXISTS ai_analysis    JSONB,
  ADD COLUMN IF NOT EXISTS ai_score       INTEGER,
  ADD COLUMN IF NOT EXISTS ai_analysed_at TIMESTAMPTZ;

-- Index for sorting by AI score
CREATE INDEX IF NOT EXISTS leads_ai_score_idx
  ON leads(ai_score DESC NULLS LAST);
