-- 030: waitlist, offers on cancellation, offer expiry, cancellation rules
begin;

create temporary table t_ctx (key text primary key, id uuid) on commit drop;
grant all on t_ctx to anon, authenticated, service_role;

do $$
declare
  v_org uuid := tests.new_organizer(tests.new_user('owner'), true);
begin
  insert into t_ctx values
    ('full', tests.new_event(v_org, true, 2)),
    ('roomy', tests.new_event(v_org, true, 5)),
    ('paid', tests.new_event(v_org, false, 5)),
    ('a', tests.new_user('ann')), ('b', tests.new_user('ben')), ('c', tests.new_user('cat')),
    ('d', tests.new_user('dan')), ('e', tests.new_user('eve')), ('f', tests.new_user('fay'));
end
$$;

do $$
declare
  v_full uuid := (select id from t_ctx where key = 'full');
  v_a uuid := (select id from t_ctx where key = 'a');
  v_b uuid := (select id from t_ctx where key = 'b');
  v_c uuid := (select id from t_ctx where key = 'c');
  v_d uuid := (select id from t_ctx where key = 'd');
  v_e uuid := (select id from t_ctx where key = 'e');
  v_reg_a uuid;
  v_reg_b uuid;
  v_wl jsonb;
  v_res jsonb;
  v_detail jsonb;
begin
  perform tests.as_user(v_a);
  v_reg_a := (public.register_for_free_event(v_full, '[]', 0, 'wl-key-a001') ->> 'registration_id')::uuid;
  perform tests.throws(format('select public.join_waitlist(%L)', v_full), 'already_registered',
                       'registered users cannot join the waitlist');
  perform tests.throws(format('select public.join_waitlist(%L)', (select id from t_ctx where key = 'roomy')), 'seats_available',
                       'waitlist is only for full events');
  perform tests.throws(format('select public.join_waitlist(%L)', (select id from t_ctx where key = 'paid')), 'not_free_event',
                       'waitlist is for free events');
  perform tests.as_user(v_b);
  v_reg_b := (public.register_for_free_event(v_full, '[]', 0, 'wl-key-b001') ->> 'registration_id')::uuid;

  perform tests.as_user(v_c);
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'wl-key-c001')$q$, v_full), 'sold_out',
                       'full event rejects new registrations');
  v_wl := public.join_waitlist(v_full);
  perform tests.is(v_wl ->> 'status', 'waitlisted', 'join_waitlist: status waitlisted');
  perform tests.is((v_wl ->> 'position')::int, 1, 'join_waitlist: first in line');
  perform tests.throws(format('select public.join_waitlist(%L)', v_full), 'already_registered', 'cannot join the waitlist twice');
  v_detail := public.get_event_detail(v_full);
  perform tests.is((v_detail -> 'viewer' ->> 'waitlisted')::boolean, true, 'event detail: viewer.waitlisted');
  perform tests.is(v_detail -> 'viewer' ->> 'registration_status', 'waitlisted', 'event detail: registration_status waitlisted');
  perform tests.is((v_detail -> 'viewer' ->> 'waitlist_position')::int, 1, 'event detail: waitlist position');

  perform tests.as_user(v_d);
  perform tests.is((public.join_waitlist(v_full) ->> 'position')::int, 2, 'join_waitlist: second in line');

  -- A cancels: the seat is offered to C (seat stays held).
  perform tests.as_user(v_a);
  perform tests.throws(format('select public.cancel_registration(%L)', v_reg_b), 'registration_not_found',
                       'cannot cancel someone else''s registration');
  v_res := public.cancel_registration(v_reg_a);
  perform tests.is(v_res ->> 'status', 'cancelled', 'cancel_registration returns cancelled');
  perform tests.is(public.my_tickets() -> 0 ->> 'status', 'cancelled', 'cancelled registration cancels the ticket');
  perform tests.is(public.cancel_registration(v_reg_a) ->> 'status', 'cancelled', 'cancelling twice is idempotent');
  perform tests.as_postgres();
  perform tests.is((select status from public.registrations where user_id = v_c and event_id = v_full), 'offered',
                   'next waitlisted user is offered the seat');
  perform tests.ok((select offer_expires_at > now() from public.registrations where user_id = v_c and event_id = v_full),
                   'offer has a future expiry');
  perform tests.is((select count(*)::int from public.notifications where user_id = v_c and kind = 'waitlist_movement'), 1,
                   'offered user gets a waitlist_movement notification');
  perform tests.is(tests.seats_taken(v_full), 2, 'the offered seat stays held (seats_taken unchanged)');
  perform tests.is((select status from public.registrations where user_id = v_d and event_id = v_full), 'waitlisted',
                   'second waitlisted user keeps waiting');

  -- Someone else cannot take the held seat.
  perform tests.as_user(v_e);
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'wl-key-e001')$q$, v_full), 'sold_out',
                       'active offers count against capacity');
  -- The offered user confirms.
  perform tests.as_user(v_c);
  perform tests.is((public.quote_free_registration(v_full) ->> 'can_register')::boolean, true, 'offered user can register');
  v_res := public.register_for_free_event(v_full, '[]', 0, 'wl-key-c002');
  perform tests.is(v_res ->> 'status', 'confirmed', 'offered user confirms the seat');
  perform tests.as_postgres();
  perform tests.is(tests.seats_taken(v_full), 2, 'accepting an offer does not double-count the seat');
  perform tests.is((select count(*)::int from public.tickets where user_id = v_c and event_id = v_full and status = 'valid'), 1,
                   'offered user receives a ticket');

  -- B cancels: D is offered; the offer then expires and is released.
  perform tests.as_user(v_b);
  perform public.cancel_registration(v_reg_b);
  perform tests.as_postgres();
  perform tests.is((select status from public.registrations where user_id = v_d and event_id = v_full), 'offered', 'D is offered');
  update public.registrations set offer_expires_at = now() - interval '1 second' where user_id = v_d and event_id = v_full;
  perform tests.as_service();
  perform public.expire_stale_orders();
  perform tests.as_postgres();
  perform tests.is((select cancellation_reason from public.registrations where user_id = v_d and event_id = v_full), 'offer_expired',
                   'expired offers are cancelled by expire_stale_orders');
  perform tests.is(tests.seats_taken(v_full), 1, 'expired offer with an empty waitlist frees the seat');
  perform tests.as_user(v_e);
  perform tests.is(public.register_for_free_event(v_full, '[]', 0, 'wl-key-e002') ->> 'status', 'confirmed',
                   'freed seat can be taken by anyone');
  perform tests.as_postgres();
