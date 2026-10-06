-- 010: Row Level Security isolation and column-level write protection
begin;

create temporary table t_ctx (key text primary key, id uuid) on commit drop;
grant all on t_ctx to anon, authenticated, service_role;

do $$
declare
  v_a uuid := tests.new_user('alice');
  v_b uuid := tests.new_user('bob');
  v_org_owner uuid := tests.new_user('owner');
  v_org uuid;
  v_org_pending uuid;
  v_pub uuid;
  v_draft uuid;
  v_pending_event uuid;
  v_tier uuid;
  v_order_a uuid;
  v_order_b uuid;
  v_reg uuid;
begin
  v_org := tests.new_organizer(v_org_owner, true);
  v_org_pending := tests.new_organizer(tests.new_user('pendingowner'), false);
  v_pub := tests.new_event(v_org, false, 50);
  v_draft := tests.new_event(v_org, true, 50, 'draft');
  v_pending_event := tests.new_event(v_org_pending, true, 50, 'draft');
  v_tier := tests.new_tier(v_pub, 150000, 50);
  update public.events set online_url = 'https://live.zuno.example/x' where id = v_pub;

  perform tests.fund_wallet(v_a, 5000);
  perform tests.fund_wallet(v_b, 7000);
  perform private.notify(v_a, 'general', 'For A', 'a');
  perform private.notify(v_b, 'general', 'For B', 'b');
  insert into public.orders (user_id, event_id, kind, subtotal_minor, total_minor, idempotency_key, expires_at)
  values (v_a, v_pub, 'ticket', 150000, 150000, 'rls-order-a', now() + interval '15 minutes') returning id into v_order_a;
  insert into public.orders (user_id, event_id, kind, subtotal_minor, total_minor, idempotency_key, expires_at)
  values (v_b, v_pub, 'ticket', 150000, 150000, 'rls-order-b', now() + interval '15 minutes') returning id into v_order_b;
  insert into public.order_items (order_id, tier_id, quantity, unit_price_minor) values (v_order_a, v_tier, 1, 150000);
  insert into public.order_items (order_id, tier_id, quantity, unit_price_minor) values (v_order_b, v_tier, 1, 150000);
  insert into public.registrations (event_id, user_id, status, kind, order_id, reference)
  values (v_pub, v_b, 'confirmed', 'paid', v_order_b, private.generate_registration_reference()) returning id into v_reg;
  perform private.issue_ticket(v_reg, v_pub, v_b, v_tier, v_order_b);
  insert into public.push_devices (user_id, apns_token) values (v_b, repeat('ab', 32));
  insert into public.saved_events (user_id, event_id) values (v_b, v_pub);

  insert into t_ctx values ('a', v_a), ('b', v_b), ('owner', v_org_owner), ('org', v_org), ('org_pending', v_org_pending),
    ('pub', v_pub), ('draft', v_draft), ('pending_event', v_pending_event), ('tier', v_tier),
    ('order_a', v_order_a), ('order_b', v_order_b);
end
$$;

-- ---------------------------------------------------------------------------
-- User A sees only their own rows
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid := (select id from t_ctx where key = 'a');
  v_b uuid := (select id from t_ctx where key = 'b');
  v_n_b uuid;
