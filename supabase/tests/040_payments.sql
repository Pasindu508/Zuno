-- 040: PayHere orders - DB pricing, commission rounding, inventory reservation,
--      expiry release, idempotent notifications, amount checks, fulfilment,
--      wallet top-ups and event creation fees
begin;

create temporary table t_ctx (key text primary key, id uuid) on commit drop;
grant all on t_ctx to anon, authenticated, service_role;

do $$
declare
  v_owner uuid := tests.new_user('owner');
  v_org uuid := tests.new_organizer(v_owner, true);
  v_ev uuid := tests.new_event(v_org, false, 100);
  v_small uuid := tests.new_event(v_org, false, 3);
begin
  insert into t_ctx values ('owner', v_owner), ('org', v_org), ('ev', v_ev), ('small', v_small),
    ('t1', tests.new_tier(v_ev, 150000, 5, 4)),
    ('t30', tests.new_tier(v_ev, 30, 10, 10)),
    ('t29', tests.new_tier(v_ev, 29, 10, 10)),
    ('t9', tests.new_tier(v_ev, 9, 20, 10)),
    ('tsmall', tests.new_tier(v_small, 1000, 5, 5)),
    ('free_ev', tests.new_event(v_org, true, 10)),
    ('u', tests.new_user('buyer')), ('v', tests.new_user('second'));
  -- a tier of another event
  insert into t_ctx values ('t_other', tests.new_tier(v_small, 500, 5, 5));
end
$$;

-- ---------------------------------------------------------------------------
-- Order creation: DB pricing, commission, reservation, idempotency, errors
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := (select id from t_ctx where key = 'u');
  v_ev uuid := (select id from t_ctx where key = 'ev');
  v_t1 uuid := (select id from t_ctx where key = 't1');
  v_order jsonb;
  v_replay jsonb;
  v_c jsonb;
