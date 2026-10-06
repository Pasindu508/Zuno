-- =============================================================================
-- Zuno 0300: organizers, venues, events and event-owned content
-- Server-owned columns are protected by column-level grants (20261006000600):
-- clients can never write status, seats_taken, sold, reserved,
-- verification_status, creation_fee_paid_at, published_at or timestamps.
-- =============================================================================

create table public.organizer_profiles (
  id uuid primary key default gen_random_uuid(),
  -- Nullable only so an organizer profile survives its owner's account deletion.
  owner_id uuid unique default auth.uid() references auth.users (id) on delete set null,
  name text not null check (char_length(btrim(name)) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) between 3 and 60),
  bio text not null default '' check (char_length(bio) <= 2000),
  logo_path text check (logo_path is null or char_length(logo_path) between 3 and 300),
  contact_email text check (contact_email is null or contact_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  verification_status text not null default 'pending' check (verification_status in ('pending', 'verified', 'rejected', 'suspended')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger organizer_profiles_set_updated_at
  before update on public.organizer_profiles
  for each row execute function private.set_updated_at();

create table public.venues (
  id uuid primary key default gen_random_uuid(),
  organizer_id uuid not null references public.organizer_profiles (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  address_line text not null default '' check (char_length(address_line) <= 300),
  city text not null check (char_length(btrim(city)) between 1 and 80),
  district text not null check (char_length(btrim(district)) between 1 and 80),
  latitude double precision check (latitude between -90 and 90),
  longitude double precision check (longitude between -180 and 180),
  created_at timestamptz not null default now(),
  constraint venues_coordinates_pair check ((latitude is null) = (longitude is null))
);
create index venues_organizer_idx on public.venues (organizer_id);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  organizer_id uuid not null references public.organizer_profiles (id) on delete restrict,
  category_id text not null references public.categories (id),
  venue_id uuid references public.venues (id) on delete restrict,
  title text not null default '' check (char_length(title) <= 120),
  summary text not null default '' check (char_length(summary) <= 280),
  description text not null default '' check (char_length(description) <= 10000),
  format text not null default 'physical' check (format in ('physical', 'online', 'hybrid')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  timezone text not null default 'Asia/Colombo' check (timezone = 'Asia/Colombo'),
  capacity integer not null default 0 check (capacity between 0 and 100000),
  is_free boolean not null default true,
  university text check (university is null or char_length(university) <= 120),
  tags text[] not null default '{}' check (cardinality(tags) <= 15),
  cover_path text check (cover_path is null or char_length(cover_path) between 3 and 300),
  cover_alt text check (cover_alt is null or char_length(cover_alt) <= 300),
  agenda jsonb not null default '[]'::jsonb check (jsonb_typeof(agenda) = 'array' and jsonb_array_length(agenda) <= 100),
  speakers jsonb not null default '[]'::jsonb check (jsonb_typeof(speakers) = 'array' and jsonb_array_length(speakers) <= 50),
  refund_policy text not null default '' check (char_length(refund_policy) <= 2000),
  registration_opens_at timestamptz,
  registration_closes_at timestamptz,
  online_url text check (online_url is null or (online_url ~ '^https://[^[:space:]]+$' and char_length(online_url) <= 500)),
  -- server-owned
  status text not null default 'draft' check (status in ('draft', 'pending_review', 'published', 'cancelled', 'completed')),
  seats_taken integer not null default 0 check (seats_taken >= 0),
  creation_fee_paid_at timestamptz,
  published_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text check (cancellation_reason is null or char_length(cancellation_reason) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- search support (maintained by private.events_refresh_search)
  search_document text not null default '',
  search_vector tsvector,
  constraint events_time_order check (ends_at > starts_at),
  constraint events_registration_window check (
    registration_opens_at is null or registration_closes_at is null or registration_closes_at > registration_opens_at
  ),
  constraint events_seats_within_capacity check (seats_taken <= capacity)
);
create index events_status_starts_idx on public.events (status, starts_at);
create index events_organizer_idx on public.events (organizer_id);
create index events_category_idx on public.events (category_id);
create index events_venue_idx on public.events (venue_id);
create index events_tags_idx on public.events using gin (tags);
create index events_search_vector_idx on public.events using gin (search_vector);
create index events_search_trgm_idx on public.events using gin (search_document extensions.gin_trgm_ops);

create trigger events_set_updated_at
  before update on public.events
  for each row execute function private.set_updated_at();

create table public.ticket_tiers (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  description text not null default '' check (char_length(description) <= 500),
  price_minor bigint not null check (price_minor between 0 and 100000000),
  currency text not null default 'LKR' check (currency = 'LKR'),
  quantity integer not null check (quantity between 0 and 100000),
  max_per_order integer not null default 10 check (max_per_order between 1 and 50),
  sales_start_at timestamptz,
  sales_end_at timestamptz,
  sort_order integer not null default 0,
  -- server-owned inventory counters
  sold integer not null default 0 check (sold >= 0),
  reserved integer not null default 0 check (reserved >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ticket_tiers_inventory check (sold + reserved <= quantity),
  constraint ticket_tiers_sales_window check (sales_start_at is null or sales_end_at is null or sales_end_at > sales_start_at)
);
create index ticket_tiers_event_idx on public.ticket_tiers (event_id, sort_order);

create trigger ticket_tiers_set_updated_at
  before update on public.ticket_tiers
  for each row execute function private.set_updated_at();

create table public.registration_questions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  prompt text not null check (char_length(btrim(prompt)) between 1 and 300),
  kind text not null check (kind in ('short_text', 'long_text', 'single_choice', 'multi_choice', 'yes_no')),
  options jsonb not null default '[]'::jsonb check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) <= 30),
  required boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index registration_questions_event_idx on public.registration_questions (event_id, sort_order);

create trigger registration_questions_set_updated_at
  before update on public.registration_questions
  for each row execute function private.set_updated_at();

create table public.event_media (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  storage_path text not null check (char_length(storage_path) between 3 and 300),
  kind text not null default 'gallery' check (kind in ('cover', 'gallery')),
  alt_text text not null default '' check (char_length(alt_text) <= 300),
  width integer check (width is null or width between 1 and 20000),
  height integer check (height is null or height between 1 and 20000),
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index event_media_event_idx on public.event_media (event_id, sort_order);

create table public.ai_drafts (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  organizer_id uuid not null references public.organizer_profiles (id) on delete cascade,
  kind text not null check (kind in ('agenda', 'questions')),
  status text not null check (status in ('succeeded', 'failed', 'approved', 'discarded')),
  request_id text not null check (char_length(request_id) between 8 and 100),
  instructions text check (instructions is null or char_length(instructions) <= 1000),
  content jsonb,
  model text,
  error_code text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_drafts_request_unique unique (event_id, request_id)
);
create index ai_drafts_organizer_idx on public.ai_drafts (organizer_id, created_at desc);

create trigger ai_drafts_set_updated_at
  before update on public.ai_drafts
  for each row execute function private.set_updated_at();

create table public.event_updates (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  kind text not null check (kind in ('venue_change', 'schedule_change', 'general')),
  message text not null check (char_length(btrim(message)) between 1 and 1000),
  recipients integer not null default 0 check (recipients >= 0),
  sent_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);
create index event_updates_event_idx on public.event_updates (event_id, created_at desc);

-- Payout status per event for organizer_settlements() (server only).
create table public.event_settlements (
  event_id uuid primary key references public.events (id) on delete cascade,
  status text not null default 'unsettled' check (status in ('unsettled', 'scheduled', 'paid')),
  scheduled_for date,
  paid_at timestamptz,
  payout_reference text,
  updated_at timestamptz not null default now()
);

create trigger event_settlements_set_updated_at
  before update on public.event_settlements
  for each row execute function private.set_updated_at();

create table public.saved_events (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, event_id)
);
create index saved_events_event_idx on public.saved_events (event_id);

create table public.saved_organizers (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  organizer_id uuid not null references public.organizer_profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, organizer_id)
);
create index saved_organizers_organizer_idx on public.saved_organizers (organizer_id);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in (
    'registration_confirmed', 'payment_status', 'ticket_issued', 'event_reminder', 'venue_change',
    'schedule_change', 'event_cancelled', 'refund_status', 'waitlist_movement', 'organizer_update', 'general'
  )),
  title text not null check (char_length(title) between 1 and 200),
  body text not null default '' check (char_length(body) <= 2000),
  event_id uuid references public.events (id) on delete set null,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user_created_idx on public.notifications (user_id, created_at desc);
create index notifications_user_unread_idx on public.notifications (user_id) where read_at is null;

create or replace function private.notify(
  p_user_id uuid,
  p_kind text,
  p_title text,
  p_body text,
  p_event_id uuid default null,
  p_data jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user_id is null then
    return;
  end if;
  insert into public.notifications (user_id, kind, title, body, event_id, data)
  values (p_user_id, p_kind, left(p_title, 200), left(coalesce(p_body, ''), 2000), p_event_id, coalesce(p_data, '{}'::jsonb));
end;
$$;
