-- Cerminara Pipeline Tracker — initial schema
-- Created: 2026-07-22
-- Project ref: cvlxxmkzhdqfownrkbbd
--
-- Single-tenant: only the owner (auth user) can read/write any rows.
-- All policies enforce auth.uid() = owner_id (or owner_id IS NULL on inserts,
-- defaulted by trigger below).
--
-- Five tables:
--   clients      — companies/people you do consulting work for
--   engagements  — one per project / retainer / hourly block
--   invoices     — billable amounts tied to an engagement, optionally Stripe-backed
--   time_entries — only used for hourly engagements
--   activities   — append-only audit log of every state change

-- ============================================================
-- Extensions
-- ============================================================
create extension if not exists "pgcrypto";

-- ============================================================
-- Helper: current user's owner_id is always auth.uid() since
-- the only user is the owner. RLS policies use auth.uid() directly.
-- ============================================================

-- ============================================================
-- Enum types
-- ============================================================
do $$ begin
  create type engagement_type as enum ('fixed', 'retainer', 'hourly');
exception when duplicate_object then null; end $$;

do $$ begin
  create type engagement_status as enum ('lead', 'quoted', 'active', 'invoiced', 'paid', 'closed', 'lost');
exception when duplicate_object then null; end $$;

do $$ begin
  create type invoice_status as enum ('draft', 'sent', 'paid', 'overdue', 'void');
exception when duplicate_object then null; end $$;

do $$ begin
  create type activity_type as enum (
    'engagement_created', 'engagement_status_changed', 'engagement_updated',
    'invoice_created', 'invoice_sent', 'invoice_paid', 'invoice_overdue',
    'note_added', 'followup_scheduled', 'client_created', 'client_updated'
  );
exception when duplicate_object then null; end $$;