begin
  perform tests.as_service();
  -- p_amount_minor = 1 is ignored for ticket orders: price comes from the DB.
  v_order := public.create_payment_order(v_u, 'ticket', v_ev, jsonb_build_array(jsonb_build_object('tier_id', v_t1, 'quantity', 2)),
                                         1, 'order-key-0001');
  perform tests.is(v_order ->> 'status', 'pending', 'ticket order is pending');
  perform tests.is((v_order -> 'summary' ->> 'subtotal_minor')::bigint, 300000::bigint, 'subtotal priced from the DB (2 x 150000)');
  perform tests.is((v_order -> 'summary' ->> 'total_minor')::bigint, 300000::bigint, 'attendee pays face value');
  perform tests.is((v_order -> 'summary' ->> 'commission_minor')::bigint, 15000::bigint, 'commission 5% of 300000');
  perform tests.is(v_order -> 'summary' -> 'lines' -> 0 ->> 'amount_minor', '300000', 'summary line amount');
  perform tests.ok((v_order ->> 'expires_at')::timestamptz between now() + interval '14 minutes' and now() + interval '16 minutes',
                   'expires_at = now + order_hold_minutes (15)');
  perform tests.ok(v_order ? 'customer' and v_order ? 'item_description', 'RPC returns checkout customer/item data for the Edge Function');
  insert into t_ctx values ('order1', (v_order ->> 'order_id')::uuid);

  v_replay := public.create_payment_order(v_u, 'ticket', v_ev, jsonb_build_array(jsonb_build_object('tier_id', v_t1, 'quantity', 2)),
                                          null, 'order-key-0001');
  perform tests.is(v_replay ->> 'order_id', v_order ->> 'order_id', 'same idempotency key returns the same order');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'wallet_topup', null, null, 100000, 'order-key-0001')$q$, v_u),
                       'idempotency_conflict', 'idempotency key reused for another kind is rejected');
  perform tests.as_postgres();
  perform tests.is((select reserved from public.ticket_tiers where id = v_t1), 2, 'inventory reserved once (replay does not double-reserve)');
  perform tests.is((select sold from public.ticket_tiers where id = v_t1), 0, 'nothing sold before payment');
  perform tests.is((select count(*)::int from public.tickets where order_id = (v_order ->> 'order_id')::uuid), 0,
                   'no tickets before a verified payment');
  perform tests.is((select count(*)::int from public.registrations where user_id = v_u), 0, 'no registration before a verified payment');

  -- Commission rounding: (subtotal * 500 + 5000) / 10000, half-up.
  perform tests.as_service();
  v_c := public.create_payment_order(v_u, 'ticket', v_ev, jsonb_build_array(jsonb_build_object('tier_id', (select id from t_ctx where key = 't30'), 'quantity', 1)), null, 'order-key-r030');
  perform tests.is((v_c -> 'summary' ->> 'commission_minor')::bigint, 2::bigint, 'commission rounding: 30 -> 1.5 -> 2 (half-up)');
  v_c := public.create_payment_order(v_u, 'ticket', v_ev, jsonb_build_array(jsonb_build_object('tier_id', (select id from t_ctx where key = 't29'), 'quantity', 1)), null, 'order-key-r029');
  perform tests.is((v_c -> 'summary' ->> 'commission_minor')::bigint, 1::bigint, 'commission rounding: 29 -> 1.45 -> 1');
  v_c := public.create_payment_order(v_u, 'ticket', v_ev, jsonb_build_array(jsonb_build_object('tier_id', (select id from t_ctx where key = 't9'), 'quantity', 1)), null, 'order-key-r009');
  perform tests.is((v_c -> 'summary' ->> 'commission_minor')::bigint, 0::bigint, 'commission rounding: 9 -> 0.45 -> 0');
  v_c := public.create_payment_order(v_u, 'ticket', v_ev, jsonb_build_array(jsonb_build_object('tier_id', (select id from t_ctx where key = 't9'), 'quantity', 10)), null, 'order-key-r090');
  perform tests.is((v_c -> 'summary' ->> 'commission_minor')::bigint, 5::bigint, 'commission rounding: 90 -> 4.5 -> 5');

  -- Errors
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, %L, null, 'order-key-e001')$q$, v_u, v_ev,
                              jsonb_build_array(jsonb_build_object('tier_id', v_t1, 'quantity', 4))),
                       'sold_out', 'cannot reserve beyond tier quantity (2 reserved + 4 > 5)');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, %L, null, 'order-key-e002')$q$, v_u, v_ev,
                              jsonb_build_array(jsonb_build_object('tier_id', (select id from t_ctx where key = 't30'), 'quantity', 11))),
                       'max_per_order_exceeded', 'max_per_order enforced');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, %L, null, 'order-key-e003')$q$, v_u, v_ev,
                              jsonb_build_array(jsonb_build_object('tier_id', (select id from t_ctx where key = 't_other'), 'quantity', 1))),
                       'invalid_items', 'tiers of another event are rejected');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, '[{"tier_id":"nope","quantity":1}]', null, 'order-key-e004')$q$, v_u, v_ev),
                       'invalid_items', 'malformed items are rejected');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, %L, null, 'order-key-e005')$q$, v_u, v_ev,
                              jsonb_build_array(jsonb_build_object('tier_id', v_t1, 'quantity', 0))),
                       'invalid_items', 'zero quantity is rejected');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, %L, null, 'order-key-e006')$q$, v_u,
                              (select id from t_ctx where key = 'free_ev'), jsonb_build_array(jsonb_build_object('tier_id', v_t1, 'quantity', 1))),
                       'not_paid_event', 'free events cannot be bought');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, %L, null, 'order-key-e007')$q$, gen_random_uuid(), v_ev,
                              jsonb_build_array(jsonb_build_object('tier_id', v_t1, 'quantity', 1))),
                       'user_not_found', 'unknown users are rejected');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, %L, null, 'order-key-e008')$q$, v_u,
                              (select id from t_ctx where key = 'small'),
                              jsonb_build_array(jsonb_build_object('tier_id', (select id from t_ctx where key = 'tsmall'), 'quantity', 4))),
                       'sold_out', 'event capacity applies across tiers (4 > capacity 3)');
  perform tests.as_postgres();
  perform tests.throws_state(format('update public.ticket_tiers set reserved = 6 where id = %L', v_t1), '23514',
                             'CHECK sold + reserved <= quantity');
