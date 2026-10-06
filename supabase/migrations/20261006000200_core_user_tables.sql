-- =============================================================================
-- Zuno 0200: platform settings, reference data and per-user tables
-- Money is always bigint minor units (LKR cents). No floating point for money.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- platform_settings (contract section 1) - read-only to clients
-- ---------------------------------------------------------------------------
create table public.platform_settings (
  key text primary key,
  value bigint not null,
  description text not null default '',
  updated_at timestamptz not null default now(),
  constraint platform_settings_known_key check (key in (
    'free_allowance_per_month',
    'extra_free_registration_fee_minor',
    'commission_bps',
    'event_creation_fee_minor',
    'wallet_topup_min_minor',
    'wallet_topup_max_minor',
    'order_hold_minutes'
  )),
  constraint platform_settings_non_negative check (value >= 0),
  -- LKR 2.50 - 3.00 per extra free registration (contract section 1).
  constraint platform_settings_extra_fee_range check (key <> 'extra_free_registration_fee_minor' or value between 250 and 300),
  constraint platform_settings_commission_range check (key <> 'commission_bps' or value between 0 and 10000),
  constraint platform_settings_allowance_range check (key <> 'free_allowance_per_month' or value between 0 and 1000),
  constraint platform_settings_hold_range check (key <> 'order_hold_minutes' or value between 1 and 1440),
  constraint platform_settings_topup_positive check (key not in ('wallet_topup_min_minor', 'wallet_topup_max_minor') or value > 0)
);

comment on table public.platform_settings is 'Contract section 1. Read-only to clients; changed by operators only.';

insert into public.platform_settings (key, value, description) values
  ('free_allowance_per_month', 15, 'Free-event registrations included per user per calendar month (Asia/Colombo).'),
  ('extra_free_registration_fee_minor', 250, 'Wallet deduction per free registration beyond the allowance (250-300).'),
  ('commission_bps', 500, 'Platform commission on paid tickets in basis points, deducted from organizer settlement.'),
  ('event_creation_fee_minor', 100000, 'Organizer fee per published event (LKR 1,000.00).'),
  ('wallet_topup_min_minor', 10000, 'Minimum wallet top-up.'),
  ('wallet_topup_max_minor', 5000000, 'Maximum wallet top-up.'),
  ('order_hold_minutes', 15, 'Inventory reservation lifetime for pending ticket orders.')
on conflict (key) do nothing;

create trigger platform_settings_set_updated_at
  before update on public.platform_settings
  for each row execute function private.set_updated_at();

-- Typed accessor used by definer functions.
create or replace function private.setting(p_key text)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select value from public.platform_settings where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- categories (public read). Canonical slugs are part of the contract, so they
-- are inserted by the migration (the seed re-upserts the same rows).
-- ---------------------------------------------------------------------------
create table public.categories (
  id text primary key check (id ~ '^[a-z][a-z0-9_-]{1,40}$'),
  name text not null check (char_length(name) between 1 and 60),
  symbol_name text not null check (char_length(symbol_name) between 1 and 80),
  sort_order integer not null default 0
);

insert into public.categories (id, name, symbol_name, sort_order) values
  ('hackathons', 'Hackathons', 'laptopcomputer', 1),
  ('technology', 'Technology', 'cpu', 2),
  ('workshops', 'Workshops', 'hammer', 3),
  ('university', 'University', 'graduationcap', 4),
  ('art', 'Art', 'photo.artframe', 5),
  ('music', 'Music', 'music.note', 6),
  ('sports', 'Sports', 'figure.run', 7),
  ('culture', 'Culture', 'building.columns', 8),
  ('careers', 'Careers', 'briefcase', 9),
  ('community', 'Community', 'person.3', 10)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- profiles (own row: select / insert / update of editable columns only)
-- identity_status is server-owned (set only by record_identity_digest()).
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text check (display_name is null or char_length(display_name) between 1 and 80),
  avatar_path text check (avatar_path is null or char_length(avatar_path) between 3 and 300),
  city text check (city is null or char_length(city) <= 80),
  district text check (district is null or char_length(district) <= 80),
  preferred_categories text[] not null default '{}' check (cardinality(preferred_categories) <= 10),
  language text not null default 'en' check (language in ('en', 'si', 'ta')),
  accessibility_needs text[] not null default '{}' check (
    accessibility_needs <@ array['wheelchair_access', 'sign_language', 'quiet_space', 'large_print', 'assisted_entry']::text[]
  ),
  phone text check (phone is null or phone ~ '^\+?[0-9]{9,15}$'),
  identity_status text not null default 'none' check (identity_status in ('none', 'verified_unique', 'duplicate')),
  onboarding_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

-- avatar_path must live under the user's own folder; preferred categories must exist.
create or replace function private.profiles_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.avatar_path is not null and new.avatar_path not like new.id::text || '/%' then
    perform private.fail('invalid_avatar_path');
  end if;
  if exists (
    select 1 from unnest(new.preferred_categories) as c(id)
    where not exists (select 1 from public.categories cat where cat.id = c.id)
  ) then
    perform private.fail('invalid_category');
  end if;
  return new;
end;
$$;

create trigger profiles_validate
  before insert or update on public.profiles
  for each row execute function private.profiles_validate();

