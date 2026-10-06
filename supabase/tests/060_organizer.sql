-- 060: organizer flows - publish validation, event updates, cancellation with
--      refunds, dashboards, attendee export data
begin;

create temporary table t_ctx (key text primary key, id uuid) on commit drop;
grant all on t_ctx to anon, authenticated, service_role;

do $$
declare
  v_owner uuid := tests.new_user('owner');
  v_pending_owner uuid := tests.new_user('pendingowner');
begin
  insert into t_ctx values ('owner', v_owner), ('org', tests.new_organizer(v_owner, true)),
    ('pending_owner', v_pending_owner), ('org_pending', tests.new_organizer(v_pending_owner, false)),
    ('stranger', tests.new_user('stranger'));
end
$$;

-- ---------------------------------------------------------------------------
-- submit_event_for_publish
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_org uuid := (select id from t_ctx where key = 'org');
  v_ev uuid := gen_random_uuid();
  v_paid uuid := gen_random_uuid();
  v_pending_ev uuid;
  v_detail text;
  v_msg text;
  v_res jsonb;
  v_venue uuid := (select id from public.venues where organizer_id = (select id from t_ctx where key = 'org') limit 1);
begin
  perform tests.as_user(v_owner);
  insert into public.events (id, organizer_id, category_id, title, summary, starts_at, ends_at, capacity, format)
  values (v_ev, v_org, 'technology', 'My meetup', 'Too short', now() - interval '1 hour', now() + interval '2 hours', 0, 'physical');

  begin
    perform public.submit_event_for_publish(v_ev);
    v_msg := 'no error';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detail = pg_exception_detail;
  end;
  perform tests.is(v_msg, 'validation_failed', 'incomplete draft fails validation');
  perform tests.ok(v_detail like '%summary%' and v_detail like '%starts_at%' and v_detail like '%capacity%'
                   and v_detail like '%cover_path%' and v_detail like '%venue_id%',
                   'validation DETAIL lists the failing fields (' || coalesce(v_detail, 'null') || ')');

  update public.events
     set summary = 'An evening of talks about building things', starts_at = now() + interval '10 days',
         ends_at = now() + interval '10 days 3 hours', capacity = 80, venue_id = v_venue,
         cover_path = v_org::text || '/meetup.jpg'
   where id = v_ev;
  perform tests.throws(format('select public.submit_event_for_publish(%L)', v_ev), 'creation_fee_unpaid',
                       'valid draft without the creation fee is rejected');
  perform tests.throws_state(format($q$update public.events set cover_path = 'seed/x.jpg' where id = %L$q$, v_ev), 'P0001',
                             'organizers cannot point covers at seed/ or foreign paths');

  perform tests.as_user((select id from t_ctx where key = 'stranger'));
  perform tests.throws(format('select public.submit_event_for_publish(%L)', v_ev), 'not_owner', 'non-owners get not_owner');

  perform tests.as_postgres();
  update public.events set creation_fee_paid_at = now() where id = v_ev;
  perform tests.as_user(v_owner);
  v_res := public.submit_event_for_publish(v_ev);
  perform tests.is(v_res ->> 'status', 'published', 'valid paid-up draft is published');
  perform tests.ok((v_res ->> 'published_at') is not null, 'published_at set');
  perform tests.throws(format('select public.submit_event_for_publish(%L)', v_ev), 'validation_failed',
                       'publishing twice fails validation (status)');

  -- Paid event without an on-sale tier.
  insert into public.events (id, organizer_id, category_id, venue_id, title, summary, starts_at, ends_at, capacity,
                             is_free, cover_path)
  values (v_paid, v_org, 'music', v_venue, 'Concert', 'A long enough summary for the concert', now() + interval '5 days',
          now() + interval '5 days 2 hours', 100, false, v_org::text || '/concert.jpg');
  perform tests.as_postgres();
  update public.events set creation_fee_paid_at = now() where id = v_paid;
  perform tests.as_user(v_owner);
  begin
    perform public.submit_event_for_publish(v_paid);
    v_detail := 'no error';
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  perform tests.is(v_detail, 'ticket_tiers', 'paid events need an on-sale tier');
  insert into public.ticket_tiers (event_id, name, price_minor, quantity) values (v_paid, 'General', 150000, 100);
  perform tests.is(public.submit_event_for_publish(v_paid) ->> 'status', 'published', 'paid event with a tier publishes');

  -- Unverified organizers cannot publish.
  perform tests.as_postgres();
  v_pending_ev := tests.new_event((select id from t_ctx where key = 'org_pending'), true, 10, 'draft');
  perform tests.as_user((select id from t_ctx where key = 'pending_owner'));
  perform tests.throws(format('select public.submit_event_for_publish(%L)', v_pending_ev), 'organizer_not_verified',
                       'unverified organizers cannot publish');
  perform tests.as_anon();
  perform tests.is((select count(*)::int from public.event_cards where id = v_ev), 1, 'published event visible to anon');
  perform tests.as_postgres();
  insert into t_ctx values ('ev', v_ev), ('paid', v_paid);