end
$$;

-- ---------------------------------------------------------------------------
-- PayHere notifications
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := (select id from t_ctx where key = 'u');
  v_ev uuid := (select id from t_ctx where key = 'ev');
  v_t1 uuid := (select id from t_ctx where key = 't1');
  v_order uuid := (select id from t_ctx where key = 'order1');
  v_seats int := tests.seats_taken((select id from t_ctx where key = 'ev'));
  v_res jsonb;
begin
  -- Amount / currency mismatch: rejected, nothing applied.
  perform tests.as_service();
  v_res := public.apply_payhere_notification(v_order, 'PH-0001', 2, 299999, 'LKR', 'VISA', '{}');
  perform tests.is(v_res ->> 'result', 'rejected', 'amount mismatch is rejected');
  perform tests.is(v_res ->> 'outcome', 'rejected_amount_mismatch', 'amount mismatch outcome recorded');
  v_res := public.apply_payhere_notification(v_order, 'PH-0002', 2, 300000, 'USD', 'VISA', '{}');
  perform tests.is(v_res ->> 'result', 'rejected', 'currency mismatch is rejected');
  perform tests.as_postgres();
  perform tests.is((select status from public.orders where id = v_order), 'pending', 'order still pending after rejected notifications');
  perform tests.is((select count(*)::int from public.tickets where order_id = v_order), 0, 'no tickets after rejected notifications');

  -- Verified success.
  v_res := tests.notify_payhere(v_order, 'PH-1000', 2, 300000);
  perform tests.is(v_res ->> 'result', 'applied', 'verified success notification applied');
  perform tests.is(v_res ->> 'outcome', 'paid', 'outcome paid');
  perform tests.is((select status from public.orders where id = v_order), 'paid', 'order paid');
  perform tests.ok((select paid_at is not null from public.orders where id = v_order), 'paid_at set');
  perform tests.is((select count(*)::int from public.tickets where order_id = v_order and tier_id = v_t1 and status = 'valid'), 2,
                   'one ticket per quantity issued after payment');
  perform tests.is((select sold from public.ticket_tiers where id = v_t1), 2, 'reservation converted to sold');
  perform tests.is((select reserved from public.ticket_tiers where id = v_t1), 0, 'reservation released on fulfilment');
  perform tests.is(tests.seats_taken(v_ev), v_seats + 2, 'seats_taken increased by quantity');
  perform tests.is((select count(*)::int from public.registrations where user_id = v_u and event_id = v_ev and kind = 'paid' and status = 'confirmed'), 1,
                   'paid registration created');
  perform tests.ok(exists (select 1 from public.notifications where user_id = v_u and kind = 'ticket_issued')
                   and exists (select 1 from public.notifications where user_id = v_u and kind = 'payment_status'),
                   'payment_status and ticket_issued notifications written');
  perform tests.ok(not exists (select 1 from public.payments where order_id = v_order
                                and (notification ? 'card_no' or notification ? 'card_holder_name' or notification ? 'card_expiry' or notification ? 'md5sig')),
                   'stored notification is sanitised (no card data, no md5sig)');
  perform tests.ok(exists (select 1 from public.payments where order_id = v_order and provider_payment_id = 'PH-1000' and notification ->> 'payment_id' = 'PH-1000'),
                   'sanitised notification keeps allow-listed fields');

  -- Duplicate callback: no-op.
  v_res := tests.notify_payhere(v_order, 'PH-1000', 2, 300000);
  perform tests.is(v_res ->> 'result', 'duplicate', 'duplicate callback detected');
  perform tests.is(v_res ->> 'outcome', 'paid', 'duplicate reports the original outcome');
  perform tests.is((select count(*)::int from public.tickets where order_id = v_order), 2, 'duplicate callback issues no extra tickets');
  perform tests.is((select count(*)::int from public.payments where order_id = v_order and provider_payment_id = 'PH-1000'), 1,
                   'duplicate callback stores no extra payment row');
  -- A later failure code cannot downgrade a paid order.
  v_res := tests.notify_payhere(v_order, 'PH-1000', -2, 300000);
  perform tests.is(v_res ->> 'outcome', 'ignored_paid', 'failure after success is ignored');
  perform tests.is((select status from public.orders where id = v_order), 'paid', 'paid order stays paid');
  perform tests.throws($q$select public.apply_payhere_notification(gen_random_uuid(), 'PH-x', 2, 1, 'LKR')$q$, 'order_not_found',
                       'unknown order ids are rejected');

  -- my_tickets shows the paid tickets with the order id.
  perform tests.as_user(v_u);
  perform tests.is((select count(*)::int from jsonb_array_elements(public.my_tickets()) t where t ->> 'order_id' = v_order::text), 2,
                   'my_tickets lists the paid tickets with order_id');
  perform tests.is((select count(*)::int from public.orders where id = v_order), 1, 'buyer can read own order');
  perform tests.is((select count(*)::int from public.order_items where order_id = v_order), 1, 'buyer can read own order items');
  perform tests.as_postgres();