begin
  select id into v_n_b from public.notifications where user_id = v_b limit 1;
  perform tests.as_user(v_a);

  perform tests.is((select count(*)::int from public.wallets), 1, 'A sees exactly one wallet');
  perform tests.is((select user_id from public.wallets), v_a, 'the wallet A sees is A''s');
  perform tests.is((select count(*)::int from public.wallets where user_id = v_b), 0, 'A cannot read B''s wallet');
  perform tests.is((select count(*)::int from public.wallet_ledger where user_id = v_b), 0, 'A cannot read B''s ledger');
  perform tests.ok((select count(*) from public.wallet_ledger) >= 1 and not exists (select 1 from public.wallet_ledger where user_id <> v_a),
                   'A reads only own ledger rows');
  perform tests.is((select count(*)::int from public.orders), 1, 'A sees only own orders');
  perform tests.is((select count(*)::int from public.orders where user_id = v_b), 0, 'A cannot read B''s orders');
  perform tests.is((select count(*)::int from public.order_items), 1, 'A sees only own order items');
  perform tests.is((select count(*)::int from public.notifications where user_id = v_b), 0, 'A cannot read B''s notifications');
  perform tests.is((select count(*)::int from public.profiles), 1, 'A sees only own profile');
  perform tests.is((select count(*)::int from public.push_devices), 0, 'A cannot read B''s push devices');
  perform tests.is((select count(*)::int from public.saved_events), 0, 'A cannot read B''s saved events');
  perform tests.is((select count(*)::int from public.notification_preferences), 1, 'A sees only own notification preferences');
  perform tests.throws_state('select * from public.tickets', '42501', 'tickets are not directly readable (RPC only)');
  perform tests.throws_state('select * from public.registrations', '42501', 'registrations are not directly readable (RPC only)');
  perform tests.throws_state('select * from public.payments', '42501', 'payments are not readable by clients');
  perform tests.throws_state('select * from public.identity_digests', '42501', 'identity_digests not readable by authenticated');
  perform tests.is(jsonb_array_length(public.my_tickets()), 0, 'my_tickets() returns nothing of B''s for A');

  -- Writes that must be impossible
  perform tests.throws_state(format('update public.wallets set balance_minor = 999999 where user_id = %L', v_a), '42501',
                             'client cannot update own wallet balance');
  perform tests.throws_state(format($q$insert into public.wallet_ledger (user_id, entry_type, amount_minor, reference_type) values (%L, 'topup', 100, 'manual')$q$, v_a),
                             '42501', 'client cannot insert ledger rows');
  perform tests.throws_state(format($q$update public.orders set status = 'paid' where user_id = %L$q$, v_a), '42501',
                             'client cannot change order status');
  perform tests.throws_state(format($q$update public.notifications set read_at = now() where user_id = %L$q$, v_a), '42501',
                             'notification read state changes only through RPCs');
  perform tests.throws_state(format($q$update public.profiles set identity_status = 'verified_unique' where id = %L$q$, v_a), '42501',
                             'client cannot set identity_status');
  perform tests.lives(format($q$update public.profiles set display_name = 'Alice A', language = 'si' where id = %L$q$, v_a),
                      'client can update editable profile columns');
  perform tests.throws_state(format($q$update public.profiles set language = 'fr' where id = %L$q$, v_a), '23514',
                             'profile language is constrained to en|si|ta');
  perform tests.is(public.mark_notifications_read(array[v_n_b]), 0, 'A cannot mark B''s notification read');
  perform tests.ok(public.mark_all_notifications_read() >= 1, 'A can mark own notifications read');
  perform tests.lives(format('update public.notification_preferences set push_enabled = false where user_id = %L', v_a),
                      'client can update own notification preferences');
  perform tests.lives(format($q$insert into public.push_devices (apns_token, environment) values (%L, 'sandbox')$q$, repeat('cd', 32)),
                      'client can register a push device (user_id defaults to auth.uid())');
  perform tests.throws_state(format($q$insert into public.push_devices (user_id, apns_token) values (%L, %L)$q$, v_b, repeat('ef', 32)),
                             '42501', 'client cannot register a push device for another user');
  perform tests.throws_state(format($q$insert into public.saved_events (user_id, event_id) values (%L, %L)$q$,
                                    v_b, (select id from t_ctx where key = 'pub')),
                             '42501', 'client cannot save events for another user');
  perform tests.lives(format($q$insert into public.saved_events (event_id) values (%L)$q$, (select id from t_ctx where key = 'pub')),
                      'client can save a published event');
  perform tests.throws_state(format($q$insert into public.saved_events (event_id) values (%L)$q$, (select id from t_ctx where key = 'draft')),
                             '42501', 'client cannot save an unpublished event');
  perform tests.throws_state(format($q$select public.create_payment_order(%L, 'wallet_topup', null, null, 100000, 'abcdefgh-1')$q$, v_a),
                             '42501', 'authenticated cannot call create_payment_order');
  perform tests.throws_state(format($q$select public.apply_payhere_notification(%L, 'p1', 2, 150000, 'LKR')$q$,
                                    (select id from t_ctx where key = 'order_a')),
                             '42501', 'authenticated cannot call apply_payhere_notification');
  perform tests.as_postgres();
  perform tests.is((select count(*)::int from public.notifications where user_id = v_b and read_at is null), 1,
                   'B''s notification stayed unread');
  perform tests.is(tests.balance(v_a), 5000::bigint, 'A''s balance unchanged after write attempts');