end
$$;

-- ---------------------------------------------------------------------------
-- send_event_update
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_ev uuid := (select id from t_ctx where key = 'ev');
  v_a uuid := tests.new_user('att1');
  v_b uuid := tests.new_user('att2');
  v_w uuid := tests.new_user('waiter');
  v_count int;
begin
  perform tests.as_user(v_a);
  perform public.register_for_free_event(v_ev, '[]', 0, 'upd-key-0001');
  perform tests.as_user(v_b);
  perform public.register_for_free_event(v_ev, '[]', 0, 'upd-key-0002');

  perform tests.as_user(v_owner);
  v_count := public.send_event_update(v_ev, 'venue_change', 'We moved to Hall B.');
  perform tests.is(v_count, 2, 'update fans out to confirmed registrants');
  perform tests.throws(format($q$select public.send_event_update(%L, 'marketing', 'x')$q$, v_ev), 'invalid_kind', 'unknown kinds rejected');
  perform tests.throws(format($q$select public.send_event_update(%L, 'general', '   ')$q$, v_ev), 'invalid_message', 'empty messages rejected');
  perform tests.is((select count(*)::int from public.event_updates where event_id = v_ev), 1, 'organizer can read event_updates');
  perform tests.as_user(v_a);
  perform tests.is((select kind from public.notifications where event_id = v_ev and kind = 'venue_change' limit 1), 'venue_change',
                   'registrant receives a venue_change notification');
  perform tests.throws(format($q$select public.send_event_update(%L, 'general', 'hi')$q$, v_ev), 'not_owner', 'attendees cannot send updates');
  perform tests.as_user(v_owner);
  for i in 1 .. 9 loop
    perform public.send_event_update(v_ev, 'general', 'Update ' || i);
  end loop;
  perform tests.throws(format($q$select public.send_event_update(%L, 'general', 'one too many')$q$, v_ev), 'rate_limited',
                       'event updates are rate limited (10 per hour)');
  perform tests.as_postgres();
  perform tests.is((select count(*)::int from public.notifications where event_id = v_ev and kind = 'organizer_update'), 18,
                   'general updates arrive as organizer_update notifications');
end
$$;

-- ---------------------------------------------------------------------------
-- Dashboards, stats, attendees, settlements, export data
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_ev uuid := (select id from t_ctx where key = 'ev');
  v_paid uuid := (select id from t_ctx where key = 'paid');
  v_buyer uuid := tests.new_user('buyer');
  v_tier uuid := (select id from public.ticket_tiers where event_id = (select id from t_ctx where key = 'paid'));
  v_order uuid;
  v_dash jsonb;
  v_stats jsonb;
  v_att jsonb;
  v_set jsonb;
  v_export jsonb;
