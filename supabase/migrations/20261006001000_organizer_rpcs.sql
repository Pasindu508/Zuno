-- =============================================================================
-- Zuno 1000: organizer RPCs (caller must own the organizer profile)
-- =============================================================================

-- Raises not_owner unless the current user owns the event's organizer.
-- (Unknown events also report not_owner, so event existence is not leaked.)
create or replace function private.assert_event_owner(p_event_id uuid, p_code text default 'not_owner')
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not private.is_event_owner(p_event_id) then
    perform private.fail(p_code);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- organizer_dashboard
-- ---------------------------------------------------------------------------
create or replace function public.organizer_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_org public.organizer_profiles;
begin
  select * into v_org from public.organizer_profiles where owner_id = v_uid;
  if not found then
    return jsonb_build_object(
      'organizer', null,
      'events', '[]'::jsonb,
      'totals', jsonb_build_object('gross_minor', 0, 'commission_minor', 0, 'net_minor', 0)
    );
  end if;

  return jsonb_build_object(
    'organizer', jsonb_build_object(
      'id', v_org.id,
      'owner_id', v_org.owner_id,
      'name', v_org.name,
      'slug', v_org.slug,
      'bio', v_org.bio,
      'logo_path', v_org.logo_path,
      'contact_email', v_org.contact_email,
      'verification_status', v_org.verification_status,
      'created_at', v_org.created_at
    ),
    'events', coalesce((
      select jsonb_agg(
        to_jsonb(c) || jsonb_build_object(
          'registrations', (select count(*) from public.registrations r
                             where r.event_id = c.id and r.status = 'confirmed'),
          'checked_in', (select count(*) from public.tickets t
                          where t.event_id = c.id and t.status = 'checked_in'),
          'creation_fee_paid', e.creation_fee_paid_at is not null
        ) order by c.starts_at desc, c.id)
      from public.event_cards c
      join public.events e on e.id = c.id
      where c.organizer_id = v_org.id
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'gross_minor', coalesce(sum(o.subtotal_minor), 0),
        'commission_minor', coalesce(sum(o.commission_minor), 0),
        'net_minor', coalesce(sum(o.subtotal_minor - o.commission_minor), 0))
      from public.orders o
      join public.events e on e.id = o.event_id
      where e.organizer_id = v_org.id and o.kind = 'ticket' and o.status = 'paid'
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- organizer_event_stats
-- ---------------------------------------------------------------------------
create or replace function public.organizer_event_stats(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_event public.events;
  v_money record;
begin
  perform private.require_user();
  perform private.assert_event_owner(p_event_id);
  select * into v_event from public.events where id = p_event_id;

  select coalesce(sum(o.subtotal_minor), 0) as gross,
         coalesce(sum(o.commission_minor), 0) as commission
    into v_money
    from public.orders o
   where o.event_id = p_event_id and o.kind = 'ticket' and o.status = 'paid';

  return jsonb_build_object(
    'event_id', v_event.id,
    'status', v_event.status,
    'capacity', v_event.capacity,
    'seats_taken', v_event.seats_taken,
    'registrations', (select count(*) from public.registrations where event_id = p_event_id and status = 'confirmed'),
    'waitlisted', (select count(*) from public.registrations where event_id = p_event_id and status = 'waitlisted'),
    'offered', (select count(*) from public.registrations where event_id = p_event_id and status = 'offered'),
    'checked_in', (select count(*) from public.tickets where event_id = p_event_id and status = 'checked_in'),
    'tickets_sold', (select count(*) from public.tickets
                      where event_id = p_event_id and order_id is not null and status in ('valid', 'checked_in')),
    'gross_minor', v_money.gross,
    'commission_minor', v_money.commission,
    'net_minor', v_money.gross - v_money.commission,
    'by_tier', coalesce((
      select jsonb_agg(jsonb_build_object(
          'tier_id', t.id,
          'name', t.name,
          'sold', t.sold,
          'reserved', t.reserved,
          'quantity', t.quantity,
          'gross_minor', coalesce((
            select sum(i.quantity * i.unit_price_minor)
              from public.order_items i join public.orders o on o.id = i.order_id
             where i.tier_id = t.id and o.status = 'paid'), 0)
        ) order by t.sort_order, t.id)
      from public.ticket_tiers t
      where t.event_id = p_event_id
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- organizer_attendees (no emails, no NIC data, no answers)
-- ---------------------------------------------------------------------------
create or replace function public.organizer_attendees(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_user();
  perform private.assert_event_owner(p_event_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'ticket_id', t.id,
        'attendee_name', t.attendee_name,
        'tier_name', coalesce(tt.name, 'General admission'),
        'status', t.status,
        'checked_in_at', t.checked_in_at,
        'registration_reference', r.reference
      ) order by t.attendee_name nulls last, t.issued_at, t.id)
    from public.tickets t
    join public.registrations r on r.id = t.registration_id
    left join public.ticket_tiers tt on tt.id = t.tier_id
    where t.event_id = p_event_id
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- organizer_settlements: per event gross / commission / net and payout status
-- ---------------------------------------------------------------------------
create or replace function public.organizer_settlements()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'event_id', e.id,
        'title', e.title,
        'starts_at', e.starts_at,
        'event_status', e.status,
        'gross_minor', m.gross,
        'commission_minor', m.commission,
        'net_minor', m.gross - m.commission,
        'currency', 'LKR',
        'payout_status', coalesce(s.status, 'unsettled'),
        'scheduled_for', s.scheduled_for,
        'paid_at', s.paid_at
      ) order by e.starts_at desc, e.id)
    from public.events e
    join public.organizer_profiles op on op.id = e.organizer_id
    left join public.event_settlements s on s.event_id = e.id
    cross join lateral (
      select coalesce(sum(o.subtotal_minor), 0) as gross, coalesce(sum(o.commission_minor), 0) as commission
        from public.orders o
       where o.event_id = e.id and o.kind = 'ticket' and o.status = 'paid'
    ) m
    where op.owner_id = v_uid and not e.is_free and e.status <> 'draft'
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- submit_event_for_publish
-- ---------------------------------------------------------------------------
create or replace function public.submit_event_for_publish(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_event public.events;
  v_org public.organizer_profiles;
  v_fields text[] := '{}';
begin
  select * into v_event from public.events where id = p_event_id for update;
  if not found then
    perform private.fail('not_owner');
  end if;
  select * into v_org from public.organizer_profiles where id = v_event.organizer_id;
  if v_org.owner_id is distinct from v_uid then
    perform private.fail('not_owner');
  end if;
  if v_org.verification_status <> 'verified' then
    perform private.fail('organizer_not_verified');
  end if;

  if v_event.status not in ('draft', 'pending_review') then
    v_fields := v_fields || 'status'::text;
  end if;
  if char_length(btrim(v_event.title)) < 3 then
    v_fields := v_fields || 'title'::text;
  end if;
  if char_length(btrim(v_event.summary)) < 20 then
    v_fields := v_fields || 'summary'::text;
  end if;
  if v_event.starts_at <= now() then
    v_fields := v_fields || 'starts_at'::text;
  end if;
  if v_event.ends_at <= v_event.starts_at then
    v_fields := v_fields || 'ends_at'::text;
  end if;
  if v_event.capacity <= 0 then
    v_fields := v_fields || 'capacity'::text;
  end if;
  if v_event.cover_path is null then
    v_fields := v_fields || 'cover_path'::text;
  end if;
  if v_event.format = 'physical' and v_event.venue_id is null then
    v_fields := v_fields || 'venue_id'::text;
  elsif v_event.format = 'online' and v_event.online_url is null then
    v_fields := v_fields || 'online_url'::text;
  elsif v_event.format = 'hybrid' and v_event.venue_id is null and v_event.online_url is null then
    v_fields := v_fields || 'venue_id'::text;
  end if;
  if v_event.registration_closes_at is not null and v_event.registration_closes_at <= now() then
    v_fields := v_fields || 'registration_closes_at'::text;
  end if;
  if not v_event.is_free and not exists (
       select 1 from public.ticket_tiers t
        where t.event_id = p_event_id and t.quantity > 0 and t.price_minor > 0
          and (t.sales_end_at is null or t.sales_end_at > now())) then
    v_fields := v_fields || 'ticket_tiers'::text;
  end if;
  if v_event.is_free and exists (select 1 from public.ticket_tiers t where t.event_id = p_event_id and t.price_minor > 0) then
    v_fields := v_fields || 'ticket_tiers'::text;
  end if;

  if cardinality(v_fields) > 0 then
    perform private.fail('validation_failed', array_to_string(v_fields, ','));
  end if;
  if v_event.creation_fee_paid_at is null then
    perform private.fail('creation_fee_unpaid');
  end if;

  update public.events set status = 'published', published_at = now() where id = p_event_id;
  insert into public.event_settlements (event_id) values (p_event_id) on conflict (event_id) do nothing;
  perform private.audit('event_published', 'event', p_event_id, p_event_id, '{}'::jsonb);

  return jsonb_build_object('event_id', p_event_id, 'status', 'published',
                            'published_at', (select published_at from public.events where id = p_event_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- send_event_update: fan out to confirmed registrants. Returns recipients.
-- ---------------------------------------------------------------------------
create or replace function public.send_event_update(p_event_id uuid, p_kind text, p_message text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_event public.events;
  v_org_name text;
  v_message text := btrim(coalesce(p_message, ''));
  v_kind text;
  v_title text;
  v_count integer;
begin
  perform private.assert_event_owner(p_event_id);
  if p_kind is null or p_kind not in ('venue_change', 'schedule_change', 'general') then
    perform private.fail('invalid_kind');
  end if;
  if char_length(v_message) not between 1 and 1000 then
    perform private.fail('invalid_message');
  end if;
  select * into v_event from public.events where id = p_event_id;
  if v_event.status <> 'published' then
    perform private.fail('event_not_published');
  end if;
  if not public.rate_limit_hit('event_update:' || p_event_id::text, 10, 3600) then
    perform private.fail('rate_limited');
  end if;

  select name into v_org_name from public.organizer_profiles where id = v_event.organizer_id;
  v_kind := case p_kind when 'general' then 'organizer_update' else p_kind end;
  v_title := case p_kind
    when 'venue_change' then 'Venue update: ' || v_event.title
    when 'schedule_change' then 'Schedule update: ' || v_event.title
    else 'Update from ' || v_org_name
  end;

  insert into public.notifications (user_id, kind, title, body, event_id, data)
  select distinct r.user_id, v_kind, left(v_title, 200), v_message, p_event_id,
         jsonb_build_object('update_kind', p_kind)
    from public.registrations r
   where r.event_id = p_event_id and r.status = 'confirmed' and r.user_id is not null;
  get diagnostics v_count = row_count;

  insert into public.event_updates (event_id, kind, message, recipients, sent_by)
  values (p_event_id, p_kind, v_message, v_count, v_uid);
  perform private.audit('event_update_sent', 'event', p_event_id, p_event_id,
                        jsonb_build_object('kind', p_kind, 'recipients', v_count));
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- cancel_event: cancels registrations and tickets, credits refunds to wallets
-- (extra free-registration fees and paid ticket orders) and notifies.
-- Wallet rows are locked in user_id order to avoid deadlocks between
-- concurrent cancellations.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_event(p_event_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_event public.events;
  v_reason text := left(btrim(coalesce(p_reason, '')), 500);
  v_users uuid[];
  v_order_id uuid;
  v_refund record;
  v_refunds integer := 0;
  v_refund_total bigint := 0;
  v_cancelled integer;
begin
  perform private.assert_event_owner(p_event_id);
  select * into v_event from public.events where id = p_event_id for update;

  if v_event.status = 'cancelled' then
    return jsonb_build_object('event_id', p_event_id, 'status', 'cancelled', 'registrations_cancelled', 0,
                              'refunds_issued', 0, 'refund_total_minor', 0, 'notified', 0);
  end if;
  if v_event.status = 'completed' or now() >= v_event.ends_at then
    perform private.fail('event_completed');
  end if;

  update public.events
     set status = 'cancelled', cancelled_at = now(), cancellation_reason = nullif(v_reason, '')
   where id = p_event_id;

  -- Pending checkouts: release their reservations. (A late successful
  -- payment for them is refunded to the wallet by apply_payhere_notification.)
  for v_order_id in
    select id from public.orders where event_id = p_event_id and status = 'pending' order by id
  loop
    perform private.close_order(v_order_id, 'cancelled', 'event_cancelled');
  end loop;

  select array_agg(distinct user_id) into v_users
    from public.registrations
   where event_id = p_event_id and status in ('confirmed', 'waitlisted', 'offered') and user_id is not null;

  -- Refunds, ordered by user so wallet locks are taken in a stable order.
  for v_refund in
    select 'registration'::text as source, r.id, r.user_id, r.fee_minor as amount
      from public.registrations r
     where r.event_id = p_event_id and r.kind = 'free' and r.status = 'confirmed'
       and r.fee_minor > 0 and r.user_id is not null
    union all
    select 'order'::text, o.id, o.user_id, o.total_minor
      from public.orders o
     where o.event_id = p_event_id and o.kind = 'ticket' and o.status = 'paid'
    order by 3, 1, 2
  loop
    if v_refund.source = 'registration' then
      perform private.ledger_post(v_refund.user_id, 'refund_credit', v_refund.amount, 'registration', v_refund.id,
                                  'Refund: ' || v_event.title || ' was cancelled');
      perform private.notify(v_refund.user_id, 'refund_status', 'Refund credited to your wallet',
        format('LKR %s for %s was credited to your wallet.', to_char(v_refund.amount / 100.0, 'FM999,999,990.00'), v_event.title),
        p_event_id, jsonb_build_object('registration_id', v_refund.id, 'amount_minor', v_refund.amount));
    else
      perform private.refund_order_to_wallet(v_refund.id, 'event_cancelled', false);
    end if;
    v_refunds := v_refunds + 1;
    v_refund_total := v_refund_total + v_refund.amount;
  end loop;

  -- Free registrations that used the monthly allowance get it back.
  update public.allowance_usage a
     set used = greatest(a.used - x.n, 0)
    from (
      select user_id, allowance_month, count(*)::integer as n
        from public.registrations
       where event_id = p_event_id and kind = 'free' and status = 'confirmed'
         and used_allowance and user_id is not null
       group by user_id, allowance_month
    ) x
   where a.user_id = x.user_id and a.month = x.allowance_month;

  update public.registrations
     set status = 'cancelled', cancelled_at = now(), cancellation_reason = 'event_cancelled'
   where event_id = p_event_id and status in ('confirmed', 'waitlisted', 'offered');
  get diagnostics v_cancelled = row_count;

  update public.tickets
     set status = case when order_id is null then 'cancelled' else 'refunded' end,
         cancelled_at = now()
   where event_id = p_event_id
     and (status = 'valid' or (status = 'checked_in' and order_id is not null));

  insert into public.notifications (user_id, kind, title, body, event_id, data)
  select u, 'event_cancelled', left(v_event.title || ' was cancelled', 200),
         coalesce(nullif(v_reason, ''), 'The organizer cancelled this event.'),
         p_event_id, jsonb_build_object('event_id', p_event_id)
    from unnest(coalesce(v_users, '{}')) as u;

  perform private.audit('event_cancelled', 'event', p_event_id, p_event_id,
                        jsonb_build_object('registrations_cancelled', v_cancelled, 'refunds', v_refunds,
                                           'refund_total_minor', v_refund_total));

  return jsonb_build_object(
    'event_id', p_event_id,
    'status', 'cancelled',
    'registrations_cancelled', v_cancelled,
    'refunds_issued', v_refunds,
    'refund_total_minor', v_refund_total,
    'notified', coalesce(cardinality(v_users), 0)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- check_in_ticket: atomic single-use transition valid -> checked_in.
-- p_code: "zuno:t:<token>" or the manual code (case/dash/space-insensitive,
-- Crockford aliases O->0, I/L->1 accepted, "ZN" prefix optional).
-- ---------------------------------------------------------------------------
create or replace function public.check_in_ticket(p_event_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_raw text := btrim(coalesce(p_code, ''));
  v_norm text;
  v_method text;
  v_ticket public.tickets;
  v_result text;
  v_tier_name text;
  v_at timestamptz;
begin
  if v_uid is null or not private.is_event_owner(p_event_id) then
    perform private.fail('not_authorized');
  end if;
  if not public.rate_limit_hit('check_in:' || v_uid::text, 120, 60) then
    perform private.fail('rate_limited');
  end if;

  if lower(left(v_raw, 7)) = 'zuno:t:' then
    v_method := 'qr';
    select * into v_ticket from public.tickets where qr_token = substr(v_raw, 8);
  else
    v_method := 'code';
    v_norm := translate(upper(regexp_replace(v_raw, '[[:space:]-]', '', 'g')), 'OIL', '011');
    if char_length(v_norm) = 10 and left(v_norm, 2) = 'ZN' then
      v_norm := substr(v_norm, 3);
    end if;
    if v_norm ~ '^[0-9A-HJKMNP-TV-Z]{8}$' then
      select * into v_ticket from public.tickets
       where code = 'ZN-' || substr(v_norm, 1, 4) || '-' || substr(v_norm, 5, 4);
    end if;
  end if;

  if v_ticket.id is null then
    v_result := 'invalid';
  elsif v_ticket.event_id <> p_event_id then
    v_result := 'wrong_event';
  elsif v_ticket.status = 'cancelled' then
    v_result := 'cancelled';
  elsif v_ticket.status = 'refunded' then
    v_result := 'refunded';
  elsif v_ticket.status = 'checked_in' then
    v_result := 'already_used';
  else
    -- The WHERE status = 'valid' guard makes the transition single-use even
    -- under concurrent scans (the loser re-reads and reports already_used).
    update public.tickets
       set status = 'checked_in', checked_in_at = now()
     where id = v_ticket.id and status = 'valid'
    returning checked_in_at into v_at;
    if found then
      insert into public.check_ins (ticket_id, event_id, checked_in_by, checked_in_at)
      values (v_ticket.id, p_event_id, v_uid, v_at);
      v_result := 'valid';
      v_ticket.checked_in_at := v_at;
    else
      select * into v_ticket from public.tickets where id = v_ticket.id;
      v_result := 'already_used';
    end if;
  end if;

  perform private.audit('check_in_attempt', 'ticket', v_ticket.id, p_event_id,
                        jsonb_build_object('result', v_result, 'method', v_method));

  if v_result in ('invalid', 'wrong_event') then
    return jsonb_build_object('result', v_result, 'attendee_name', null, 'tier_name', null, 'checked_in_at', null);
  end if;

  select coalesce(tt.name, 'General admission') into v_tier_name
    from public.tickets t left join public.ticket_tiers tt on tt.id = t.tier_id
   where t.id = v_ticket.id;
  return jsonb_build_object(
    'result', v_result,
    'attendee_name', v_ticket.attendee_name,
    'tier_name', v_tier_name,
    'checked_in_at', v_ticket.checked_in_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- organizer_export_data (SERVICE ROLE ONLY; used by organizer-export)
-- ---------------------------------------------------------------------------
create or replace function public.organizer_export_data(p_user_id uuid, p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.events;
  v_owner uuid;
begin
  select * into v_event from public.events where id = p_event_id;
  if not found then
    perform private.fail('not_owner');
  end if;
  select owner_id into v_owner from public.organizer_profiles where id = v_event.organizer_id;
  if p_user_id is null or v_owner is distinct from p_user_id then
    perform private.fail('not_owner');
  end if;

  perform private.audit('attendee_export', 'event', p_event_id, p_event_id, '{}'::jsonb, p_user_id);

  return jsonb_build_object(
    'event_id', v_event.id,
    'event_title', v_event.title,
    'questions', coalesce((
      select jsonb_agg(jsonb_build_object('id', q.id, 'prompt', q.prompt, 'kind', q.kind) order by q.sort_order, q.id)
      from public.registration_questions q where q.event_id = p_event_id
    ), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
          'reference', r.reference,
          'attendee_name', t.attendee_name,
          'tier_name', coalesce(tt.name, 'General admission'),
          'status', t.status,
          'checked_in_at', t.checked_in_at,
          'answers', coalesce((
            select jsonb_object_agg(a.question_id::text, a.value)
              from public.registration_answers a where a.registration_id = r.id
          ), '{}'::jsonb)
        ) order by r.reference, t.issued_at, t.id)
      from public.tickets t
      join public.registrations r on r.id = t.registration_id
      left join public.ticket_tiers tt on tt.id = t.tier_id
      where t.event_id = p_event_id
    ), '[]'::jsonb)
  );
end;
$$;