end
$$;

-- ---------------------------------------------------------------------------
-- anon sees only published events of verified organizers, public columns only
-- ---------------------------------------------------------------------------
do $$
declare
  v_pub uuid := (select id from t_ctx where key = 'pub');
  v_draft uuid := (select id from t_ctx where key = 'draft');
begin
  perform tests.as_anon();
  perform tests.is((select count(*)::int from public.events where status <> 'published'), 0, 'anon sees no unpublished events');
  perform tests.is((select count(*)::int from public.events where id = v_draft), 0, 'anon cannot read a draft');
  perform tests.is((select count(*)::int from public.event_cards where status <> 'published'), 0, 'anon event_cards are published only');
  perform tests.is((select count(*)::int from public.event_cards where id = v_pub), 1, 'anon sees the published event card');
  perform tests.throws_state('select online_url from public.events', '42501', 'anon cannot read events.online_url');
  perform tests.throws_state('select contact_email from public.organizer_profiles', '42501', 'anon cannot read organizer contact e-mail');
  perform tests.is((select count(*)::int from public.organizer_profiles where id = (select id from t_ctx where key = 'org_pending')), 0,
                   'anon cannot see unverified organizers');
  perform tests.ok((select count(*) from public.organizer_profiles) > 0, 'anon can list verified organizers (public columns)');
  perform tests.is((select count(*)::int from public.ticket_tiers where event_id = v_draft), 0, 'anon cannot read draft tiers');
  perform tests.is((select count(*)::int from public.ticket_tiers where event_id = v_pub), 1, 'anon can read published tiers');
  perform tests.throws_state('select * from public.wallets', '42501', 'anon cannot read wallets');
  perform tests.throws_state('select * from public.notifications', '42501', 'anon cannot read notifications');
  perform tests.throws_state('select public.my_tickets()', '42501', 'anon cannot call my_tickets');
  perform tests.throws($q$select public.get_event_detail('$q$ || v_draft || $q$')$q$, 'event_not_found',
                       'get_event_detail hides drafts from anon');
  perform tests.is(public.get_event_detail(v_pub) -> 'event' ->> 'online_url', null::text,
                   'get_event_detail hides online_url from non-attendees');
  perform tests.throws_state($q$insert into public.saved_events (event_id) values (gen_random_uuid())$q$, '42501',
                             'anon cannot write');
  perform tests.as_postgres();
end
$$;

-- ---------------------------------------------------------------------------
-- Organizer: own drafts editable, published events frozen, server columns
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_b uuid := (select id from t_ctx where key = 'b');
  v_org uuid := (select id from t_ctx where key = 'org');
  v_pub uuid := (select id from t_ctx where key = 'pub');
  v_draft uuid := (select id from t_ctx where key = 'draft');
  v_tier uuid := (select id from t_ctx where key = 'tier');
  v_new uuid := gen_random_uuid();
  v_rows int;
