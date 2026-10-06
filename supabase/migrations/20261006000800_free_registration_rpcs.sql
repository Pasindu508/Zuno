-- =============================================================================
-- Zuno 0800: free-event registration, waitlist and cancellation RPCs
--
-- Locking order (to avoid deadlocks):
--   1. the events row FOR UPDATE, always first. Rows that belong to one event
--      (its registrations, orders, tiers, tickets) are only locked while that
--      event lock is held, so their relative order cannot deadlock;
--   2. rows shared across events are locked afterwards: wallets (ascending
--      user_id when several are touched, e.g. cancel_event) and then
--      allowance_usage.
-- Every function that changes seats locks the event row FOR UPDATE first, so
-- capacity checks and seats_taken updates for one event are serialised.
--
-- Seat accounting for free events: events.seats_taken counts confirmed
-- registrations PLUS active waitlist offers (an offer holds its seat until it
-- is accepted, declined or expires). Expired offers are released lazily under
-- the event lock (release_expired_offers) and by expire_stale_orders().
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Answer validation. Returns a normalised array [{question_id, value}].
-- value shapes: short_text/long_text -> "text", single_choice -> "choice"
-- (["choice"] accepted), multi_choice -> ["a","b"], yes_no -> true/false.
-- ---------------------------------------------------------------------------
create or replace function private.validate_answers(p_event_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_answers jsonb := coalesce(p_answers, '[]'::jsonb);
  v_item jsonb;
  v_qid uuid;
  v_value jsonb;
  v_q public.registration_questions;
  v_out jsonb := '[]'::jsonb;
  v_seen uuid[] := '{}';
  v_missing uuid;
begin
  if jsonb_typeof(v_answers) <> 'array' or jsonb_array_length(v_answers) > 50 then
    perform private.fail('answers_invalid', 'answers must be an array');
  end if;

  for v_item in select value from jsonb_array_elements(v_answers) loop
    if jsonb_typeof(v_item) <> 'object' or not (v_item ? 'question_id') then
      perform private.fail('answers_invalid', 'each answer needs question_id and value');
    end if;
    begin
      v_qid := (v_item ->> 'question_id')::uuid;
    exception when invalid_text_representation then
      perform private.fail('answers_invalid', 'question_id is not a uuid');
    end;
    if v_qid = any (v_seen) then
      perform private.fail('answers_invalid', 'duplicate:' || v_qid);
    end if;
    v_seen := v_seen || v_qid;

    select * into v_q from public.registration_questions where id = v_qid and event_id = p_event_id;
    if not found then
      perform private.fail('answers_invalid', 'unknown_question:' || v_qid);
    end if;

    v_value := v_item -> 'value';
    -- null, "" and [] mean "not answered"
    if v_value is null
       or jsonb_typeof(v_value) = 'null'
       or (jsonb_typeof(v_value) = 'string' and btrim(v_value #>> '{}') = '')
       or (jsonb_typeof(v_value) = 'array' and jsonb_array_length(v_value) = 0) then
      continue;
    end if;

    if v_q.kind in ('short_text', 'long_text') then
      if jsonb_typeof(v_value) <> 'string'
         or char_length(btrim(v_value #>> '{}')) > (case when v_q.kind = 'short_text' then 200 else 2000 end) then
        perform private.fail('answers_invalid', 'invalid:' || v_qid);
      end if;
      v_value := to_jsonb(btrim(v_value #>> '{}'));
    elsif v_q.kind = 'single_choice' then
      if jsonb_typeof(v_value) = 'array' and jsonb_array_length(v_value) = 1 then
        v_value := v_value -> 0;
      end if;
      if jsonb_typeof(v_value) <> 'string' or not (v_q.options @> jsonb_build_array(v_value)) then
        perform private.fail('answers_invalid', 'invalid:' || v_qid);
      end if;
    elsif v_q.kind = 'multi_choice' then
      if jsonb_typeof(v_value) <> 'array'
         or exists (
           select 1 from jsonb_array_elements(v_value) e
           where jsonb_typeof(e) <> 'string' or not (v_q.options @> jsonb_build_array(e))
         )
         or (select count(distinct e) from jsonb_array_elements(v_value) e) <> jsonb_array_length(v_value) then
        perform private.fail('answers_invalid', 'invalid:' || v_qid);
      end if;
    elsif v_q.kind = 'yes_no' then
      if jsonb_typeof(v_value) <> 'boolean' then
        perform private.fail('answers_invalid', 'invalid:' || v_qid);
      end if;
    end if;

    v_out := v_out || jsonb_build_array(jsonb_build_object('question_id', v_qid, 'value', v_value));
  end loop;

  select q.id into v_missing
    from public.registration_questions q
   where q.event_id = p_event_id
     and q.required
     and not exists (
       select 1 from jsonb_array_elements(v_out) a where (a ->> 'question_id')::uuid = q.id
     )
   order by q.sort_order
   limit 1;
  if v_missing is not null then
    perform private.fail('answers_invalid', 'required:' || v_missing);
  end if;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Seat hand-over. Caller MUST hold the event row lock.
-- A seat freed by a confirmed/offered registration goes to the oldest
-- waitlisted user as an offer (seats_taken unchanged); otherwise it is freed.
-- Returns the offered registration id, or null.
-- ---------------------------------------------------------------------------
create or replace function private.pass_seat_on(p_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.events;
  v_next public.registrations;
  v_expires timestamptz;
begin
  select * into v_event from public.events where id = p_event_id;
  v_expires := least(now() + interval '12 hours', private.registration_closes_at(v_event));

  if v_event.status = 'published' and v_expires > now() + interval '5 minutes' then
    select * into v_next
      from public.registrations
     where event_id = p_event_id and status = 'waitlisted' and user_id is not null
     order by created_at, id
     limit 1
     for update;
    if found then
      update public.registrations
         set status = 'offered', offer_expires_at = v_expires
       where id = v_next.id;
      perform private.notify(
        v_next.user_id, 'waitlist_movement', 'A seat is available for you',
        format('A seat opened up for %s. Confirm before %s (Colombo time) to keep it.',
               v_event.title, to_char(v_expires at time zone 'Asia/Colombo', 'DD Mon HH24:MI')),
        p_event_id,
        jsonb_build_object('registration_id', v_next.id, 'status', 'offered', 'offer_expires_at', v_expires));
      perform private.audit('waitlist_offered', 'registration', v_next.id, p_event_id,
                            jsonb_build_object('offer_expires_at', v_expires));
      return v_next.id;
    end if;
  end if;

  update public.events set seats_taken = greatest(seats_taken - 1, 0) where id = p_event_id;
  return null;
end;
$$;

-- Expire stale offers of one event. Caller MUST hold the event row lock.
create or replace function private.release_expired_offers(p_event_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reg record;
  v_count integer := 0;
begin
  for v_reg in
    select id, user_id
      from public.registrations
     where event_id = p_event_id and status = 'offered' and offer_expires_at <= now()
     order by offer_expires_at, id
     for update
  loop
    update public.registrations
       set status = 'cancelled', cancelled_at = now(), cancellation_reason = 'offer_expired'
     where id = v_reg.id;
    perform private.notify(v_reg.user_id, 'waitlist_movement', 'Your waitlist offer expired',
                           'The seat was offered to the next person on the waitlist.',
                           p_event_id, jsonb_build_object('registration_id', v_reg.id, 'status', 'expired'));
    perform private.pass_seat_on(p_event_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Cancel one registration (any kind) and release what it held.
-- Caller MUST hold the event row lock. No refunds happen here.
create or replace function private.cancel_registration_internal(p_registration_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_reg public.registrations;
  v_ticket record;
  v_released integer := 0;
begin
  select * into v_reg from public.registrations where id = p_registration_id for update;
  if not found or v_reg.status = 'cancelled' then
    return;
  end if;

  update public.registrations
     set status = 'cancelled', cancelled_at = now(), cancellation_reason = p_reason
   where id = p_registration_id;

  for v_ticket in
    update public.tickets
       set status = 'cancelled', cancelled_at = now()
     where registration_id = p_registration_id and status = 'valid'
    returning id, tier_id
  loop
    if v_reg.kind = 'paid' and v_ticket.tier_id is not null then
      update public.ticket_tiers set sold = greatest(sold - 1, 0) where id = v_ticket.tier_id;
      v_released := v_released + 1;
    end if;
  end loop;

  if v_reg.kind = 'free' and v_reg.status in ('confirmed', 'offered') then
    perform private.pass_seat_on(v_reg.event_id);
  elsif v_reg.kind = 'paid' and v_released > 0 then
    update public.events set seats_taken = greatest(seats_taken - v_released, 0) where id = v_reg.event_id;
  end if;

  perform private.audit('registration_cancelled', 'registration', p_registration_id, v_reg.event_id,
                        jsonb_build_object('reason', p_reason, 'previous_status', v_reg.status));
end;
$$;

-- ---------------------------------------------------------------------------
-- quote_free_registration (read-only preview; register re-validates)
-- ---------------------------------------------------------------------------
create or replace function public.quote_free_registration(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_event public.events;
  v_active public.registrations;
  v_month date := private.colombo_month();
  v_limit bigint := private.setting('free_allowance_per_month');
  v_used integer;
  v_fee bigint;
  v_balance bigint;
  v_identity text;
  v_reason text;
begin
  select * into v_event from public.events where id = p_event_id;
  if not found or v_event.status in ('draft', 'pending_review') then
    perform private.fail('event_not_found');
  end if;

  v_used := coalesce((select used from public.allowance_usage where user_id = v_uid and month = v_month), 0);
  v_fee := case when v_used < v_limit then 0 else private.setting('extra_free_registration_fee_minor') end;
  v_balance := coalesce((select balance_minor from public.wallets where user_id = v_uid), 0);
  v_identity := coalesce((select identity_status from public.profiles where id = v_uid), 'none');

  select * into v_active
    from public.registrations
   where event_id = p_event_id and user_id = v_uid
     and (status in ('confirmed', 'waitlisted') or (status = 'offered' and offer_expires_at > now()))
   limit 1;

  v_reason := case
    when not v_event.is_free then 'not_free_event'
    when not private.registration_open(v_event) then 'registration_closed'
    when v_active.status = 'confirmed' then 'already_registered'
    when v_active.status = 'waitlisted' and v_event.seats_taken >= v_event.capacity then 'already_registered'
    when v_identity <> 'verified_unique' then 'identity_required'
    when v_active.status is distinct from 'offered' and v_event.seats_taken >= v_event.capacity then 'sold_out'
    when v_fee > v_balance then 'insufficient_balance'
  end;

  return jsonb_build_object(
    'allowance_limit', v_limit,
    'allowance_used', v_used,
    'allowance_remaining', greatest(v_limit - v_used, 0),
    'fee_minor', v_fee,
    'wallet_balance_minor', v_balance,
    'currency', 'LKR',
    'can_register', v_reason is null,
    'reason', v_reason,
    'seats_remaining', greatest(v_event.capacity - v_event.seats_taken, 0),
    'month', to_char(v_month, 'YYYY-MM')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- register_for_free_event (atomic; any failure rolls everything back)
-- ---------------------------------------------------------------------------
create or replace function public.register_for_free_event(
  p_event_id uuid,
  p_answers jsonb default '[]'::jsonb,
  p_expected_fee_minor bigint default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_prior public.registrations;
  v_event public.events;
  v_active public.registrations;
  v_from_offer boolean := false;
  v_balance bigint;
  v_identity text;
  v_answers jsonb;
  v_month date := private.colombo_month();
  v_limit bigint := private.setting('free_allowance_per_month');
  v_used integer;
  v_use_allowance boolean;
  v_fee bigint;
  v_reg_id uuid;
  v_reference text;
  v_ticket_id uuid;
  v_result jsonb;
begin
  if v_key is not null and char_length(v_key) not between 8 and 200 then
    perform private.fail('invalid_idempotency_key');
  end if;

  -- (1) Idempotent replay fast path: a completed request is answered verbatim.
  if v_key is not null then
    select * into v_prior from public.registrations where user_id = v_uid and idempotency_key = v_key;
    if found then
      if v_prior.event_id <> p_event_id then
        perform private.fail('idempotency_conflict');
      end if;
      return v_prior.result;
    end if;
  end if;

  -- (2) Lock the event row: serialises capacity checks for this event.
  select * into v_event from public.events where id = p_event_id for update;
  if not found or v_event.status in ('draft', 'pending_review') then
    perform private.fail('event_not_found');
  end if;
  if not v_event.is_free then
    perform private.fail('not_free_event');
  end if;
  if not private.registration_open(v_event) then
    perform private.fail('registration_closed');
  end if;

  -- (2b) Re-check idempotency under the event lock: a concurrent request with
  --      the same key for this event may have committed while we waited.
  if v_key is not null then
    select * into v_prior from public.registrations where user_id = v_uid and idempotency_key = v_key;
    if found then
      if v_prior.event_id <> p_event_id then
        perform private.fail('idempotency_conflict');
      end if;
      return v_prior.result;
    end if;
  end if;

  if private.release_expired_offers(p_event_id) > 0 then
    select * into v_event from public.events where id = p_event_id;
  end if;

  select * into v_active
    from public.registrations
   where event_id = p_event_id and user_id = v_uid and status in ('confirmed', 'waitlisted', 'offered')
   for update;
  if found then
    if v_active.status = 'confirmed' then
      perform private.fail('already_registered');
    elsif v_active.status = 'offered' then
      v_from_offer := true;
    elsif v_event.seats_taken >= v_event.capacity then
      -- waitlisted and still no free seat
      perform private.fail('already_registered');
    end if;
  end if;

  -- (3) Lock the wallet row: serialises this user's money movements.
  insert into public.wallets (user_id) values (v_uid) on conflict (user_id) do nothing;
  select balance_minor into v_balance from public.wallets where user_id = v_uid for update;

  -- (4) Re-check idempotency under the wallet lock (covers a concurrent
  --     request with the same key for a different event).
  if v_key is not null then
    select * into v_prior from public.registrations where user_id = v_uid and idempotency_key = v_key;
    if found then
      if v_prior.event_id <> p_event_id then
        perform private.fail('idempotency_conflict');
      end if;
      return v_prior.result;
    end if;
  end if;

  v_identity := coalesce((select identity_status from public.profiles where id = v_uid), 'none');
  if v_identity <> 'verified_unique' then
    perform private.fail('identity_required');
  end if;

  -- Capacity: seats_taken already includes active offers (holds).
  if not v_from_offer and v_event.seats_taken >= v_event.capacity then
    perform private.fail('sold_out');
  end if;

  v_answers := private.validate_answers(p_event_id, p_answers);

  -- (5) Monthly allowance (Asia/Colombo calendar month), counter row locked.
  insert into public.allowance_usage (user_id, month, used) values (v_uid, v_month, 0)
  on conflict (user_id, month) do nothing;
  select used into v_used from public.allowance_usage where user_id = v_uid and month = v_month for update;
  v_use_allowance := v_used < v_limit;
  v_fee := case when v_use_allowance then 0 else private.setting('extra_free_registration_fee_minor') end;

  -- The client must echo the exact fee it showed the user.
  if p_expected_fee_minor is distinct from v_fee then
    perform private.fail('fee_changed', 'fee_minor=' || v_fee);
  end if;
  if v_fee > v_balance then
    perform private.fail('insufficient_balance');
  end if;

  -- (6) Writes.
  if v_active.id is not null then
    update public.registrations
       set status = 'confirmed', offer_expires_at = null, used_allowance = v_use_allowance,
           allowance_month = v_month, fee_minor = v_fee, idempotency_key = v_key
     where id = v_active.id;
    v_reg_id := v_active.id;
    v_reference := v_active.reference;
  else
    insert into public.registrations (event_id, user_id, status, kind, used_allowance, allowance_month,
                                      fee_minor, reference, idempotency_key)
    values (p_event_id, v_uid, 'confirmed', 'free', v_use_allowance, v_month,
            v_fee, private.generate_registration_reference(), v_key)
    returning id, reference into v_reg_id, v_reference;
  end if;

  insert into public.registration_answers (registration_id, question_id, value)
  select v_reg_id, (a ->> 'question_id')::uuid, a -> 'value'
    from jsonb_array_elements(v_answers) a
  on conflict (registration_id, question_id) do update set value = excluded.value;

  v_ticket_id := private.issue_ticket(v_reg_id, p_event_id, v_uid, null, null);

  if v_fee > 0 then
    -- Debit through the ledger; the ledger trigger updates the wallet balance.
    perform private.ledger_post(v_uid, 'free_registration_fee', -v_fee, 'registration', v_reg_id,
                                'Extra free registration: ' || v_event.title);
    v_balance := v_balance - v_fee;
  end if;

  if v_use_allowance then
    update public.allowance_usage set used = used + 1 where user_id = v_uid and month = v_month;
    v_used := v_used + 1;
  end if;

  if not v_from_offer then
    update public.events set seats_taken = seats_taken + 1 where id = p_event_id;
  end if;

  perform private.notify(v_uid, 'registration_confirmed', 'You''re registered',
                         v_event.title || ' · ' || v_reference, p_event_id,
                         jsonb_build_object('registration_id', v_reg_id, 'ticket_id', v_ticket_id, 'reference', v_reference));
  perform private.audit('free_registration', 'registration', v_reg_id, p_event_id,
                        jsonb_build_object('fee_minor', v_fee, 'used_allowance', v_use_allowance,
                                           'month', to_char(v_month, 'YYYY-MM'), 'from_offer', v_from_offer));

  v_result := jsonb_build_object(
    'registration_id', v_reg_id,
    'reference', v_reference,
    'ticket_id', v_ticket_id,
    'fee_minor', v_fee,
    'allowance_remaining', greatest(v_limit - v_used, 0),
    'wallet_balance_minor', v_balance,
    'status', 'confirmed'
  );
  update public.registrations set result = v_result where id = v_reg_id;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- join_waitlist (free events that are currently full)
-- ---------------------------------------------------------------------------
create or replace function public.join_waitlist(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_event public.events;
  v_reg public.registrations;
  v_position integer;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if not found or v_event.status in ('draft', 'pending_review') then
    perform private.fail('event_not_found');
  end if;
  if not v_event.is_free then
    perform private.fail('not_free_event');
  end if;
  if not private.registration_open(v_event) then
    perform private.fail('registration_closed');
  end if;

  if private.release_expired_offers(p_event_id) > 0 then
    select * into v_event from public.events where id = p_event_id;
  end if;

  if exists (
    select 1 from public.registrations
    where event_id = p_event_id and user_id = v_uid and status in ('confirmed', 'waitlisted', 'offered')
  ) then
    perform private.fail('already_registered');
  end if;
  if coalesce((select identity_status from public.profiles where id = v_uid), 'none') <> 'verified_unique' then
    perform private.fail('identity_required');
  end if;
  if v_event.seats_taken < v_event.capacity then
    perform private.fail('seats_available');
  end if;

  -- clock_timestamp() (not now()) so queue order is strict even for several
  -- joins inside one transaction; ties fall back to the id.
  insert into public.registrations (event_id, user_id, status, kind, reference, created_at)
  values (p_event_id, v_uid, 'waitlisted', 'free', private.generate_registration_reference(), clock_timestamp())
  returning * into v_reg;

  select count(*)::integer into v_position
    from public.registrations w
   where w.event_id = p_event_id and w.status = 'waitlisted'
     and (w.created_at, w.id) <= (v_reg.created_at, v_reg.id);

  perform private.audit('waitlist_joined', 'registration', v_reg.id, p_event_id,
                        jsonb_build_object('position', v_position));

  return jsonb_build_object('registration_id', v_reg.id, 'status', 'waitlisted', 'position', v_position);
end;
$$;

-- ---------------------------------------------------------------------------
-- cancel_registration (attendee-initiated, free registrations)
-- ---------------------------------------------------------------------------
create or replace function public.cancel_registration(p_registration_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_event_id uuid;
  v_event public.events;
  v_reg public.registrations;
begin
  select event_id into v_event_id
    from public.registrations
   where id = p_registration_id and user_id = v_uid;
  if not found then
    perform private.fail('registration_not_found');
  end if;

  -- Lock order: event first, then the registration.
  select * into v_event from public.events where id = v_event_id for update;
  select * into v_reg from public.registrations where id = p_registration_id for update;

  if v_reg.status = 'cancelled' then
    return jsonb_build_object('registration_id', v_reg.id, 'status', 'cancelled');
  end if;
  if v_reg.kind = 'paid' then
    -- Paid tickets are refunded by the organizer / event cancellation flow.
    perform private.fail('not_cancellable');
  end if;
  if exists (select 1 from public.tickets where registration_id = v_reg.id and status = 'checked_in') then
    perform private.fail('already_checked_in');
  end if;
  if now() >= v_event.ends_at then
    perform private.fail('registration_closed');
  end if;

  perform private.release_expired_offers(v_event_id);
  perform private.cancel_registration_internal(p_registration_id, 'attendee_cancelled');

  return jsonb_build_object('registration_id', v_reg.id, 'status', 'cancelled');
end;
$$;