begin
  perform tests.as_service();
  v_order := (public.create_payment_order(v_buyer, 'ticket', v_paid, jsonb_build_array(jsonb_build_object('tier_id', v_tier, 'quantity', 3)),
                                          null, 'dash-key-0001') ->> 'order_id')::uuid;
  perform tests.as_postgres();
  perform tests.notify_payhere(v_order, 'PH-DASH-1', 2, 450000);
  insert into t_ctx values ('paid_order', v_order), ('buyer', v_buyer);

  perform tests.as_user(v_owner);
  v_dash := public.organizer_dashboard();
  perform tests.is(v_dash -> 'organizer' ->> 'id', (select id from t_ctx where key = 'org')::text, 'dashboard returns the organizer');
  perform tests.ok(jsonb_array_length(v_dash -> 'events') >= 2, 'dashboard lists organizer events');
  perform tests.is((v_dash -> 'totals' ->> 'gross_minor')::bigint, 450000::bigint, 'dashboard gross');
  perform tests.is((v_dash -> 'totals' ->> 'commission_minor')::bigint, 22500::bigint, 'dashboard commission (5%)');
  perform tests.is((v_dash -> 'totals' ->> 'net_minor')::bigint, 427500::bigint, 'dashboard net = gross - commission');
  perform tests.ok((select bool_and(e ? 'registrations' and e ? 'checked_in' and e ? 'seats_remaining') from jsonb_array_elements(v_dash -> 'events') e),
                   'dashboard events carry card fields plus registrations/checked_in');

  v_stats := public.organizer_event_stats(v_paid);
  perform tests.is((v_stats ->> 'tickets_sold')::int, 3, 'stats: tickets_sold');
  perform tests.is((v_stats ->> 'gross_minor')::bigint, 450000::bigint, 'stats: gross');
  perform tests.is((v_stats ->> 'net_minor')::bigint, 427500::bigint, 'stats: net');
  perform tests.is((v_stats -> 'by_tier' -> 0 ->> 'sold')::int, 3, 'stats: by_tier sold');
  perform tests.is((v_stats -> 'by_tier' -> 0 ->> 'gross_minor')::bigint, 450000::bigint, 'stats: by_tier gross');
  perform tests.is((public.organizer_event_stats(v_ev) ->> 'registrations')::int, 2, 'stats: free registrations');

  v_att := public.organizer_attendees(v_paid);
  perform tests.is(jsonb_array_length(v_att), 3, 'attendees: one row per ticket');
  perform tests.ok(not exists (select 1 from jsonb_array_elements(v_att) a where a ? 'email' or a ? 'answers' or a ? 'user_id'),
                   'attendees list exposes no e-mail, answers or user ids');
  perform tests.ok((select bool_and(a ? 'ticket_id' and a ? 'attendee_name' and a ? 'tier_name' and a ? 'status'
                                     and a ? 'checked_in_at' and a ? 'registration_reference')
                      from jsonb_array_elements(v_att) a), 'attendee rows have the contract keys');

  v_set := public.organizer_settlements();
  perform tests.ok(exists (select 1 from jsonb_array_elements(v_set) s
                            where s ->> 'event_id' = v_paid::text and s ->> 'payout_status' = 'unsettled'
                              and (s ->> 'net_minor')::bigint = 427500),
                   'settlements report net and payout status per event');

  perform tests.as_user((select id from t_ctx where key = 'stranger'));
  perform tests.throws(format('select public.organizer_event_stats(%L)', v_paid), 'not_owner', 'stats require ownership');
  perform tests.throws(format('select public.organizer_attendees(%L)', v_paid), 'not_owner', 'attendees require ownership');
  perform tests.ok(public.organizer_dashboard() -> 'organizer' = 'null'::jsonb, 'dashboard for a non-organizer has organizer null');
  perform tests.is(jsonb_array_length(public.organizer_settlements()), 0, 'settlements empty for non-organizers');

  perform tests.as_service();
  perform tests.throws(format('select public.organizer_export_data(%L, %L)', (select id from t_ctx where key = 'stranger'), v_paid), 'not_owner',
                       'export requires ownership');
  v_export := public.organizer_export_data(v_owner, v_paid);
  perform tests.is(jsonb_array_length(v_export -> 'rows'), 3, 'export has one row per ticket');
  perform tests.as_postgres();
end
$$;

-- ---------------------------------------------------------------------------
-- cancel_event: refunds fees and paid orders, restores allowance, notifies
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_org uuid := (select id from t_ctx where key = 'org');
  v_ev uuid := tests.new_event((select id from t_ctx where key = 'org'), true, 2);
  v_paid uuid := (select id from t_ctx where key = 'paid');
  v_buyer uuid := (select id from t_ctx where key = 'buyer');
  v_tier uuid := (select id from public.ticket_tiers where event_id = (select id from t_ctx where key = 'paid'));
  v_fee_user uuid := tests.new_user('feepayer');
  v_free_user uuid := tests.new_user('freeuser');
  v_waiter uuid := tests.new_user('waiter2');
  v_pending_buyer uuid := tests.new_user('pendingbuyer');
  v_pending_order uuid;
  v_res jsonb;
