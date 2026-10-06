-- =============================================================================
-- Zuno 0400: orders, registrations, tickets, check-ins and payments
-- None of these tables is directly writable by clients. orders/order_items are
-- readable by their owner (contract section 2); the rest are reachable only
-- through security-definer RPCs.
-- =============================================================================

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete set null,
  event_id uuid references public.events (id) on delete restrict,
  kind text not null check (kind in ('ticket', 'wallet_topup', 'event_creation_fee')),
  status text not null default 'pending' check (status in ('pending', 'paid', 'failed', 'cancelled', 'expired', 'refunded')),
  subtotal_minor bigint not null check (subtotal_minor >= 0),
  commission_minor bigint not null default 0 check (commission_minor >= 0),
  total_minor bigint not null check (total_minor > 0),
  currency text not null default 'LKR' check (currency = 'LKR'),
  idempotency_key text not null check (char_length(idempotency_key) between 8 and 200),
  -- registration answers captured at checkout for ticket orders (owner-readable)
  answers jsonb check (answers is null or jsonb_typeof(answers) = 'array'),
  provider text not null default 'payhere' check (provider = 'payhere'),
  status_reason text,
  expires_at timestamptz not null,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint orders_event_required check (kind = 'wallet_topup' or event_id is not null),
  constraint orders_topup_has_no_event check (kind <> 'wallet_topup' or event_id is null),
  constraint orders_commission_le_subtotal check (commission_minor <= subtotal_minor),
  constraint orders_paid_at check (status <> 'paid' or paid_at is not null)
);
create unique index orders_user_idempotency_idx on public.orders (user_id, idempotency_key) where user_id is not null;
create index orders_user_created_idx on public.orders (user_id, created_at desc);
create index orders_event_status_idx on public.orders (event_id, status);
create index orders_pending_expiry_idx on public.orders (expires_at) where status = 'pending';

create trigger orders_set_updated_at
  before update on public.orders
  for each row execute function private.set_updated_at();

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  tier_id uuid not null references public.ticket_tiers (id) on delete restrict,
  quantity integer not null check (quantity between 1 and 50),
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  constraint order_items_one_line_per_tier unique (order_id, tier_id)
);
create index order_items_tier_idx on public.order_items (tier_id);

create table public.registrations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete restrict,
  user_id uuid references auth.users (id) on delete set null,
  status text not null check (status in ('confirmed', 'waitlisted', 'offered', 'cancelled')),
  kind text not null check (kind in ('free', 'paid')),
  used_allowance boolean not null default false,
  allowance_month date check (allowance_month is null or extract(day from allowance_month) = 1),
  fee_minor bigint not null default 0 check (fee_minor >= 0),
  order_id uuid references public.orders (id) on delete restrict,
  reference text not null unique check (reference ~ '^ZR-[0-9A-HJKMNP-TV-Z]{8}$'),
  idempotency_key text check (idempotency_key is null or char_length(idempotency_key) between 8 and 200),
  -- original RPC result, returned verbatim on idempotent replay
  result jsonb,
  offer_expires_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint registrations_paid_has_order check (kind = 'free' or order_id is not null),
  constraint registrations_offer_has_expiry check (status <> 'offered' or offer_expires_at is not null),
  constraint registrations_allowance_month check (not used_allowance or allowance_month is not null)
);
-- One active registration per user and event (contract: unique active registration).
create unique index registrations_one_active_idx
  on public.registrations (event_id, user_id)
  where status in ('confirmed', 'waitlisted', 'offered');
create unique index registrations_idempotency_idx
  on public.registrations (user_id, idempotency_key)
  where idempotency_key is not null;
create index registrations_user_created_idx on public.registrations (user_id, created_at desc);
create index registrations_event_status_idx on public.registrations (event_id, status, created_at);
create index registrations_offer_expiry_idx on public.registrations (offer_expires_at) where status = 'offered';
create index registrations_order_idx on public.registrations (order_id);

create trigger registrations_set_updated_at
  before update on public.registrations
  for each row execute function private.set_updated_at();