end
$$;

-- ---------------------------------------------------------------------------
-- Failed / cancelled / expired orders release their reservations
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := (select id from t_ctx where key = 'v');
  v_ev uuid := (select id from t_ctx where key = 'ev');
  v_t1 uuid := (select id from t_ctx where key = 't1');
  v_items jsonb := jsonb_build_array(jsonb_build_object('tier_id', (select id from t_ctx where key = 't1'), 'quantity', 1));
  v_o1 uuid;
  v_o2 uuid;
  v_o3 uuid;
  v_res jsonb;
  v_reserved int;
begin
  perform tests.as_service();
  v_o1 := (public.create_payment_order(v_u, 'ticket', v_ev, v_items, null, 'rel-key-0001') ->> 'order_id')::uuid;
  v_o2 := (public.create_payment_order(v_u, 'ticket', v_ev, v_items, null, 'rel-key-0002') ->> 'order_id')::uuid;
  v_o3 := (public.create_payment_order(v_u, 'ticket', v_ev, v_items, null, 'rel-key-0003') ->> 'order_id')::uuid;
  perform tests.as_postgres();
  perform tests.is((select reserved from public.ticket_tiers where id = v_t1), 3, 'three single-ticket holds');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'ticket', %L, %L, null, 'rel-key-0004')$q$, v_u, v_ev, v_items),
                       'sold_out', 'tier fully held (2 sold + 3 reserved = 5)');

  v_res := tests.notify_payhere(v_o1, 'PH-2001', -2, 150000);
  perform tests.is(v_res ->> 'outcome', 'order_failed', 'failed notification fails the order');
  v_res := tests.notify_payhere(v_o2, 'PH-2002', -1, 150000);
  perform tests.is(v_res ->> 'outcome', 'order_cancelled', 'cancelled notification cancels the order');
  perform tests.is((select reserved from public.ticket_tiers where id = v_t1), 1, 'failed and cancelled orders release their holds');
  perform tests.is((select count(*)::int from public.tickets where order_id in (v_o1, v_o2)), 0, 'no tickets for failed/cancelled orders');
  perform tests.is((select count(*)::int from public.notifications where user_id = v_u and kind = 'payment_status'), 2,
                   'buyer notified about failed and cancelled payments');
  v_res := tests.notify_payhere(v_o3, 'PH-2003', 0, 150000);
  perform tests.is(v_res ->> 'outcome', 'pending_recorded', 'pending (0) notification only recorded');

  -- Expiry releases the hold.
  update public.orders set expires_at = now() - interval '1 second' where id = v_o3;
  perform tests.as_service();
  perform tests.ok(public.expire_stale_orders() >= 1, 'expire_stale_orders expires stale holds');
  perform tests.as_postgres();
  perform tests.is((select status from public.orders where id = v_o3), 'expired', 'order expired');
  perform tests.is((select reserved from public.ticket_tiers where id = v_t1), 0, 'expired hold released');

  -- Late success on an expired order while seats remain: fulfilled.
  v_res := tests.notify_payhere(v_o3, 'PH-2003', 2, 150000);
  perform tests.is(v_res ->> 'outcome', 'paid', 'late payment on an expired order is fulfilled when inventory remains');
  perform tests.is((select count(*)::int from public.tickets where order_id = v_o3), 1, 'late payment issues the ticket');
  perform tests.is((select sold from public.ticket_tiers where id = v_t1), 3, 'late payment counted as sold');

  -- Late success when sold out: refunded to the wallet.
  update public.ticket_tiers set sold = quantity where id = v_t1;
  v_res := tests.notify_payhere(v_o1, 'PH-2001', 2, 150000);
  perform tests.is(v_res ->> 'outcome', 'refunded_sold_out', 'late payment for a sold-out tier is refunded');
  perform tests.is((select status from public.orders where id = v_o1), 'refunded', 'order marked refunded');
  perform tests.is(tests.balance(v_u), 150000::bigint, 'refund credited to the wallet');
  perform tests.ok(exists (select 1 from public.wallet_ledger where user_id = v_u and entry_type = 'refund_credit' and amount_minor = 150000),
                   'refund_credit ledger entry');
  perform tests.is(tests.ledger_sum(v_u), tests.balance(v_u), 'ledger and balance agree after refund');
