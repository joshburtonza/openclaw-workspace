-- whatsapp_messages
-- Stores every inbound/outbound WhatsApp exchange Sophia has.
-- One row per exchange: inbound_text is what was received, outbound_text is Sophia's reply.
-- skipped = true when Sophia chose not to respond.

create table if not exists whatsapp_messages (
  id            uuid        default gen_random_uuid() primary key,
  created_at    timestamptz default now(),
  chat_id       text        not null,
  from_number   text,
  sender_name   text,
  is_group      boolean     default false,
  group_name    text,
  client_slug   text,
  inbound_text  text,
  outbound_text text,
  skipped       boolean     default false
);

-- Index for fetching recent history per chat
create index if not exists whatsapp_messages_chat_id_created_at
  on whatsapp_messages (chat_id, created_at desc);

-- Index for per-client queries
create index if not exists whatsapp_messages_client_slug
  on whatsapp_messages (client_slug, created_at desc);

alter table whatsapp_messages enable row level security;
create policy "service_role_all" on whatsapp_messages
  using (true) with check (true);
