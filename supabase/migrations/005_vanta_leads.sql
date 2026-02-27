-- Migration 005: Vanta Studios lead pipeline
-- Stores discovered, verified, and outreached photographer leads.

CREATE TABLE IF NOT EXISTS vanta_leads (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identity
  instagram_handle    text        UNIQUE,
  full_name           text,
  business_name       text,

  -- Contact
  email               text,
  phone               text,
  website             text,

  -- Location
  location_raw        text,                        -- as extracted
  location_city       text,                        -- normalized (Cape Town, Johannesburg, etc.)
  in_south_africa     boolean     DEFAULT false,

  -- Instagram metrics
  follower_count      int,
  following_count     int,
  post_count          int,
  avg_likes           float,
  avg_comments        float,
  engagement_rate     float,
  last_post_at        timestamptz,
  bio_text            text,
  profile_url         text,
  is_business_account boolean     DEFAULT false,

  -- Photography specialty (extracted from bio / posts)
  specialties         text[],     -- ['wedding','portrait','commercial','lifestyle','product']

  -- Verification
  email_verified      boolean     DEFAULT false,
  email_deliverable   boolean,    -- SMTP probe result
  email_domain_type   text,       -- 'business'|'personal'|'unknown'
  website_live        boolean,
  instagram_active    boolean,    -- post in last 30 days

  -- Quality scoring
  quality_score       int         NOT NULL DEFAULT 0,  -- 0-100
  quality_breakdown   jsonb,                           -- {email:30, active:20, ...}
  quality_scored_at   timestamptz,

  -- Outreach tracking
  outreach_status     text        NOT NULL DEFAULT 'new'
                      CHECK (outreach_status IN ('new','queued','emailed','dmed','ig_commented','responded','converted','rejected','unsubscribed')),
  last_contacted_at   timestamptz,
  last_reply_at       timestamptz,
  outreach_notes      text,
  email_queue_id      uuid,      -- FK to email_queue if email sent via Sophia

  -- Instagram engagement tracking
  ig_comment_sent_at  timestamptz,
  ig_dm_sent_at       timestamptz,
  ig_dm_text          text,

  -- Metadata
  source              text,       -- 'instagram_hashtag'|'google_maps'|'directory'|'manual'
  source_hashtag      text,
  discovered_at       timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now()
);

-- Indexes for pipeline processing
CREATE INDEX IF NOT EXISTS idx_vanta_leads_status
  ON vanta_leads (outreach_status, quality_score DESC);

CREATE INDEX IF NOT EXISTS idx_vanta_leads_email
  ON vanta_leads (email) WHERE email IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_vanta_leads_ig
  ON vanta_leads (instagram_handle) WHERE instagram_handle IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_vanta_leads_quality
  ON vanta_leads (quality_score DESC, discovered_at DESC);

-- RLS
ALTER TABLE vanta_leads ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role_all" ON vanta_leads
  FOR ALL TO service_role USING (true) WITH CHECK (true);

COMMENT ON TABLE vanta_leads IS
  'Vanta Studios B2B photographer leads — discovered, verified and quality-scored before outreach.';