end
$$;

-- ---------------------------------------------------------------------------
-- Wallet top-ups: pending ledger entry, posted only after verified payment
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := tests.new_user('topper');
  v_order jsonb;
  v_failed jsonb;
  v_res jsonb;
begin
  perform tests.as_service();
  perform tests.throws(format($q$select public.create_payment_order(%L, 'wallet_topup', null, null, 9999, 'top-key-0001')$q$, v_u),
                       'invalid_amount', 'top-up below the minimum is rejected');
  perform tests.throws(format($q$select public.create_payment_order(%L, 'wallet_topup', null, null, 5000001, 'top-key-0002')$q$, v_u),
                       'invalid_amount', 'top-up above the maximum is rejected');
  v_order := public.create_payment_order(v_u, 'wallet_topup', null, null, 100000, 'top-key-0003');
  perform tests.is((v_order -> 'summary' ->> 'total_minor')::bigint, 100000::bigint, 'top-up order total');
  perform tests.is((v_order -> 'summary' ->> 'commission_minor')::bigint, 0::bigint, 'no commission on top-ups');
  perform tests.as_postgres();
  perform tests.ok(exists (select 1 from public.wallet_ledger where user_id = v_u and status = 'pending' and amount_minor = 100000
                            and balance_after_minor is null and reference_id = (v_order ->> 'order_id')::uuid),
                   'pending ledger entry with null balance_after');
  perform tests.is(tests.balance(v_u), 0::bigint, 'pending top-up does not change the balance');
  perform tests.as_user(v_u);
  perform tests.is((public.wallet_summary() ->> 'pending_topups_minor')::bigint, 100000::bigint, 'wallet_summary reports pending top-ups');
  perform tests.as_postgres();

  v_res := tests.notify_payhere((v_order ->> 'order_id')::uuid, 'PH-3000', 2, 100000);
  perform tests.is(v_res ->> 'outcome', 'paid', 'top-up applied');
  perform tests.is(tests.balance(v_u), 100000::bigint, 'top-up credited');
  perform tests.ok(exists (select 1 from public.wallet_ledger where user_id = v_u and status = 'posted' and amount_minor = 100000
                            and balance_after_minor = 100000),
                   'pending entry transitioned to posted with balance_after');
  perform tests.is((select count(*)::int from public.wallet_ledger where user_id = v_u), 1, 'no second ledger row on posting');
  v_res := tests.notify_payhere((v_order ->> 'order_id')::uuid, 'PH-3000', 2, 100000);
  perform tests.is(v_res ->> 'result', 'duplicate', 'duplicate top-up callback is a no-op');
  perform tests.is(tests.balance(v_u), 100000::bigint, 'duplicate callback does not double-credit');

  perform tests.as_service();
  v_failed := public.create_payment_order(v_u, 'wallet_topup', null, null, 20000, 'top-key-0004');
  perform tests.as_postgres();
  perform tests.notify_payhere((v_failed ->> 'order_id')::uuid, 'PH-3001', -2, 20000);
  perform tests.ok(exists (select 1 from public.wallet_ledger where reference_id = (v_failed ->> 'order_id')::uuid and status = 'failed'),
                   'failed top-up marks the pending ledger entry failed');
  perform tests.is(tests.balance(v_u), 100000::bigint, 'failed top-up leaves the balance unchanged');
  perform tests.is(tests.ledger_sum(v_u), tests.balance(v_u), 'ledger and balance agree after top-ups');