-- ---------------------------------------------------------------------------
-- user_identities: server-maintained mirror of auth.identities (own rows: select)
-- ---------------------------------------------------------------------------
create table public.user_identities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  identity_id text not null,
  provider text not null,
  linked_at timestamptz not null default now(),
  unlinked_at timestamptz
);
create index user_identities_user_idx on public.user_identities (user_id);
create unique index user_identities_active_identity on public.user_identities (identity_id) where unlinked_at is null;

-- ---------------------------------------------------------------------------
-- identity_digests: HMAC-SHA-256 of the canonical NIC. NO client access at all
-- (not even service_role table grants): only record_identity_digest() writes it.
-- ---------------------------------------------------------------------------
create table public.identity_digests (
  user_id uuid primary key references auth.users (id) on delete cascade,
  digest text not null unique check (digest ~ '^[0-9a-f]{64}$'),
  key_version integer not null check (key_version > 0),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- wallets + append-only ledger
-- The balance can only change as a side effect of posting a ledger entry
-- (see private.wallet_ledger_apply in 20261006000500).
-- ---------------------------------------------------------------------------
create table public.wallets (
  user_id uuid primary key references auth.users (id) on delete cascade,
  balance_minor bigint not null default 0 check (balance_minor >= 0),
  currency text not null default 'LKR' check (currency = 'LKR'),
  updated_at timestamptz not null default now()
);

create table public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  -- Nullable only so a deleted account's financial history can be anonymised.
  user_id uuid references auth.users (id) on delete set null,
  entry_type text not null check (entry_type in ('topup', 'free_registration_fee', 'refund_credit', 'ticket_purchase', 'adjustment')),
  amount_minor bigint not null check (amount_minor <> 0),
  balance_after_minor bigint check (balance_after_minor is null or balance_after_minor >= 0),
  status text not null default 'posted' check (status in ('pending', 'posted', 'failed')),
  reference_type text not null check (reference_type in ('registration', 'order', 'event', 'seed', 'manual')),
  reference_id uuid,
  description text not null default '' check (char_length(description) <= 300),
  created_at timestamptz not null default now(),
  posted_at timestamptz,
  constraint wallet_ledger_balance_after_iff_posted check ((status = 'posted') = (balance_after_minor is not null)),
  constraint wallet_ledger_sign check (
    (entry_type in ('topup', 'refund_credit') and amount_minor > 0)
    or (entry_type in ('free_registration_fee', 'ticket_purchase') and amount_minor < 0)
    or entry_type = 'adjustment'
  )
);
create index wallet_ledger_user_created_idx on public.wallet_ledger (user_id, created_at desc);
create index wallet_ledger_reference_idx on public.wallet_ledger (reference_type, reference_id);
create index wallet_ledger_pending_idx on public.wallet_ledger (reference_id) where status = 'pending';

-- Monthly free-registration allowance counter (Asia/Colombo calendar month).
-- Kept separate from registrations so usage survives cancellations and can be
-- seeded; registrations.used_allowance/allowance_month record which ones used it.
create table public.allowance_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  month date not null check (extract(day from month) = 1),
  used integer not null default 0 check (used >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, month)
);

create trigger allowance_usage_set_updated_at
  before update on public.allowance_usage
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- notification_preferences (own row: select / update)
-- ---------------------------------------------------------------------------
create table public.notification_preferences (
  user_id uuid primary key references auth.users (id) on delete cascade,
  event_reminders boolean not null default true,
  payment_updates boolean not null default true,
  event_changes boolean not null default true,
  waitlist_updates boolean not null default true,
  organizer_news boolean not null default true,
  push_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

create trigger notification_preferences_set_updated_at
  before update on public.notification_preferences
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- push_devices (own rows: select / insert / delete)
-- ---------------------------------------------------------------------------
create table public.push_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  apns_token text not null unique check (apns_token ~ '^[0-9A-Fa-f]{32,200}$'),
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index push_devices_user_idx on public.push_devices (user_id);

create trigger push_devices_set_updated_at
  before update on public.push_devices
  for each row execute function private.set_updated_at();

-- ---------------------------------------------------------------------------
-- rate_limits: fixed-window counters (server only)
-- ---------------------------------------------------------------------------
create table public.rate_limits (
  key text not null check (char_length(key) between 1 and 200),
  window_start timestamptz not null,
  count integer not null default 0 check (count >= 0),
  primary key (key, window_start)
);
create index rate_limits_window_idx on public.rate_limits (window_start);

-- ---------------------------------------------------------------------------
-- audit_events: append-only security/financial audit trail (server only)
-- ---------------------------------------------------------------------------
create table public.audit_events (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users (id) on delete set null,
  action text not null check (char_length(action) between 1 and 80),
  entity_type text not null check (char_length(entity_type) between 1 and 60),
  entity_id uuid,
  event_id uuid,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_events_entity_idx on public.audit_events (entity_type, entity_id);
create index audit_events_event_idx on public.audit_events (event_id, created_at desc);
create index audit_events_actor_idx on public.audit_events (actor_id, created_at desc);

create or replace function private.audit(
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_event_id uuid default null,
  p_data jsonb default '{}'::jsonb,
  p_actor uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.audit_events (actor_id, action, entity_type, entity_id, event_id, data)
  values (coalesce(p_actor, auth.uid()), p_action, p_entity_type, p_entity_id, p_event_id, coalesce(p_data, '{}'::jsonb));
end;
$$;