create table public.registration_answers (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null references public.registrations (id) on delete cascade,
  question_id uuid not null references public.registration_questions (id) on delete cascade,
  value jsonb not null,
  created_at timestamptz not null default now(),
  constraint registration_answers_unique unique (registration_id, question_id)
);
create index registration_answers_question_idx on public.registration_answers (question_id);

create table public.tickets (
  id uuid primary key default gen_random_uuid(),
  registration_id uuid not null references public.registrations (id) on delete restrict,
  event_id uuid not null references public.events (id) on delete restrict,
  user_id uuid references auth.users (id) on delete set null,
  tier_id uuid references public.ticket_tiers (id) on delete restrict,
  order_id uuid references public.orders (id) on delete restrict,
  attendee_name text check (attendee_name is null or char_length(attendee_name) <= 120),
  code text not null unique check (code ~ '^ZN-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$'),
  qr_token text not null unique check (qr_token ~ '^[A-Za-z0-9_-]{43}$'),
  status text not null default 'valid' check (status in ('valid', 'checked_in', 'cancelled', 'refunded')),
  issued_at timestamptz not null default now(),
  checked_in_at timestamptz,
  cancelled_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint tickets_checked_in_at check (status <> 'checked_in' or checked_in_at is not null)
);
create index tickets_user_idx on public.tickets (user_id, issued_at desc);
create index tickets_event_status_idx on public.tickets (event_id, status);
create index tickets_registration_idx on public.tickets (registration_id);
create index tickets_order_idx on public.tickets (order_id);

create trigger tickets_set_updated_at
  before update on public.tickets
  for each row execute function private.set_updated_at();

create table public.check_ins (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null unique references public.tickets (id) on delete restrict,
  event_id uuid not null references public.events (id) on delete restrict,
  checked_in_by uuid references auth.users (id) on delete set null,
  checked_in_at timestamptz not null default now()
);
create index check_ins_event_idx on public.check_ins (event_id, checked_in_at desc);

-- One row per verified PayHere notification. (provider_payment_id, status_code)
-- is unique, which makes duplicate callbacks idempotent no-ops. `notification`
-- holds an allow-listed copy of the payload: never card numbers, card holder
-- names, expiry dates or the md5sig.
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete restrict,
  provider text not null default 'payhere' check (provider = 'payhere'),
  provider_payment_id text not null check (char_length(provider_payment_id) between 1 and 120),
  status_code integer not null,
  amount_minor bigint not null,
  currency text not null check (char_length(currency) = 3),
  method text check (method is null or char_length(method) <= 40),
  outcome text not null,
  notification jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint payments_idempotency unique (provider_payment_id, status_code)
);
create index payments_order_idx on public.payments (order_id, created_at);

-- ---------------------------------------------------------------------------
-- Identifier generators (unique by construction + collision re-check)
-- ---------------------------------------------------------------------------
create or replace function private.generate_registration_reference()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_ref text;
begin
  loop
    v_ref := 'ZR-' || private.random_crockford(8);
    exit when not exists (select 1 from public.registrations where reference = v_ref);
  end loop;
  return v_ref;
end;
$$;

create or replace function private.generate_ticket_code()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  loop
    v_code := 'ZN-' || private.random_crockford(4) || '-' || private.random_crockford(4);
    exit when not exists (select 1 from public.tickets where code = v_code);
  end loop;
  return v_code;
end;
$$;

-- Issues one ticket. Returns the new ticket id.
create or replace function private.issue_ticket(
  p_registration_id uuid,
  p_event_id uuid,
  p_user_id uuid,
  p_tier_id uuid,
  p_order_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket_id uuid;
  v_name text;
begin
  select display_name into v_name from public.profiles where id = p_user_id;
  insert into public.tickets (registration_id, event_id, user_id, tier_id, order_id, attendee_name, code, qr_token)
  values (p_registration_id, p_event_id, p_user_id, p_tier_id, p_order_id, v_name,
          private.generate_ticket_code(), private.generate_qr_token())
  returning id into v_ticket_id;
  return v_ticket_id;
end;
$$;