end
$$;

-- Lazy release: an expired offer is released when someone else registers.
do $$
declare
  v_org uuid := tests.new_organizer(tests.new_user('owner2'), true);
  v_ev uuid := tests.new_event(v_org, true, 1);
  v_x uuid := tests.new_user('xena');
  v_y uuid := tests.new_user('yara');
  v_z uuid := tests.new_user('zane');
  v_reg uuid;
begin
  perform tests.as_user(v_x);
  v_reg := (public.register_for_free_event(v_ev, '[]', 0, 'lazy-key-x01') ->> 'registration_id')::uuid;
  perform tests.as_user(v_y);
  perform public.join_waitlist(v_ev);
  perform tests.as_user(v_x);
  perform public.cancel_registration(v_reg);
  perform tests.as_postgres();
  update public.registrations set offer_expires_at = now() - interval '1 second' where user_id = v_y and event_id = v_ev;
  perform tests.as_user(v_z);
  perform tests.is(public.register_for_free_event(v_ev, '[]', 0, 'lazy-key-z01') ->> 'status', 'confirmed',
                   'expired offers are released lazily under the event lock');
  perform tests.as_user(v_y);
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'lazy-key-y01')$q$, v_ev), 'sold_out',
                       'the user whose offer expired can no longer claim the seat');
  perform tests.as_postgres();
  perform tests.is(tests.seats_taken(v_ev), 1, 'seat accounting stays consistent after lazy release');

  -- Waitlisted user cancelling leaves seats untouched.
  perform tests.as_user(tests.new_user('walt'));
  perform tests.lives(format('select public.join_waitlist(%L)', v_ev), 'join waitlist on a full event');
  perform tests.lives(format($q$select public.cancel_registration((select (public.get_event_detail(%L) -> 'viewer' ->> 'registration_id')::uuid))$q$, v_ev),
                      'waitlisted user can leave the waitlist');
  perform tests.as_postgres();
  perform tests.is(tests.seats_taken(v_ev), 1, 'leaving the waitlist does not change seats');
end
$$;

rollback;
