-- =============================================================================
-- Zuno 0900: PayHere orders, notification application, expiry, rate limits
--
-- All functions here are SERVICE-ROLE ONLY (granted in 20261006001300). Edge
-- Functions authenticate the user and pass p_user_id explicitly; prices,
-- commission and totals are always computed from the database.
--
-- Commission (contract section 1):
--   commission_minor = (subtotal_minor * commission_bps + 5000) / 10000
--   (integer division = half-up rounding). The attendee pays face value;
--   commission is deducted from the organizer settlement.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- rate_limit_hit: fixed-window counter. Returns true while within the limit.
-- ---------------------------------------------------------------------------
create or replace function public.rate_limit_hit(p_key text, p_limit integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_window timestamptz;
  v_count integer;
begin
  if p_key is null or char_length(p_key) not between 1 and 200 or p_limit < 1 or p_window_seconds < 1 then
    perform private.fail('invalid_rate_limit');
  end if;
  v_window := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into public.rate_limits as r (key, window_start, count)
  values (p_key, v_window, 1)
  on conflict (key, window_start) do update set count = r.count + 1
  returning r.count into v_count;
  return v_count <= p_limit;
end;
$$;

-- ---------------------------------------------------------------------------
-- Payload sanitising: allow-list only. Card numbers, card holder names, card
-- expiry, customer details and md5sig are never stored.
-- ---------------------------------------------------------------------------
create or replace function private.sanitize_payhere_notification(p_payload jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(key, to_jsonb(left(value #>> '{}', 200))), '{}'::jsonb)
  from jsonb_each(case when jsonb_typeof(p_payload) = 'object' then p_payload else '{}'::jsonb end)
  where key in ('merchant_id', 'order_id', 'payment_id', 'payhere_amount', 'payhere_currency',
                'status_code', 'status_message', 'method', 'captured_amount', 'recurring')
    and jsonb_typeof(value) in ('string', 'number', 'boolean');
$$;

-- ---------------------------------------------------------------------------
-- Order JSON helpers
-- ---------------------------------------------------------------------------
create or replace function private.order_summary_json(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_lines jsonb;
begin
  select * into v_order from public.orders where id = p_order_id;
  if v_order.kind = 'ticket' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'label', t.name,
        'tier_id', t.id,
        'quantity', i.quantity,
        'unit_price_minor', i.unit_price_minor,
        'amount_minor', i.unit_price_minor * i.quantity
      ) order by t.sort_order, t.id), '[]'::jsonb)
      into v_lines
      from public.order_items i
      join public.ticket_tiers t on t.id = i.tier_id
     where i.order_id = p_order_id;
  else
    v_lines := jsonb_build_array(jsonb_build_object(
      'label', case v_order.kind when 'wallet_topup' then 'Wallet top-up' else 'Event creation fee' end,
      'quantity', 1,
      'unit_price_minor', v_order.total_minor,
      'amount_minor', v_order.total_minor
    ));
  end if;

  return jsonb_build_object(
    'order_id', v_order.id,
    'kind', v_order.kind,
    'status', v_order.status,
    'event_id', v_order.event_id,
    'expires_at', v_order.expires_at,
    'summary', jsonb_build_object(
      'lines', v_lines,
      'subtotal_minor', v_order.subtotal_minor,
      'commission_minor', v_order.commission_minor,
      'total_minor', v_order.total_minor,
      'currency', v_order.currency
    )
  );
end;
$$;

-- Summary + the customer/item fields the checkout Edge Function needs to build
-- the PayHere form. The Edge Function strips `customer`/`item_description`
-- before responding to the client.
create or replace function private.order_checkout_json(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_name text;
  v_email text;
  v_city text;
  v_title text;
  v_desc text;
begin
  select * into v_order from public.orders where id = p_order_id;
  select p.display_name, p.city into v_name, v_city from public.profiles p where p.id = v_order.user_id;
  select u.email into v_email from auth.users u where u.id = v_order.user_id;
  select e.title into v_title from public.events e where e.id = v_order.event_id;

  if v_order.kind = 'ticket' then
    select v_title || ' - ' || string_agg(t.name || ' x' || i.quantity, ', ' order by t.sort_order, t.id)
      into v_desc
      from public.order_items i join public.ticket_tiers t on t.id = i.tier_id
     where i.order_id = p_order_id;
  elsif v_order.kind = 'wallet_topup' then
    v_desc := 'Zuno wallet top-up';
  else
    v_desc := 'Event creation fee - ' || coalesce(v_title, '');
  end if;

  v_name := coalesce(nullif(btrim(v_name), ''), 'Zuno Customer');
  return private.order_summary_json(p_order_id) || jsonb_build_object(
    'item_description', left(v_desc, 250),
    'customer', jsonb_build_object(
      'first_name', split_part(v_name, ' ', 1),
      'last_name', coalesce(nullif(btrim(substr(v_name, char_length(split_part(v_name, ' ', 1)) + 1)), ''), '-'),
      'email', v_email,
      'city', coalesce(nullif(btrim(v_city), ''), 'Colombo')
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Closing / refunding orders. Callers hold the event lock (if any) first.
-- ---------------------------------------------------------------------------
create or replace function private.release_order_reservations(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1
     from public.ticket_tiers t
    where t.id in (select tier_id from public.order_items where order_id = p_order_id)
    order by t.id
    for update;
  update public.ticket_tiers t
     set reserved = t.reserved - i.quantity
    from public.order_items i
   where i.order_id = p_order_id and t.id = i.tier_id;
end;
$$;

-- pending -> expired | failed | cancelled. Returns true if the order changed.
create or replace function private.close_order(p_order_id uuid, p_status text, p_reason text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_ledger_id uuid;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or v_order.status <> 'pending' then
    return false;
  end if;

  if v_order.kind = 'ticket' then
    perform private.release_order_reservations(p_order_id);
  elsif v_order.kind = 'wallet_topup' then
    for v_ledger_id in
      select id from public.wallet_ledger
       where reference_type = 'order' and reference_id = p_order_id and status = 'pending'
    loop
      perform private.ledger_settle(v_ledger_id, false);
    end loop;
  end if;

  update public.orders set status = p_status, status_reason = p_reason where id = p_order_id;

  if p_status in ('failed', 'cancelled') then
    perform private.notify(v_order.user_id, 'payment_status',
      case when p_status = 'failed' then 'Payment failed' else 'Payment cancelled' end,
      'No money was taken for this order. You can try again.',
      v_order.event_id, jsonb_build_object('order_id', p_order_id, 'status', p_status));
  end if;
  perform private.audit('order_' || p_status, 'order', p_order_id, v_order.event_id,
                        jsonb_build_object('reason', p_reason), v_order.user_id);
  return true;
end;
$$;

-- Credit the full order amount to the buyer's wallet and mark it refunded.
create or replace function private.refund_order_to_wallet(p_order_id uuid, p_reason text, p_release_reservations boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if v_order.status = 'refunded' then
    return;
  end if;
  if p_release_reservations and v_order.kind = 'ticket' and v_order.status = 'pending' then
    perform private.release_order_reservations(p_order_id);
  end if;

  update public.orders
     set status = 'refunded', status_reason = p_reason, paid_at = coalesce(paid_at, now())
   where id = p_order_id;

  if v_order.user_id is not null then
    perform private.ledger_post(v_order.user_id, 'refund_credit', v_order.total_minor, 'order', p_order_id,
                                'Refund (' || p_reason || ')');
    perform private.notify(v_order.user_id, 'refund_status', 'Refund credited to your wallet',
      format('LKR %s was credited to your Zuno wallet.', to_char(v_order.total_minor / 100.0, 'FM999,999,990.00')),
      v_order.event_id, jsonb_build_object('order_id', p_order_id, 'amount_minor', v_order.total_minor, 'reason', p_reason));
  end if;
  perform private.audit('order_refunded', 'order', p_order_id, v_order.event_id,
                        jsonb_build_object('reason', p_reason, 'amount_minor', v_order.total_minor), v_order.user_id);
end;
$$;

-- Expire stale pending orders of one event. Caller holds the event lock.
create or replace function private.expire_orders_for_event(p_event_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_count integer := 0;
begin
  for v_id in
    select id from public.orders
     where event_id = p_event_id and status = 'pending' and expires_at <= now()
     order by id
  loop
    if private.close_order(v_id, 'expired', 'hold_expired') then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_payment_order (SERVICE ROLE ONLY)
-- p_items: [{"tier_id": "...", "quantity": 2}] for kind = 'ticket'.
-- p_amount_minor: only used for kind = 'wallet_topup'; ignored otherwise
--   (ticket and creation-fee prices always come from the database).
-- p_answers: registration answers for ticket orders (validated now, stored on
--   the order, written to registration_answers when payment is verified).
-- ---------------------------------------------------------------------------
create or replace function public.create_payment_order(
  p_user_id uuid,
  p_kind text,
  p_event_id uuid,
  p_items jsonb,
  p_amount_minor bigint,
  p_idempotency_key text,
  p_answers jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
  v_existing public.orders;
  v_event public.events;
  v_order_id uuid;
  v_subtotal bigint := 0;
  v_commission bigint := 0;
  v_total bigint;
  v_expires timestamptz := now() + make_interval(mins => private.setting('order_hold_minutes')::integer);
  v_lines jsonb;
  v_line record;
  v_tier public.ticket_tiers;
  v_qty_total integer := 0;
  v_reserved_total integer;
  v_answers jsonb;
  v_owner uuid;
begin
  if p_user_id is null or not exists (select 1 from auth.users where id = p_user_id) then
    perform private.fail('user_not_found');
  end if;
  if v_key is null or char_length(v_key) not between 8 and 200 then
    perform private.fail('invalid_idempotency_key');
  end if;
  if p_kind is null or p_kind not in ('ticket', 'wallet_topup', 'event_creation_fee') then
    perform private.fail('invalid_kind');
  end if;

  -- Idempotent replay: same key returns the same order (no new reservation).
  select * into v_existing from public.orders where user_id = p_user_id and idempotency_key = v_key;
  if found then
    if v_existing.kind <> p_kind or v_existing.event_id is distinct from p_event_id then
      perform private.fail('idempotency_conflict');
    end if;
    return private.order_checkout_json(v_existing.id) || jsonb_build_object('replayed', true);
  end if;

  if p_kind = 'ticket' then
    -- Lock the event, then release this event's stale holds before pricing.
    select * into v_event from public.events where id = p_event_id for update;
    if not found or v_event.status in ('draft', 'pending_review') then
      perform private.fail('event_not_found');
    end if;
    if v_event.is_free then
      perform private.fail('not_paid_event');
    end if;
    if not private.registration_open(v_event) then
      perform private.fail('registration_closed');
    end if;
    perform private.expire_orders_for_event(p_event_id);

    -- Parse and normalise the requested lines.
    if p_items is null or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) not between 1 and 10 then
      perform private.fail('invalid_items');
    end if;
    begin
      select jsonb_agg(jsonb_build_object('tier_id', (x ->> 'tier_id')::uuid, 'quantity', (x ->> 'quantity')::integer))
        into v_lines
        from jsonb_array_elements(p_items) x;
    exception when others then
      perform private.fail('invalid_items');
    end;
    if exists (select 1 from jsonb_array_elements(v_lines) l
               where l ->> 'tier_id' is null or (l ->> 'quantity') is null or (l ->> 'quantity')::integer < 1)
       or (select count(distinct l ->> 'tier_id') from jsonb_array_elements(v_lines) l) <> jsonb_array_length(v_lines) then
      perform private.fail('invalid_items');
    end if;

    -- Lock tiers in id order (deterministic lock order across transactions).
    for v_line in
      select (l ->> 'tier_id')::uuid as tier_id, (l ->> 'quantity')::integer as quantity
        from jsonb_array_elements(v_lines) l
       order by 1
    loop
      select * into v_tier from public.ticket_tiers where id = v_line.tier_id and event_id = p_event_id for update;
      if not found then
        perform private.fail('invalid_items');
      end if;
      if (v_tier.sales_start_at is not null and v_tier.sales_start_at > now())
         or (v_tier.sales_end_at is not null and v_tier.sales_end_at <= now()) then
        perform private.fail('tier_not_on_sale');
      end if;
      if v_line.quantity > v_tier.max_per_order then
        perform private.fail('max_per_order_exceeded');
      end if;
      if v_tier.sold + v_tier.reserved + v_line.quantity > v_tier.quantity then
        perform private.fail('sold_out');
      end if;
      v_subtotal := v_subtotal + v_tier.price_minor * v_line.quantity;
      v_qty_total := v_qty_total + v_line.quantity;
    end loop;

    -- Event-level capacity across all tiers (sold seats + live reservations).
    select coalesce(sum(reserved), 0)::integer into v_reserved_total from public.ticket_tiers where event_id = p_event_id;
    if v_event.seats_taken + v_reserved_total + v_qty_total > v_event.capacity then
      perform private.fail('sold_out');
    end if;
    if v_subtotal <= 0 then
      perform private.fail('invalid_items');
    end if;

    -- Answers are required only for the first registration on this event.
    if exists (select 1 from public.registrations
               where event_id = p_event_id and user_id = p_user_id and status in ('confirmed', 'waitlisted', 'offered')) then
      v_answers := null;
    else
      v_answers := private.validate_answers(p_event_id, p_answers);
    end if;

    v_commission := (v_subtotal * private.setting('commission_bps') + 5000) / 10000;
    v_total := v_subtotal;

    insert into public.orders (user_id, event_id, kind, status, subtotal_minor, commission_minor, total_minor,
                               idempotency_key, answers, expires_at)
    values (p_user_id, p_event_id, 'ticket', 'pending', v_subtotal, v_commission, v_total, v_key, v_answers, v_expires)
    returning id into v_order_id;

    insert into public.order_items (order_id, tier_id, quantity, unit_price_minor)
    select v_order_id, (l ->> 'tier_id')::uuid, (l ->> 'quantity')::integer, t.price_minor
      from jsonb_array_elements(v_lines) l
      join public.ticket_tiers t on t.id = (l ->> 'tier_id')::uuid;

    -- Reserve inventory: sold + reserved <= quantity is enforced by a CHECK.
    update public.ticket_tiers t
       set reserved = t.reserved + (l ->> 'quantity')::integer
      from jsonb_array_elements(v_lines) l
     where t.id = (l ->> 'tier_id')::uuid;

  elsif p_kind = 'wallet_topup' then
    if p_event_id is not null then
      perform private.fail('invalid_request');
    end if;
    if p_amount_minor is null
       or p_amount_minor < private.setting('wallet_topup_min_minor')
       or p_amount_minor > private.setting('wallet_topup_max_minor') then
      perform private.fail('invalid_amount');
    end if;
    v_subtotal := p_amount_minor;
    v_total := p_amount_minor;

    insert into public.orders (user_id, event_id, kind, status, subtotal_minor, commission_minor, total_minor,
                               idempotency_key, expires_at)
    values (p_user_id, null, 'wallet_topup', 'pending', v_subtotal, 0, v_total, v_key, v_expires)
    returning id into v_order_id;

    -- Pending ledger credit; posted only after a verified PayHere notification.
    perform private.ledger_add_pending(p_user_id, 'topup', v_total, 'order', v_order_id, 'Wallet top-up');

  else -- event_creation_fee
    select * into v_event from public.events where id = p_event_id for update;
    if not found then
      perform private.fail('event_not_found');
    end if;
    select owner_id into v_owner from public.organizer_profiles where id = v_event.organizer_id;
    if v_owner is distinct from p_user_id then
      perform private.fail('not_owner');
    end if;
    if v_event.creation_fee_paid_at is not null then
      perform private.fail('creation_fee_already_paid');
    end if;
    if v_event.status not in ('draft', 'pending_review') then
      perform private.fail('event_not_editable');
    end if;
    v_subtotal := private.setting('event_creation_fee_minor');
    v_total := v_subtotal;

    insert into public.orders (user_id, event_id, kind, status, subtotal_minor, commission_minor, total_minor,
                               idempotency_key, expires_at)
    values (p_user_id, p_event_id, 'event_creation_fee', 'pending', v_subtotal, 0, v_total, v_key, v_expires)
    returning id into v_order_id;
  end if;

  perform private.audit('order_created', 'order', v_order_id, p_event_id,
                        jsonb_build_object('kind', p_kind, 'total_minor', v_total), p_user_id);
  return private.order_checkout_json(v_order_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Fulfilment after a VERIFIED successful payment. Caller holds event + order
-- locks. p_late = the order had already expired/failed (reservation released).
-- Returns an outcome code recorded on the payments row.
-- ---------------------------------------------------------------------------
create or replace function private.fulfil_ticket_order(p_order public.orders, p_late boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.events;
  v_qty_total integer;
  v_reserved_total integer;
  v_reg_id uuid;
  v_line record;
  v_ticket_ids uuid[] := '{}';
begin
  select * into v_event from public.events where id = p_order.event_id;
  if v_event.status <> 'published' or now() >= v_event.ends_at then
    perform private.refund_order_to_wallet(p_order.id, 'event_unavailable', not p_late);
    return 'refunded_event_unavailable';
  end if;

  perform 1 from public.ticket_tiers t
   where t.id in (select tier_id from public.order_items where order_id = p_order.id)
   order by t.id
   for update;
  select coalesce(sum(quantity), 0)::integer into v_qty_total from public.order_items where order_id = p_order.id;

  if p_late then
    -- The hold was released: the seats must still be available.
    select coalesce(sum(reserved), 0)::integer into v_reserved_total from public.ticket_tiers where event_id = v_event.id;
    if exists (
         select 1 from public.order_items i join public.ticket_tiers t on t.id = i.tier_id
          where i.order_id = p_order.id and t.sold + t.reserved + i.quantity > t.quantity)
       or v_event.seats_taken + v_reserved_total + v_qty_total > v_event.capacity then
      perform private.refund_order_to_wallet(p_order.id, 'sold_out_after_expiry', false);
      return 'refunded_sold_out';
    end if;
    update public.ticket_tiers t
       set sold = t.sold + i.quantity
      from public.order_items i
     where i.order_id = p_order.id and t.id = i.tier_id;
  else
    -- Convert the reservation into sales.
    update public.ticket_tiers t
       set reserved = t.reserved - i.quantity, sold = t.sold + i.quantity
      from public.order_items i
     where i.order_id = p_order.id and t.id = i.tier_id;
  end if;

  update public.events set seats_taken = seats_taken + v_qty_total where id = v_event.id;

  -- One active registration per user/event: repeat purchases add tickets to it.
  select id into v_reg_id
    from public.registrations
   where event_id = v_event.id and user_id = p_order.user_id and status in ('confirmed', 'waitlisted', 'offered')
   for update;
  if not found then
    insert into public.registrations (event_id, user_id, status, kind, order_id, reference)
    values (v_event.id, p_order.user_id, 'confirmed', 'paid', p_order.id, private.generate_registration_reference())
    returning id into v_reg_id;
    if p_order.answers is not null then
      insert into public.registration_answers (registration_id, question_id, value)
      select v_reg_id, (a ->> 'question_id')::uuid, a -> 'value'
        from jsonb_array_elements(p_order.answers) a
       where exists (select 1 from public.registration_questions q where q.id = (a ->> 'question_id')::uuid)
      on conflict (registration_id, question_id) do nothing;
    end if;
  else
    update public.registrations set status = 'confirmed', offer_expires_at = null where id = v_reg_id;
  end if;

  -- One ticket per unit of quantity.
  for v_line in select tier_id, quantity from public.order_items where order_id = p_order.id order by tier_id loop
    for i in 1 .. v_line.quantity loop
      v_ticket_ids := v_ticket_ids || private.issue_ticket(v_reg_id, v_event.id, p_order.user_id, v_line.tier_id, p_order.id);
    end loop;
  end loop;

  update public.orders set status = 'paid', paid_at = now(), status_reason = null where id = p_order.id;

  perform private.notify(p_order.user_id, 'payment_status', 'Payment received',
    format('LKR %s paid for %s.', to_char(p_order.total_minor / 100.0, 'FM999,999,990.00'), v_event.title),
    v_event.id, jsonb_build_object('order_id', p_order.id, 'status', 'paid'));
  perform private.notify(p_order.user_id, 'ticket_issued',
    case when v_qty_total = 1 then 'Your ticket is ready' else format('Your %s tickets are ready', v_qty_total) end,
    v_event.title, v_event.id,
    jsonb_build_object('order_id', p_order.id, 'registration_id', v_reg_id, 'ticket_ids', to_jsonb(v_ticket_ids)));
  return 'paid';
end;
$$;

create or replace function private.fulfil_order(p_order public.orders, p_late boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ledger_id uuid;
  v_event public.events;
begin
  if p_order.user_id is null then
    -- The buyer deleted their account before PayHere confirmed: keep the money
    -- traceable for a manual refund.
    update public.orders set status = 'paid', paid_at = now(), status_reason = 'user_deleted' where id = p_order.id;
    return 'paid_user_deleted_manual_refund';
  end if;

  if p_order.kind = 'ticket' then
    return private.fulfil_ticket_order(p_order, p_late);

  elsif p_order.kind = 'wallet_topup' then
    select id into v_ledger_id
      from public.wallet_ledger
     where reference_type = 'order' and reference_id = p_order.id and status = 'pending' and entry_type = 'topup'
     limit 1;
    if found then
      perform private.ledger_settle(v_ledger_id, true);   -- pending -> posted (balance applied)
    else
      perform private.ledger_post(p_order.user_id, 'topup', p_order.total_minor, 'order', p_order.id, 'Wallet top-up');
    end if;
    update public.orders set status = 'paid', paid_at = now(), status_reason = null where id = p_order.id;
    perform private.notify(p_order.user_id, 'payment_status', 'Wallet topped up',
      format('LKR %s was added to your Zuno wallet.', to_char(p_order.total_minor / 100.0, 'FM999,999,990.00')),
      null, jsonb_build_object('order_id', p_order.id, 'status', 'paid'));
    return 'paid';

  else -- event_creation_fee
    select * into v_event from public.events where id = p_order.event_id;
    if v_event.creation_fee_paid_at is not null then
      -- Already paid through another order: credit this payment back.
      perform private.refund_order_to_wallet(p_order.id, 'creation_fee_already_paid', false);
      return 'refunded_duplicate_fee';
    end if;
    update public.events set creation_fee_paid_at = now() where id = p_order.event_id;
    update public.orders set status = 'paid', paid_at = now(), status_reason = null where id = p_order.id;
    perform private.notify(p_order.user_id, 'payment_status', 'Event creation fee paid',
      v_event.title || ' can now be submitted for publishing.', v_event.id,
      jsonb_build_object('order_id', p_order.id, 'status', 'paid'));
    return 'paid';
  end if;
end;
$$;

-- Chargeback (-3) on a paid order.
create or replace function private.handle_chargeback(p_order public.orders)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ticket record;
  v_revoked integer := 0;
begin
  if p_order.status <> 'paid' then
    return 'chargeback_ignored_' || p_order.status;
  end if;
  if p_order.kind <> 'ticket' then
    update public.orders set status_reason = 'chargeback' where id = p_order.id;
    perform private.audit('chargeback_manual_review', 'order', p_order.id, p_order.event_id, '{}'::jsonb, p_order.user_id);
    return 'chargeback_manual_review';
  end if;

  for v_ticket in
    update public.tickets set status = 'refunded', cancelled_at = now()
     where order_id = p_order.id and status in ('valid', 'checked_in')
    returning id, tier_id, registration_id
  loop
    update public.ticket_tiers set sold = greatest(sold - 1, 0) where id = v_ticket.tier_id;
    v_revoked := v_revoked + 1;
  end loop;
  update public.events set seats_taken = greatest(seats_taken - v_revoked, 0) where id = p_order.event_id;
  update public.registrations r
     set status = 'cancelled', cancelled_at = now(), cancellation_reason = 'chargeback'
   where r.event_id = p_order.event_id and r.user_id = p_order.user_id and r.status = 'confirmed'
     and not exists (select 1 from public.tickets t where t.registration_id = r.id and t.status in ('valid', 'checked_in'));
  update public.orders set status = 'refunded', status_reason = 'chargeback' where id = p_order.id;
  perform private.notify(p_order.user_id, 'refund_status', 'Payment reversed',
    'Your bank reversed this payment, so the related tickets are no longer valid.',
    p_order.event_id, jsonb_build_object('order_id', p_order.id, 'status', 'refunded'));
  return 'chargeback_tickets_revoked';
end;
$$;

-- ---------------------------------------------------------------------------
-- apply_payhere_notification (SERVICE ROLE ONLY)
-- Called by payhere-notify AFTER md5sig verification. Idempotent: a repeated
-- (payment_id, status_code) pair is a no-op that reports the original outcome.
-- Amount and currency must equal the order's total exactly.
-- PayHere status codes: 2 success, 0 pending, -1 cancelled, -2 failed, -3 chargeback.
-- ---------------------------------------------------------------------------
create or replace function public.apply_payhere_notification(
  p_order_id uuid,
  p_payment_id text,
  p_status_code integer,
  p_amount_minor bigint,
  p_currency text,
  p_method text default null,
  p_notification jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id uuid;
  v_order public.orders;
  v_payment_id text;
  v_prior public.payments;
  v_outcome text;
  v_result text := 'applied';
begin
  if p_order_id is null then
    perform private.fail('order_not_found');
  end if;
  select event_id into v_event_id from public.orders where id = p_order_id;
  if not found then
    perform private.fail('order_not_found');
  end if;

  -- Global lock order: event row first, then the order row.
  if v_event_id is not null then
    perform 1 from public.events where id = v_event_id for update;
  end if;
  select * into v_order from public.orders where id = p_order_id for update;

  v_payment_id := left(coalesce(nullif(btrim(p_payment_id), ''), 'missing:' || p_order_id::text), 120);

  -- Duplicate callback: no-op (the unique constraint is the final backstop).
  select * into v_prior from public.payments where provider_payment_id = v_payment_id and status_code = p_status_code;
  if found then
    return jsonb_build_object('result', 'duplicate', 'outcome', v_prior.outcome,
                              'order_id', v_order.id, 'order_status', v_order.status);
  end if;

  if p_amount_minor is distinct from v_order.total_minor or upper(p_currency) is distinct from v_order.currency then
    v_outcome := 'rejected_amount_mismatch';
    v_result := 'rejected';
  elsif p_status_code = 2 then
    if v_order.status = 'pending' then
      v_outcome := private.fulfil_order(v_order, false);
    elsif v_order.status in ('expired', 'cancelled', 'failed') then
      v_outcome := private.fulfil_order(v_order, true);
    elsif v_order.status = 'paid' then
      v_outcome := 'already_paid_manual_review';
    else
      v_outcome := 'ignored_' || v_order.status;
    end if;
  elsif p_status_code = 0 then
    v_outcome := 'pending_recorded';
  elsif p_status_code in (-1, -2) then
    if v_order.status = 'pending' then
      perform private.close_order(v_order.id, case when p_status_code = -1 then 'cancelled' else 'failed' end,
                                  'payhere_status_' || p_status_code);
      v_outcome := case when p_status_code = -1 then 'order_cancelled' else 'order_failed' end;
    else
      v_outcome := 'ignored_' || v_order.status;
    end if;
  elsif p_status_code = -3 then
    v_outcome := private.handle_chargeback(v_order);
  else
    v_outcome := 'rejected_unknown_status';
    v_result := 'rejected';
  end if;

  insert into public.payments (order_id, provider_payment_id, status_code, amount_minor, currency, method, outcome, notification)
  values (v_order.id, v_payment_id, p_status_code, coalesce(p_amount_minor, 0),
          coalesce(nullif(left(upper(btrim(p_currency)), 3), ''), 'XXX'),
          left(p_method, 40), v_outcome, private.sanitize_payhere_notification(p_notification));

  perform private.audit('payhere_notification', 'order', v_order.id, v_order.event_id,
                        jsonb_build_object('status_code', p_status_code, 'outcome', v_outcome, 'payment_id', v_payment_id),
                        v_order.user_id);

  return jsonb_build_object('result', v_result, 'outcome', v_outcome, 'order_id', v_order.id,
                            'order_status', (select status from public.orders where id = v_order.id));
end;
$$;

-- ---------------------------------------------------------------------------
-- expire_stale_orders (SERVICE ROLE / pg_cron): releases reservations of
-- pending orders past expires_at, fails their pending ledger rows, releases
-- expired waitlist offers and prunes old rate-limit windows.
-- ---------------------------------------------------------------------------
create or replace function public.expire_stale_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rec record;
  v_count integer := 0;
begin
  for v_rec in
    select id, event_id from public.orders
     where status = 'pending' and expires_at <= now()
     order by expires_at, id
     limit 500
  loop
    if v_rec.event_id is not null then
      perform 1 from public.events where id = v_rec.event_id for update;
    end if;
    if private.close_order(v_rec.id, 'expired', 'hold_expired') then
      v_count := v_count + 1;
    end if;
  end loop;

  for v_rec in
    select distinct event_id from public.registrations where status = 'offered' and offer_expires_at <= now()
  loop
    perform 1 from public.events where id = v_rec.event_id for update;
    perform private.release_expired_offers(v_rec.event_id);
  end loop;

  delete from public.rate_limits where window_start < now() - interval '2 days';
  return v_count;
end;
$$;
