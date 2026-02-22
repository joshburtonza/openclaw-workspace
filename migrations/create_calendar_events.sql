-- calendar_events table: stores upcoming Google Calendar events synced every 30min
CREATE TABLE IF NOT EXISTS calendar_events (
  id           TEXT PRIMARY KEY,         -- Google Calendar event ID
  title        TEXT NOT NULL,
  description  TEXT,
  start_at     TIMESTAMPTZ NOT NULL,
  end_at       TIMESTAMPTZ,
  all_day      BOOLEAN DEFAULT false,
  calendar_id  TEXT,
  calendar_name TEXT,
  location     TEXT,
  attendees    JSONB DEFAULT '[]',
  status       TEXT DEFAULT 'confirmed', -- confirmed | tentative | cancelled
  meet_link    TEXT,
  updated_at   TIMESTAMPTZ DEFAULT now(),
  synced_at    TIMESTAMPTZ DEFAULT now()
);

-- Index for upcoming events query
CREATE INDEX IF NOT EXISTS idx_calendar_events_start ON calendar_events(start_at);

-- RLS: allow service role full access, anon read
ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY "service_role_all" ON calendar_events FOR ALL USING (true);
CREATE POLICY "anon_read" ON calendar_events FOR SELECT USING (true);