begin
  perform tests.fund_wallet(v_fee_user, 1000);
  perform tests.set_allowance_used(v_fee_user, 15);
  perform tests.as_user(v_fee_user);
  perform public.register_for_free_event(v_ev, '[]', 250, 'cxl-key-0001');
  perform tests.as_user(v_free_user);
  perform public.register_for_free_event(v_ev, '[]', 0, 'cxl-key-0002');
  perform tests.as_user(v_waiter);
  perform public.join_waitlist(v_ev);
  perform tests.as_postgres();
  perform tests.is(tests.balance(v_fee_user), 750::bigint, 'fee payer charged 250');
  perform tests.is(tests.allowance_used(v_free_user), 1, 'free user used one allowance slot');

  perform tests.as_user((select id from t_ctx where key = 'stranger'));
  perform tests.throws(format($q$select public.cancel_event(%L, 'nope')$q$, v_ev), 'not_owner', 'only the owner can cancel');

  perform tests.as_user(v_owner);
  v_res := public.cancel_event(v_ev, 'Venue flooded');
  perform tests.is(v_res ->> 'status', 'cancelled', 'cancel_event returns cancelled');
  perform tests.is((v_res ->> 'registrations_cancelled')::int, 3, 'all active registrations cancelled (incl. waitlist)');
  perform tests.is((v_res ->> 'refunds_issued')::int, 1, 'one fee refund issued');
  perform tests.is((v_res ->> 'refund_total_minor')::bigint, 250::bigint, 'refund total 250');
  perform tests.is((public.cancel_event(v_ev, 'again') ->> 'refunds_issued')::int, 0, 'cancel_event is idempotent');
  perform tests.as_postgres();
  perform tests.is(tests.balance(v_fee_user), 1000::bigint, 'extra fee refunded as refund_credit');
  perform tests.is(tests.ledger_sum(v_fee_user), tests.balance(v_fee_user), 'ledger reconciles after refund');
  perform tests.is(tests.allowance_used(v_free_user), 0, 'allowance restored for the cancelled free registration');
  perform tests.is((select count(*)::int from public.tickets where event_id = v_ev and status = 'cancelled'), 2, 'free tickets cancelled');
  perform tests.is((select count(*)::int from public.notifications where event_id = v_ev and kind = 'event_cancelled'), 3,
                   'every affected user notified');
  perform tests.is((select status from public.events where id = v_ev), 'cancelled', 'event status cancelled');

  -- Paid event: paid orders refunded to wallets, pending checkouts released.
  perform tests.as_service();
  v_pending_order := (public.create_payment_order(v_pending_buyer, 'ticket', v_paid,
                       jsonb_build_array(jsonb_build_object('tier_id', v_tier, 'quantity', 2)), null, 'cxl-order-01') ->> 'order_id')::uuid;
  perform tests.as_user(v_owner);
  v_res := public.cancel_event(v_paid, 'Artist unwell');
  perform tests.is((v_res ->> 'refund_total_minor')::bigint, 450000::bigint, 'paid order refunded in full');
  perform tests.as_postgres();
  perform tests.is(tests.balance(v_buyer), 450000::bigint, 'buyer wallet credited with the ticket price');
  perform tests.is((select status from public.orders where id = (select id from t_ctx where key = 'paid_order')), 'refunded', 'paid order refunded');
  perform tests.is((select count(*)::int from public.tickets where event_id = v_paid and status = 'refunded'), 3, 'paid tickets refunded');
  perform tests.is((select status from public.orders where id = v_pending_order), 'cancelled', 'pending checkout cancelled');
  perform tests.is((select reserved from public.ticket_tiers where id = v_tier), 0, 'pending reservation released');
  -- A late successful payment for the cancelled event is refunded, not fulfilled.
  perform tests.is(tests.notify_payhere(v_pending_order, 'PH-LATE-1', 2, 300000) ->> 'outcome', 'refunded_event_unavailable',
                   'late payment for a cancelled event is refunded to the wallet');
  perform tests.is((select count(*)::int from public.tickets where order_id = v_pending_order), 0, 'no tickets for a cancelled event');
  perform tests.is(tests.balance(v_pending_buyer), 300000::bigint, 'late payer refunded');
  perform tests.ok(not exists (
    select 1 from public.wallets w
     where w.balance_minor <> coalesce((select sum(amount_minor) from public.wallet_ledger l where l.user_id = w.user_id and l.status = 'posted'), 0)),
    'all wallets reconcile after cancellations');
end
$$;

rollback;
