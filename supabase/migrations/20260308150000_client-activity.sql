-- client_activity: cross-client usage events written by each client app
-- Used by sophia-client-monitor.sh to generate proactive WhatsApp nudges

create table if not exists client_activity (
  id          bigserial primary key,
  client_slug text not null,                -- e.g. 'ascend-lc', 'race-technik'
  event_type  text not null,                -- e.g. 'nc_created', 'nc_closed', 'booking_created', 'login'
  user_email  text,
  user_name   text,
  metadata    jsonb default '{}',
  created_at  timestamptz default now()
);

create index if not exists client_activity_slug_idx on client_activity(client_slug, created_at desc);

-- RLS: only service role can write/read
alter table client_activity enable row level security;

create policy "service_role_only" on client_activity
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

-- Track last-alerted per client so we don't spam
create table if not exists client_activity_alerts (
  client_slug text primary key,
  last_alerted_at timestamptz,
  last_event_count int default 0
);