begin
  perform tests.as_user(v_owner);
  perform tests.is((select count(*)::int from public.events where id = v_draft), 1, 'organizer sees own draft');
  perform tests.is((select count(*)::int from public.event_cards where id = v_draft), 1, 'organizer sees own draft card');
  perform tests.lives(format($q$update public.events set title = 'Renamed draft' where id = %L$q$, v_draft),
                      'organizer can edit own draft');
  update public.events set title = 'Hijacked' where id = v_pub;
  get diagnostics v_rows = row_count;
  perform tests.is(v_rows, 0, 'organizer cannot edit a published event (RLS: draft only)');
  update public.ticket_tiers set price_minor = 1 where id = v_tier;
  get diagnostics v_rows = row_count;
  perform tests.is(v_rows, 0, 'organizer cannot change tier prices after publication');
  perform tests.throws_state(format($q$update public.events set status = 'published' where id = %L$q$, v_draft), '42501',
                             'organizer cannot set event status');
  perform tests.throws_state(format('update public.events set seats_taken = 0 where id = %L', v_draft), '42501',
                             'organizer cannot set seats_taken');
  perform tests.throws_state(format('update public.ticket_tiers set sold = 0 where id = %L', v_tier), '42501',
                             'organizer cannot set tier sold');
  perform tests.throws_state(format($q$update public.organizer_profiles set verification_status = 'verified' where id = %L$q$, v_org),
                             '42501', 'organizer cannot self-verify');
  perform tests.throws_state(format($q$insert into public.events (organizer_id, category_id, title, starts_at, ends_at, status)
                                       values (%L, 'technology', 'x', now() + interval '2 days', now() + interval '3 days', 'published')$q$, v_org),
                             '42501', 'organizer cannot insert a published event');
  perform tests.lives(format($q$insert into public.events (id, organizer_id, category_id, title, starts_at, ends_at)
                                values (%L, %L, 'technology', 'New draft', now() + interval '2 days', now() + interval '3 days')$q$, v_new, v_org),
                      'organizer can create a draft event');
  perform tests.is((select status from public.events where id = v_new), 'draft', 'new events default to draft');
  perform tests.throws_state(format($q$insert into public.events (organizer_id, category_id, title, starts_at, ends_at)
                                       values (%L, 'technology', 'x', now() + interval '2 days', now() + interval '3 days')$q$,
                                    (select id from t_ctx where key = 'org_pending')),
                             '42501', 'organizer cannot create events for another organizer');
  perform tests.lives(format($q$insert into public.ticket_tiers (event_id, name, price_minor, quantity) values (%L, 'GA', 1000, 10)$q$, v_new),
                      'organizer can add tiers to own draft');
  perform tests.throws_state(format($q$insert into public.ticket_tiers (event_id, name, price_minor, quantity) values (%L, 'GA', 1000, 10)$q$, v_pub),
                             '42501', 'organizer cannot add tiers to a published event');
  perform tests.throws_state(format($q$insert into public.organizer_profiles (name, slug) values ('Second org', 'second-org-x')$q$),
                             '23505', 'one organizer profile per owner');
  perform tests.as_user(v_b);
  perform tests.is((select count(*)::int from public.events where id = v_draft), 0, 'other users cannot see a draft');
  update public.events set title = 'Hijacked' where id = v_draft;
  get diagnostics v_rows = row_count;
  perform tests.is(v_rows, 0, 'other users cannot edit someone else''s draft');
  perform tests.lives($q$insert into public.organizer_profiles (name, slug) values ('Bob Events', 'bob-events-x')$q$,
                      'a user can create their own organizer profile');
  perform tests.is((select verification_status from public.organizer_profiles where slug = 'bob-events-x'), 'pending',
                   'new organizer profiles start pending');
  perform tests.as_postgres();
end
$$;

-- ---------------------------------------------------------------------------
-- ai_drafts review and service role boundaries
-- ---------------------------------------------------------------------------
do $$
declare
  v_owner uuid := (select id from t_ctx where key = 'owner');
  v_org uuid := (select id from t_ctx where key = 'org');
  v_draft uuid := (select id from t_ctx where key = 'draft');
  v_ai uuid;
  v_rows int;
begin
  insert into public.ai_drafts (event_id, organizer_id, kind, status, request_id, content)
  values (v_draft, v_org, 'agenda', 'succeeded', 'request-0001', '{"agenda": []}') returning id into v_ai;

  perform tests.as_user((select id from t_ctx where key = 'a'));
  perform tests.is((select count(*)::int from public.ai_drafts), 0, 'non-owners cannot read AI drafts');
  perform tests.as_user(v_owner);
  perform tests.lives(format($q$update public.ai_drafts set status = 'approved' where id = %L$q$, v_ai),
                      'organizer can approve an AI draft');
  perform tests.throws_state(format($q$update public.ai_drafts set status = 'succeeded' where id = %L$q$, v_ai), '42501',
                             'organizer cannot set an AI draft back to succeeded');
  perform tests.throws_state(format($q$update public.ai_drafts set content = '{}' where id = %L$q$, v_ai), '42501',
                             'organizer cannot edit AI draft content');

  perform tests.as_service();
  perform tests.ok((select count(*) from public.orders) >= 2, 'service_role bypasses RLS for reads');
  perform tests.throws_state(format('update public.wallets set balance_minor = 1 where user_id = %L', (select id from t_ctx where key = 'a')),
                             '42501', 'service_role cannot update wallet balances directly');
  perform tests.throws_state('select * from public.identity_digests', '42501', 'service_role cannot read identity_digests');
  perform tests.as_postgres();
end
$$;

rollback;
