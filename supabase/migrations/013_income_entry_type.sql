-- Add entry_type to income_entries to distinguish recurring vs once-off payments
-- Once-off entries (setup fees, project fees) are excluded from MRR calculation

ALTER TABLE income_entries
  ADD COLUMN IF NOT EXISTS entry_type TEXT NOT NULL DEFAULT 'recurring'
  CHECK (entry_type IN ('recurring', 'one_off'));

-- Mark Vanta Studios setup fee as one-off
UPDATE income_entries
  SET entry_type = 'one_off'
  WHERE client = 'Vanta Studios' AND project ILIKE '%setup%';

-- Index for quick filtering
CREATE INDEX IF NOT EXISTS income_entries_entry_type_idx ON income_entries(entry_type);
