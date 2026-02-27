-- ============================================================
-- Migration 003: Multi-tenant config tables
-- Adds vertical_templates, org_gmail_tokens, and extends
-- organizations, candidates, inbound_email_routes.
-- Nicole's existing rows are untouched (backward compatible).
-- ============================================================

-- vertical_templates: one row per industry vertical
CREATE TABLE vertical_templates (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                 text UNIQUE NOT NULL,  -- 'teaching', 'legal', 'tech', 'medical', 'finance', 'generic'
  display_name         text NOT NULL,
  ai_system_prompt     text NOT NULL,         -- full system prompt sent to Claude for this vertical
  ai_extraction_schema text NOT NULL,         -- JSON schema description embedded in the prompt
  gate_rules           jsonb NOT NULL DEFAULT '{}',    -- hard/soft gate rules evaluated post-extraction
  scoring_config       jsonb NOT NULL DEFAULT '{}',    -- weights for scoring (future use)
  created_at           timestamptz DEFAULT now()
);

-- org_gmail_tokens: per-org OAuth tokens for Gmail access
-- When present, edge function uses this instead of the shared env secret
CREATE TABLE org_gmail_tokens (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  gmail_email       text NOT NULL,
  refresh_token     text NOT NULL,
  access_token      text,
  token_expires_at  timestamptz,
  scopes            text[],
  created_at        timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now(),
  UNIQUE(organization_id)
);

-- Extend organizations with vertical + onboarding fields
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS vertical_id       uuid REFERENCES vertical_templates(id);
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS ai_prompt_override text;
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS gate_rules_override jsonb;
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS onboarding_status text
  CHECK (onboarding_status IN ('pending', 'gmail_connected', 'active'))
  DEFAULT 'pending';
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS contact_name  text;
ALTER TABLE organizations ADD COLUMN IF NOT EXISTS contact_email text;

-- Extend candidates with raw extraction data + vertical tag
-- Teaching-specific columns remain untouched for Nicole's dashboard
ALTER TABLE candidates ADD COLUMN IF NOT EXISTS raw_extraction jsonb;  -- full vertical-specific extracted data
ALTER TABLE candidates ADD COLUMN IF NOT EXISTS vertical      text;    -- which vertical processed this candidate

-- Extend inbound_email_routes to optionally point at an org Gmail token
-- NULL means fall back to shared GMAIL_REFRESH_TOKEN env secret (Nicole's existing setup)
ALTER TABLE inbound_email_routes ADD COLUMN IF NOT EXISTS gmail_token_id uuid REFERENCES org_gmail_tokens(id);
