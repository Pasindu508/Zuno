-- 050: check-in transitions, code normalisation, authorisation, rate limiting, audit
begin;

create temporary table t_ctx (key text primary key, id uuid, txt text) on commit drop;
grant all on t_ctx to anon, authenticated, service_role;

do $$
declare
  v_owner uuid := tests.new_user('owner');
  v_other_owner uuid := tests.new_user('otherowner');
  v_org uuid := tests.new_organizer(v_owner, true);
  v_ev uuid := tests.new_event(v_org, true, 50);
  v_ev2 uuid := tests.new_event(v_org, true, 50);
  v_u uuid := tests.new_user('guest');
  v_u2 uuid := tests.new_user('guest2');
  v_u3 uuid := tests.new_user('guest3');
  v_res jsonb;
begin
  perform tests.new_organizer(v_other_owner, true);
  perform tests.as_user(v_u);
  v_res := public.register_for_free_event(v_ev, '[]', 0, 'chk-key-0001');
  insert into t_ctx values ('t1', (v_res ->> 'ticket_id')::uuid, null), ('r1', (v_res ->> 'registration_id')::uuid, null);
  v_res := public.register_for_free_event(v_ev2, '[]', 0, 'chk-key-0002');
  insert into t_ctx values ('t_ev2', (v_res ->> 'ticket_id')::uuid, null);
  perform tests.as_user(v_u2);
  v_res := public.register_for_free_event(v_ev, '[]', 0, 'chk-key-0003');
  insert into t_ctx values ('t2', (v_res ->> 'ticket_id')::uuid, null), ('r2', (v_res ->> 'registration_id')::uuid, null);
  perform tests.as_user(v_u3);
  v_res := public.register_for_free_event(v_ev, '[]', 0, 'chk-key-0004');
  insert into t_ctx values ('t3', (v_res ->> 'ticket_id')::uuid, null);
  perform tests.as_postgres();
  insert into t_ctx values ('owner', v_owner, null), ('other_owner', v_other_owner, null), ('ev', v_ev, null),
    ('u', v_u, null), ('u2', v_u2, null);
end
$$;

do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_ev uuid := (select id from t_ctx where key = 'ev');
  v_t1 uuid := (select id from t_ctx where key = 't1');
  v_t2 uuid := (select id from t_ctx where key = 't2');
  v_t3 uuid := (select id from t_ctx where key = 't3');
  v_qr text;
  v_code text;
  v_code3 text;
  v_qr_ev2 text;
  v_res jsonb;
begin
  select 'zuno:t:' || qr_token into v_qr from public.tickets where id = v_t1;
  select 'zuno:t:' || qr_token into v_qr_ev2 from public.tickets where id = (select id from t_ctx where key = 't_ev2');
  select code into v_code from public.tickets where id = v_t2;
  select code into v_code3 from public.tickets where id = v_t3;

  -- QR payload from my_tickets matches what the scanner accepts.
  perform tests.as_user((select id from t_ctx where key = 'u'));
  perform tests.ok(exists (select 1 from jsonb_array_elements(public.my_tickets()) t where t ->> 'qr_payload' = v_qr),
                   'my_tickets exposes qr_payload zuno:t:<token>');

  perform tests.as_user(v_owner);
  v_res := public.check_in_ticket(v_ev, v_qr);
  perform tests.is(v_res ->> 'result', 'valid', 'first QR scan is valid');
  perform tests.is(v_res ->> 'attendee_name', 'Guest', 'valid scan returns the attendee name');
  perform tests.is(v_res ->> 'tier_name', 'General admission', 'free ticket tier name');
  perform tests.ok((v_res ->> 'checked_in_at') is not null, 'valid scan returns checked_in_at');
  v_res := public.check_in_ticket(v_ev, v_qr);
  perform tests.is(v_res ->> 'result', 'already_used', 'second scan of the same ticket is already_used');

  -- Manual code: case-, dash- and space-insensitive, optional ZN prefix, Crockford aliases.
  v_res := public.check_in_ticket(v_ev, lower(replace(v_code, '-', ' ')));
  perform tests.is(v_res ->> 'result', 'valid', 'manual code is case/dash-insensitive');
  v_res := public.check_in_ticket(v_ev, v_code);
  perform tests.is(v_res ->> 'result', 'already_used', 'manual code scanned twice is already_used');
  v_res := public.check_in_ticket(v_ev, translate(substr(v_code3, 4), '01-', 'OI'));
  perform tests.is(v_res ->> 'result', 'valid', 'code without ZN prefix and with O/I aliases is accepted');

  v_res := public.check_in_ticket(v_ev, 'zuno:t:' || repeat('A', 43));
  perform tests.is(v_res ->> 'result', 'invalid', 'unknown QR token is invalid');
  v_res := public.check_in_ticket(v_ev, 'not a code');
  perform tests.is(v_res ->> 'result', 'invalid', 'garbage input is invalid');
  perform tests.is(v_res ->> 'attendee_name', null::text, 'invalid scans reveal no attendee data');

  v_res := public.check_in_ticket(v_ev, v_qr_ev2);
  perform tests.is(v_res ->> 'result', 'wrong_event', 'ticket for another event is wrong_event');
  perform tests.is(v_res ->> 'attendee_name', null::text, 'wrong_event reveals no attendee data');
  perform tests.as_postgres();
  perform tests.is((select status from public.tickets where id = (select id from t_ctx where key = 't_ev2')), 'valid',
                   'wrong_event scan does not consume the ticket');
  perform tests.is((select count(*)::int from public.check_ins where event_id = v_ev), 3, 'one check_ins row per successful scan');
  perform tests.throws_state(format('insert into public.check_ins (ticket_id, event_id) values (%L, %L)', v_t1, v_ev), '23505',
                             'check_ins.ticket_id is unique (single use backstop)');