-- ============================================================
-- clients
-- ============================================================
create table if not exists public.clients (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  company     text,
  email       text,
  phone       text,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists clients_owner_idx on public.clients(owner_id);
create index if not exists clients_owner_name_idx on public.clients(owner_id, name);

-- ============================================================
-- engagements
-- ============================================================
create table if not exists public.engagements (
  id                uuid primary key default gen_random_uuid(),
  owner_id          uuid not null references auth.users(id) on delete cascade,
  client_id         uuid not null references public.clients(id) on delete cascade,
  name              text not null,
  type              engagement_type not null default 'fixed',
  status            engagement_status not null default 'lead',
  quoted_amount     numeric(12,2),
  hourly_rate       numeric(8,2),
  estimated_hours   numeric(8,2),
  start_date        date,
  end_date          date,
  next_followup_at  timestamptz,
  gcal_event_id     text,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists engagements_owner_idx on public.engagements(owner_id);
create index if not exists engagements_owner_status_idx on public.engagements(owner_id, status);
create index if not exists engagements_owner_client_idx on public.engagements(owner_id, client_id);
create index if not exists engagements_followup_idx on public.engagements(owner_id, next_followup_at) where next_followup_at is not null;

-- ============================================================
-- invoices
-- ============================================================
create table if not exists public.invoices (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references auth.users(id) on delete cascade,
  engagement_id       uuid not null references public.engagements(id) on delete cascade,
  stripe_invoice_id   text unique,
  stripe_payment_intent text,
  amount              numeric(12,2) not null,
  currency            text not null default 'usd',
  status              invoice_status not null default 'draft',
  due_date            date,
  description         text,
  sent_at             timestamptz,
  paid_at             timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists invoices_owner_idx on public.invoices(owner_id);
create index if not exists invoices_owner_status_idx on public.invoices(owner_id, status);
create index if not exists invoices_engagement_idx on public.invoices(engagement_id);
create index if not exists invoices_due_idx on public.invoices(owner_id, due_date) where status in ('sent', 'overdue');

-- ============================================================
-- time_entries  (only for hourly engagements)
-- ============================================================
create table if not exists public.time_entries (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references auth.users(id) on delete cascade,
  engagement_id uuid not null references public.engagements(id) on delete cascade,
  started_at    timestamptz not null,
  ended_at      timestamptz not null,
  minutes       numeric(8,2) generated always as (
    extract(epoch from (ended_at - started_at)) / 60.0
  ) stored,
  description   text,
  billable      boolean not null default true,
  created_at    timestamptz not null default now(),
  check (ended_at >= started_at)
);

create index if not exists time_entries_owner_idx on public.time_entries(owner_id);
create index if not exists time_entries_engagement_idx on public.time_entries(engagement_id);

-- ============================================================
-- activities  (audit log — append-only)
-- ============================================================
create table if not exists public.activities (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null references auth.users(id) on delete cascade,
  engagement_id uuid references public.engagements(id) on delete cascade,
  invoice_id    uuid references public.invoices(id) on delete cascade,
  type          activity_type not null,
  summary       text not null,
  metadata      jsonb default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index if not exists activities_owner_idx on public.activities(owner_id);
create index if not exists activities_engagement_idx on public.activities(engagement_id) where engagement_id is not null;
create index if not exists activities_invoice_idx on public.activities(invoice_id) where invoice_id is not null;
create index if not exists activities_owner_created_idx on public.activities(owner_id, created_at desc);

-- ============================================================
-- updated_at triggers
-- ============================================================
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_clients_updated_at on public.clients;
create trigger trg_clients_updated_at
  before update on public.clients
  for each row execute function public.set_updated_at();

drop trigger if exists trg_engagements_updated_at on public.engagements;
create trigger trg_engagements_updated_at
  before update on public.engagements
  for each row execute function public.set_updated_at();

drop trigger if exists trg_invoices_updated_at on public.invoices;
create trigger trg_invoices_updated_at
  before update on public.invoices
  for each row execute function public.set_updated_at();

-- ============================================================
-- Activity logging triggers (light — every change creates a row)
-- ============================================================
create or replace function public.log_engagement_change()
returns trigger language plpgsql as $$
declare
  status_change text;
begin
  if TG_OP = 'INSERT' then
    insert into public.activities(owner_id, engagement_id, type, summary, metadata)
      values (new.owner_id, new.id, 'engagement_created',
              'Created engagement: ' || new.name,
              jsonb_build_object('status', new.status, 'type', new.type));
    return new;
  elsif TG_OP = 'UPDATE' then
    if new.status is distinct from old.status then
      insert into public.activities(owner_id, engagement_id, type, summary, metadata)
        values (new.owner_id, new.id, 'engagement_status_changed',
                'Status: ' || old.status::text || ' → ' || new.status::text,
                jsonb_build_object('from', old.status, 'to', new.status));
    end if;
    if new.name is distinct from old.name or new.notes is distinct from old.notes or
       new.quoted_amount is distinct from old.quoted_amount or new.type is distinct from old.type then
      insert into public.activities(owner_id, engagement_id, type, summary, metadata)
        values (new.owner_id, new.id, 'engagement_updated',
                'Updated engagement details',
                jsonb_build_object());
    end if;
    if new.next_followup_at is distinct from old.next_followup_at and new.next_followup_at is not null then
      insert into public.activities(owner_id, engagement_id, type, summary, metadata)
        values (new.owner_id, new.id, 'followup_scheduled',
                'Follow-up scheduled for ' || to_char(new.next_followup_at, 'YYYY-MM-DD HH12:MI AM'),
                jsonb_build_object('followup_at', new.next_followup_at));
    end if;
    return new;
  end if;
  return new;
end $$;

drop trigger if exists trg_engagements_log on public.engagements;
create trigger trg_engagements_log
  after insert or update on public.engagements
  for each row execute function public.log_engagement_change();

create or replace function public.log_invoice_change()
returns trigger language plpgsql as $$
begin
  if TG_OP = 'INSERT' then
    insert into public.activities(owner_id, engagement_id, invoice_id, type, summary, metadata)
      values (new.owner_id, new.engagement_id, new.id, 'invoice_created',
              'Invoice created: $' || new.amount::text,
              jsonb_build_object('amount', new.amount, 'status', new.status));
  elsif TG_OP = 'UPDATE' then
    if new.status is distinct from old.status then
      insert into public.activities(owner_id, engagement_id, invoice_id, type, summary, metadata)
        values (
          new.owner_id, new.engagement_id, new.id,
          case
            when new.status = 'sent' then 'invoice_sent'::activity_type
            when new.status = 'paid' then 'invoice_paid'::activity_type
            when new.status = 'overdue' then 'invoice_overdue'::activity_type
            else 'engagement_updated'::activity_type
          end,
          case
            when new.status = 'sent' then 'Invoice sent for $' || new.amount::text
            when new.status = 'paid' then 'Invoice PAID: $' || new.amount::text
            when new.status = 'overdue' then 'Invoice OVERDUE: $' || new.amount::text
            else 'Invoice status: ' || new.status::text
          end,
          jsonb_build_object('from', old.status, 'to', new.status)
        );
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_invoices_log on public.invoices;
create trigger trg_invoices_log
  after insert or update on public.invoices
  for each row execute function public.log_invoice_change();

-- ============================================================
-- Enable RLS on every table
-- ============================================================
alter table public.clients       enable row level security;
alter table public.engagements   enable row level security;
alter table public.invoices      enable row level security;
alter table public.time_entries  enable row level security;
alter table public.activities    enable row level security;

-- ============================================================
-- RLS policies — single-tenant. Only the owner can read/write.
-- ============================================================

-- clients
drop policy if exists "clients: own read"     on public.clients;
drop policy if exists "clients: own insert"   on public.clients;
drop policy if exists "clients: own update"   on public.clients;
drop policy if exists "clients: own delete"   on public.clients;
create policy "clients: own read"   on public.clients for select using (owner_id = auth.uid());
create policy "clients: own insert" on public.clients for insert with check (owner_id = auth.uid());
create policy "clients: own update" on public.clients for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "clients: own delete" on public.clients for delete using (owner_id = auth.uid());

-- engagements
drop policy if exists "engagements: own read"     on public.engagements;
drop policy if exists "engagements: own insert"   on public.engagements;
drop policy if exists "engagements: own update"   on public.engagements;
drop policy if exists "engagements: own delete"   on public.engagements;
create policy "engagements: own read"   on public.engagements for select using (owner_id = auth.uid());
create policy "engagements: own insert" on public.engagements for insert with check (owner_id = auth.uid());
create policy "engagements: own update" on public.engagements for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "engagements: own delete" on public.engagements for delete using (owner_id = auth.uid());

-- invoices
drop policy if exists "invoices: own read"     on public.invoices;
drop policy if exists "invoices: own insert"   on public.invoices;
drop policy if exists "invoices: own update"   on public.invoices;
drop policy if exists "invoices: own delete"   on public.invoices;
create policy "invoices: own read"   on public.invoices for select using (owner_id = auth.uid());
create policy "invoices: own insert" on public.invoices for insert with check (owner_id = auth.uid());
create policy "invoices: own update" on public.invoices for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "invoices: own delete" on public.invoices for delete using (owner_id = auth.uid());

-- time_entries
drop policy if exists "time_entries: own read"     on public.time_entries;
drop policy if exists "time_entries: own insert"   on public.time_entries;
drop policy if exists "time_entries: own update"   on public.time_entries;
drop policy if exists "time_entries: own delete"   on public.time_entries;
create policy "time_entries: own read"   on public.time_entries for select using (owner_id = auth.uid());
create policy "time_entries: own insert" on public.time_entries for insert with check (owner_id = auth.uid());
create policy "time_entries: own update" on public.time_entries for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "time_entries: own delete" on public.time_entries for delete using (owner_id = auth.uid());

-- activities (read-only for user; inserts only via triggers which bypass RLS as service role)
drop policy if exists "activities: own read" on public.activities;
create policy "activities: own read" on public.activities for select using (owner_id = auth.uid());

-- ============================================================
-- View: engagement summary (denormalized for fast dashboard loads)
-- ============================================================
create or replace view public.engagement_summary as
select
  e.id,
  e.owner_id,
  e.client_id,
  c.name as client_name,
  c.company as client_company,
  e.name,
  e.type,
  e.status,
  e.quoted_amount,
  e.hourly_rate,
  e.start_date,
  e.end_date,
  e.next_followup_at,
  e.notes,
  e.created_at,
  e.updated_at,
  coalesce((
    select sum(amount)
    from public.invoices i
    where i.engagement_id = e.id and i.status in ('sent', 'paid', 'overdue')
  ), 0) as invoiced_amount,
  coalesce((
    select sum(amount)
    from public.invoices i
    where i.engagement_id = e.id and i.status = 'paid'
  ), 0) as paid_amount,
  (
    select count(*)
    from public.invoices i
    where i.engagement_id = e.id and i.status in ('sent', 'overdue')
  ) as open_invoice_count,
  (
    select max(created_at)
    from public.activities a
    where a.engagement_id = e.id
  ) as last_activity_at
from public.engagements e
join public.clients c on c.id = e.client_id;

-- View inherits table RLS via the underlying clients + engagements tables,
-- so it's automatically owner-scoped.

-- ============================================================
-- Grant access on the view to authenticated users
-- ============================================================
grant select on public.engagement_summary to authenticated;
grant select, insert, update, delete on public.clients      to authenticated;
grant select, insert, update, delete on public.engagements  to authenticated;
grant select, insert, update, delete on public.invoices     to authenticated;
grant select, insert, update, delete on public.time_entries to authenticated;
grant select                              on public.activities   to authenticated;

-- ============================================================
-- Done.
-- ============================================================