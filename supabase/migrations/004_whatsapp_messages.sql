-- Migration 004: WhatsApp messages table
-- Stores inbound WhatsApp messages received via the whatsapp-webhook Edge Function.
-- The whatsapp-inbound-notifier.sh polls this table and forwards new messages to Telegram.

CREATE TABLE IF NOT EXISTS whatsapp_messages (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id       text        UNIQUE NOT NULL,     -- WhatsApp wamid (dedup key)
  from_number      text        NOT NULL,             -- sender E.164 format: +27831234567
  from_name        text,                             -- display name from WhatsApp profile
  contact_slug     text,                             -- matched slug from contacts.json
  contact_name     text,                             -- matched display name
  message_type     text        NOT NULL DEFAULT 'text',  -- text|image|document|audio|video|sticker|reaction|location
  body             text,                             -- text content (null for media-only)
  media_url        text,                             -- WhatsApp media URL (expires after 5 min)
  media_mime_type  text,
  timestamp_wa     timestamptz NOT NULL,             -- WhatsApp's own timestamp
  received_at      timestamptz DEFAULT now(),
  notified         boolean     NOT NULL DEFAULT false,  -- Telegram notification sent?
  notified_at      timestamptz,
  read_sent        boolean     NOT NULL DEFAULT false,  -- read receipt sent back to WhatsApp?
  reply_sent       text,                             -- outbound reply text (if we replied)
  replied_at       timestamptz,
  phone_number_id  text,                             -- which WA Business number received this
  raw_payload      jsonb                             -- full WhatsApp webhook payload
);

-- Indexes for notifier polling and history views
CREATE INDEX IF NOT EXISTS idx_wamsg_notified
  ON whatsapp_messages (notified, received_at DESC);

CREATE INDEX IF NOT EXISTS idx_wamsg_from
  ON whatsapp_messages (from_number, received_at DESC);

CREATE INDEX IF NOT EXISTS idx_wamsg_contact
  ON whatsapp_messages (contact_slug, received_at DESC);

-- RLS: service role gets full access; anon gets nothing
ALTER TABLE whatsapp_messages ENABLE ROW LEVEL SECURITY;

CREATE POLICY "service_role_all" ON whatsapp_messages
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Comment
COMMENT ON TABLE whatsapp_messages IS
  'Inbound WhatsApp messages received via Cloud API webhook. Written by whatsapp-webhook Edge Function.';