end
$$;

-- ---------------------------------------------------------------------------
-- Event creation fee
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_draft uuid := tests.new_event((select id from t_ctx where key = 'org'), true, 10, 'draft');
  v_order jsonb;
  v_second jsonb;
  v_res jsonb;
begin
  perform tests.as_service();
  perform tests.throws(format($q$select public.create_payment_order(%L, 'event_creation_fee', %L, null, null, 'fee-key-0001')$q$,
                              (select id from t_ctx where key = 'u'), v_draft),
                       'not_owner', 'only the organizer owner can pay the creation fee');
  v_order := public.create_payment_order(v_owner, 'event_creation_fee', v_draft, null, 1, 'fee-key-0002');
  perform tests.is((v_order -> 'summary' ->> 'total_minor')::bigint, 100000::bigint, 'creation fee priced from platform_settings');
  v_second := public.create_payment_order(v_owner, 'event_creation_fee', v_draft, null, null, 'fee-key-0003');
  perform tests.as_postgres();
  v_res := tests.notify_payhere((v_order ->> 'order_id')::uuid, 'PH-4000', 2, 100000);
  perform tests.is(v_res ->> 'outcome', 'paid', 'creation fee applied');
  perform tests.ok((select creation_fee_paid_at is not null from public.events where id = v_draft), 'creation_fee_paid_at set');
  v_res := tests.notify_payhere((v_second ->> 'order_id')::uuid, 'PH-4001', 2, 100000);
  perform tests.is(v_res ->> 'outcome', 'refunded_duplicate_fee', 'a second paid fee is refunded to the wallet');
  perform tests.is(tests.balance(v_owner), 100000::bigint, 'duplicate fee credited back');
  perform tests.as_service();
  perform tests.throws(format($q$select public.create_payment_order(%L, 'event_creation_fee', %L, null, null, 'fee-key-0004')$q$, v_owner, v_draft),
                       'creation_fee_already_paid', 'fee cannot be bought twice');
  perform tests.as_postgres();
end
$$;

-- ---------------------------------------------------------------------------
-- Chargeback revokes tickets
-- ---------------------------------------------------------------------------
do $$
declare
  v_order uuid := (select id from t_ctx where key = 'order1');
  v_t1 uuid := (select id from t_ctx where key = 't1');
  v_sold int := (select sold from public.ticket_tiers where id = (select id from t_ctx where key = 't1'));
  v_res jsonb;
begin
  v_res := tests.notify_payhere(v_order, 'PH-1000', -3, 300000);
  perform tests.is(v_res ->> 'outcome', 'chargeback_tickets_revoked', 'chargeback revokes tickets');
  perform tests.is((select count(*)::int from public.tickets where order_id = v_order and status = 'refunded'), 2, 'tickets marked refunded');
  perform tests.is((select sold from public.ticket_tiers where id = v_t1), v_sold - 2, 'inventory returned after chargeback');
  perform tests.is((select status from public.orders where id = v_order), 'refunded', 'order refunded after chargeback');
end
$$;

rollback;