end
$$;

-- Cancelled and refunded tickets
do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_ev uuid := (select id from t_ctx where key = 'ev');
  v_org uuid := (select organizer_id from public.events where id = (select id from t_ctx where key = 'ev'));
  v_paid_ev uuid;
  v_tier uuid;
  v_order uuid;
  v_ticket uuid;
  v_buyer uuid := tests.new_user('buyer');
  v_cancel_user uuid := tests.new_user('canceller');
  v_reg jsonb;
  v_res jsonb;
  v_code text;
begin
  perform tests.as_user(v_cancel_user);
  v_reg := public.register_for_free_event(v_ev, '[]', 0, 'chk-key-0010');
  perform public.cancel_registration((v_reg ->> 'registration_id')::uuid);
  perform tests.as_postgres();
  v_code := (select code from public.tickets where id = (v_reg ->> 'ticket_id')::uuid);
  perform tests.as_user(v_owner);
  v_res := public.check_in_ticket(v_ev, v_code);
  perform tests.as_postgres();
  perform tests.is(v_res ->> 'result', 'cancelled', 'cancelled ticket scans as cancelled');

  v_paid_ev := tests.new_event(v_org, false, 10);
  v_tier := tests.new_tier(v_paid_ev, 5000, 10);
  perform tests.as_service();
  v_order := (public.create_payment_order(v_buyer, 'ticket', v_paid_ev, jsonb_build_array(jsonb_build_object('tier_id', v_tier, 'quantity', 1)),
                                          null, 'chk-order-01') ->> 'order_id')::uuid;
  perform tests.as_postgres();
  perform tests.notify_payhere(v_order, 'PH-CHK-1', 2, 5000);
  select id into v_ticket from public.tickets where order_id = v_order;
  perform tests.notify_payhere(v_order, 'PH-CHK-1', -3, 5000);
  v_code := (select 'zuno:t:' || qr_token from public.tickets where id = v_ticket);
  perform tests.as_user(v_owner);
  v_res := public.check_in_ticket(v_paid_ev, v_code);
  perform tests.is(v_res ->> 'result', 'refunded', 'refunded ticket scans as refunded');
  perform tests.is(v_res ->> 'tier_name', 'Tier 5000', 'paid ticket reports its tier name');
  perform tests.as_postgres();
end
$$;

-- Authorisation, rate limiting and audit
do $$
declare
  v_ev uuid := (select id from t_ctx where key = 'ev');
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_audits int;
begin
  perform tests.as_user((select id from t_ctx where key = 'other_owner'));
  perform tests.throws(format($q$select public.check_in_ticket(%L, 'ZN-0000-0000')$q$, v_ev), 'not_authorized',
                       'another organizer cannot check in tickets for this event');
  perform tests.as_user((select id from t_ctx where key = 'u2'));
  perform tests.throws(format($q$select public.check_in_ticket(%L, 'ZN-0000-0000')$q$, v_ev), 'not_authorized',
                       'attendees cannot check in tickets');
  perform tests.as_anon();
  perform tests.throws_state(format($q$select public.check_in_ticket(%L, 'ZN-0000-0000')$q$, v_ev), '42501',
                             'anon cannot call check_in_ticket');
  perform tests.as_postgres();

  v_audits := (select count(*)::int from public.audit_events where event_id = v_ev and action = 'check_in_attempt');
  perform tests.ok(v_audits >= 8, 'every check-in attempt is audited (' || v_audits || ' rows)');
  perform tests.ok(exists (select 1 from public.audit_events where event_id = v_ev and action = 'check_in_attempt'
                            and data ->> 'result' = 'wrong_event'),
                   'audit records the result of each attempt');

  -- 120 attempts per minute per organizer, then rate_limited.
  perform tests.as_user(v_owner);
  for i in 1 .. 130 loop
    begin
      perform public.check_in_ticket(v_ev, 'ZN-0000-0000');
    exception when others then
      if sqlerrm = 'rate_limited' then
        perform tests.ok(i > 100, 'check-in becomes rate_limited after the per-minute budget (attempt ' || i || ')');
        exit;
      end if;
      raise;
    end;
    if i = 130 then
      perform tests.ok(false, 'check-in was never rate limited');
    end if;
  end loop;
  perform tests.throws(format($q$select public.check_in_ticket(%L, 'ZN-0000-0000')$q$, v_ev), 'rate_limited',
                       'subsequent attempts in the window stay rate_limited');
  perform tests.as_postgres();
end
$$;

rollback;
