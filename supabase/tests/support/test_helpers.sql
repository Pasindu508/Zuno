-- =============================================================================
-- Test helpers (LOCAL VERIFICATION ONLY - applied after migrations + seed by
-- scripts/db-verify.sh; never part of a Supabase project).
--
-- Assertions RAISE NOTICE 'PASS: ...' on success and RAISE EXCEPTION
-- 'FAIL: ...' on failure. Role switching mimics PostgREST:
--   set_config('role', 'authenticated', true) + request.jwt.claims.
-- =============================================================================

create schema if not exists tests;
grant usage on schema tests to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------
create or replace function tests.ok(p_condition boolean, p_description text)
returns void language plpgsql as $$
begin
  if p_condition is distinct from true then
    raise exception 'FAIL: %', p_description;
  end if;
  raise notice 'PASS: %', p_description;
end $$;

create or replace function tests.is(p_got anycompatible, p_want anycompatible, p_description text)
returns void language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'FAIL: % (got %, want %)', p_description, p_got, p_want;
  end if;
  raise notice 'PASS: %', p_description;
end $$;

-- Expect p_sql to raise an error whose message equals p_message.
create or replace function tests.throws(p_sql text, p_message text, p_description text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm = p_message then
      raise notice 'PASS: %', p_description;
      return;
    end if;
    raise exception 'FAIL: % (expected error "%", got "%" [%])', p_description, p_message, sqlerrm, sqlstate;
  end;
  raise exception 'FAIL: % (expected error "%", but the statement succeeded)', p_description, p_message;
end $$;

-- Expect p_sql to raise an error with SQLSTATE p_state (e.g. 42501).
create or replace function tests.throws_state(p_sql text, p_state text, p_description text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      raise notice 'PASS: %', p_description;
      return;
    end if;
    raise exception 'FAIL: % (expected SQLSTATE %, got % "%")', p_description, p_state, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % (expected SQLSTATE %, but the statement succeeded)', p_description, p_state;
end $$;

-- Expect p_sql to succeed.
create or replace function tests.lives(p_sql text, p_description text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise exception 'FAIL: % (unexpected error "%" [%])', p_description, sqlerrm, sqlstate;
  end;
  raise notice 'PASS: %', p_description;
end $$;

-- Count rows of an arbitrary query as the current role (0 when denied by RLS).
create or replace function tests.count_rows(p_sql text)
returns bigint language plpgsql as $$
declare
  v_count bigint;
begin
  execute 'select count(*) from (' || p_sql || ') q' into v_count;
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- Role switching (PostgREST style)
-- ---------------------------------------------------------------------------
create or replace function tests.as_user(p_user_id uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user_id, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function tests.as_anon()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function tests.as_service()
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform set_config('role', 'service_role', true);
end $$;

create or replace function tests.as_postgres()
returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- Fixture builders (SECURITY DEFINER: run as the superuser whatever the
-- current test role is; they never touch request.jwt.claims).
-- ---------------------------------------------------------------------------
create or replace function tests.new_user(p_label text, p_verified boolean default true)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_id, 'authenticated', 'authenticated', p_label || '.' || left(v_id::text, 8) || '@test.example',
          '{"provider":"email"}', jsonb_build_object('display_name', initcap(p_label)), now(), now());
  if p_verified then
    update public.profiles set identity_status = 'verified_unique' where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function tests.new_organizer(p_owner uuid, p_verified boolean default true)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into public.organizer_profiles (id, owner_id, name, slug, verification_status)
  values (v_id, p_owner, 'Org ' || left(v_id::text, 8), 'org-' || left(v_id::text, 8),
          case when p_verified then 'verified' else 'pending' end);
  insert into public.venues (organizer_id, name, address_line, city, district, latitude, longitude)
  values (v_id, 'Hall ' || left(v_id::text, 4), 'Test Road', 'Colombo', 'Colombo', 6.9271, 79.8612);
  return v_id;
end $$;

create or replace function tests.new_event(
  p_organizer uuid,
  p_free boolean default true,
  p_capacity integer default 100,
  p_status text default 'published',
  p_starts_in interval default interval '7 days'
)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid := gen_random_uuid();
  v_venue uuid;
begin
  select id into v_venue from public.venues where organizer_id = p_organizer order by created_at limit 1;
  insert into public.events (id, organizer_id, category_id, venue_id, title, summary, description, format,
                             starts_at, ends_at, capacity, is_free, tags, cover_path, status,
                             creation_fee_paid_at, published_at)
  values (v_id, p_organizer, 'technology', v_venue, 'Test event ' || left(v_id::text, 8),
          'A sufficiently long summary for tests', 'Description', 'physical',
          now() + p_starts_in, now() + p_starts_in + interval '3 hours', p_capacity, p_free, '{test}',
          p_organizer::text || '/cover.jpg', p_status,
          case when p_status = 'published' then now() end,
          case when p_status = 'published' then now() end);
  return v_id;
end $$;

create or replace function tests.new_tier(p_event uuid, p_price bigint, p_quantity integer, p_max integer default 10)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid;
begin
  insert into public.ticket_tiers (event_id, name, price_minor, quantity, max_per_order)
  values (p_event, 'Tier ' || p_price, p_price, p_quantity, p_max)
  returning id into v_id;
  return v_id;
end $$;

create or replace function tests.new_question(p_event uuid, p_kind text, p_required boolean, p_options jsonb default '[]')
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid;
begin
  insert into public.registration_questions (event_id, prompt, kind, options, required)
  values (p_event, 'Question ' || p_kind, p_kind, p_options, p_required)
  returning id into v_id;
  return v_id;
end $$;

-- Credit a wallet through the ledger (the only legal way).
create or replace function tests.fund_wallet(p_user uuid, p_amount bigint)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into public.wallet_ledger (user_id, entry_type, amount_minor, status, reference_type, description)
  values (p_user, 'topup', p_amount, 'posted', 'manual', 'test funding');
end $$;

create or replace function tests.set_allowance_used(p_user uuid, p_used integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  insert into public.allowance_usage (user_id, month, used)
  values (p_user, private.colombo_month(), p_used)
  on conflict (user_id, month) do update set used = excluded.used;
end $$;

-- Superuser-side reads used by assertions while the role is a client.
create or replace function tests.balance(p_user uuid)
returns bigint language sql security definer set search_path = public as $$
  select balance_minor from public.wallets where user_id = p_user;
$$;

create or replace function tests.ledger_sum(p_user uuid)
returns bigint language sql security definer set search_path = public as $$
  select coalesce(sum(amount_minor), 0) from public.wallet_ledger where user_id = p_user and status = 'posted';
$$;

create or replace function tests.seats_taken(p_event uuid)
returns integer language sql security definer set search_path = public as $$
  select seats_taken from public.events where id = p_event;
$$;

create or replace function tests.allowance_used(p_user uuid)
returns integer language sql security definer set search_path = public as $$
  select coalesce((select used from public.allowance_usage where user_id = p_user and month = private.colombo_month()), 0);
$$;

-- Simulates the PayHere notification path as the Edge Function would call it.
create or replace function tests.notify_payhere(p_order uuid, p_payment_id text, p_status integer, p_amount bigint, p_currency text default 'LKR')
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return public.apply_payhere_notification(p_order, p_payment_id, p_status, p_amount, p_currency, 'VISA',
    jsonb_build_object('merchant_id', '1211149', 'order_id', p_order, 'payment_id', p_payment_id,
                       'payhere_amount', to_char(p_amount / 100.0, 'FM999999990.00'), 'payhere_currency', p_currency,
                       'status_code', p_status::text, 'card_no', '************1292', 'card_holder_name', 'Test Holder',
                       'card_expiry', '12/30', 'md5sig', 'ABCDEF'));
end $$;

grant execute on all functions in schema tests to anon, authenticated, service_role;
