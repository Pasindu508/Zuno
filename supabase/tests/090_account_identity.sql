-- 090: identity digests (NIC uniqueness), identity mirror and account deletion
begin;

do $$
declare
  v_a uuid := tests.new_user('ida', false);
  v_b uuid := tests.new_user('idb', false);
  v_digest text := encode(extensions.digest('example-digest-input', 'sha256'), 'hex');
  v_other text := encode(extensions.digest('another-input', 'sha256'), 'hex');
  v_event uuid;
begin
  perform tests.as_user(v_a);
  perform tests.throws_state(format($q$select public.record_identity_digest(%L, %L, 1)$q$, v_a, v_digest), '42501',
                             'clients cannot record identity digests directly');
  perform tests.as_service();
  perform tests.is(public.record_identity_digest(v_a, v_digest, 1) ->> 'status', 'verified_unique', 'first holder of a NIC is verified_unique');
  perform tests.is(public.record_identity_digest(v_a, v_digest, 1) ->> 'status', 'verified_unique', 're-submitting the same NIC is idempotent');
  perform tests.is(public.record_identity_digest(v_b, v_digest, 1) ->> 'status', 'duplicate', 'second account with the same NIC is duplicate');
  perform tests.throws(format($q$select public.record_identity_digest(%L, %L, 1)$q$, v_a, v_other), 'already_verified',
                       'a verified account cannot switch to another NIC');
  perform tests.throws(format($q$select public.record_identity_digest(%L, 'NOT-HEX', 1)$q$, v_a), 'invalid_digest',
                       'digest must be 64 lowercase hex chars');
  perform tests.throws_state('select * from public.identity_digests', '42501', 'service_role has no table access to digests');
  perform tests.as_postgres();
  perform tests.is((select identity_status from public.profiles where id = v_a), 'verified_unique', 'profile marked verified_unique');
  perform tests.is((select identity_status from public.profiles where id = v_b), 'duplicate', 'profile marked duplicate');
  perform tests.is((select count(*)::int from public.identity_digests), 1, 'only one digest stored per NIC');
  perform tests.ok(not exists (select 1 from public.audit_events where data::text like '%' || v_digest || '%'),
                   'digests are not copied into the audit log');
  v_event := tests.new_event(tests.new_organizer(tests.new_user('o'), true));
  perform tests.as_user(v_b);
  perform tests.is(public.quote_free_registration(v_event) ->> 'reason',
                   'identity_required', 'duplicate identities cannot use the free allowance');
  perform tests.as_postgres();
end
$$;

-- user_identities mirror
do $$
declare
  v_u uuid := tests.new_user('linker');
  v_identity uuid;
begin
  insert into auth.identities (provider_id, user_id, identity_data, provider)
  values ('apple-sub-123', v_u, '{"sub":"apple-sub-123"}', 'apple') returning id into v_identity;
  perform tests.is((select provider from public.user_identities where identity_id = v_identity::text), 'apple',
                   'linking a provider mirrors into user_identities');
  perform tests.as_user(v_u);
  perform tests.is((select count(*)::int from public.user_identities), 1, 'user can read own linked identities');
  perform tests.as_postgres();
  delete from auth.identities where id = v_identity;
  perform tests.ok((select unlinked_at is not null from public.user_identities where identity_id = v_identity::text),
                   'unlinking sets unlinked_at');
end
$$;

-- Account deletion: anonymise retained records, free seats, remove personal rows
do $$
declare
  v_owner uuid := tests.new_user('owner');
  v_org uuid := tests.new_organizer(v_owner, true);
  v_ev uuid := tests.new_event(v_org, true, 1);
  v_paid uuid := tests.new_event(v_org, false, 10);
  v_tier uuid := tests.new_tier(v_paid, 2000, 10);
  v_q uuid := tests.new_question(v_ev, 'short_text', false);
  v_doomed uuid := tests.new_user('doomed');
  v_waiter uuid := tests.new_user('waiter');
  v_order uuid;
  v_res jsonb;
begin
  perform tests.fund_wallet(v_doomed, 5000);
  perform tests.as_user(v_doomed);
  perform public.register_for_free_event(v_ev, jsonb_build_array(jsonb_build_object('question_id', v_q, 'value', 'personal answer')), 0, 'del-key-0001');
  perform tests.as_user(v_waiter);
  perform public.join_waitlist(v_ev);
  perform tests.as_service();
  v_order := (public.create_payment_order(v_doomed, 'ticket', v_paid, jsonb_build_array(jsonb_build_object('tier_id', v_tier, 'quantity', 1)),
                                          null, 'del-order-01') ->> 'order_id')::uuid;
  perform tests.as_postgres();
  perform tests.notify_payhere(v_order, 'PH-DEL-1', 2, 2000);

  perform tests.as_service();
  perform tests.throws(format('select public.prepare_account_deletion(%L)', v_owner), 'organizer_has_active_events',
                       'organizers with live events must cancel or finish them first');
  v_res := public.prepare_account_deletion(v_doomed);
  perform tests.is(v_res ->> 'avatar_prefix', v_doomed::text, 'prepare_account_deletion reports the avatar prefix');
  perform tests.as_postgres();

  delete from auth.users where id = v_doomed;   -- what auth.admin.deleteUser does

  perform tests.ok(not exists (select 1 from public.profiles where id = v_doomed), 'profile removed');
  perform tests.ok(not exists (select 1 from public.wallets where user_id = v_doomed), 'wallet removed');
  perform tests.ok(not exists (select 1 from public.notifications where user_id = v_doomed), 'notifications removed');
  perform tests.is((select count(*)::int from public.wallet_ledger where user_id is null and description = 'test funding'), 1,
                   'ledger history retained but anonymised');
  perform tests.ok(exists (select 1 from public.orders where id = v_order and user_id is null and status = 'paid'),
                   'paid order retained for accounting without the user');
  perform tests.ok(exists (select 1 from public.payments where order_id = v_order), 'payment record retained');
  perform tests.ok(not exists (select 1 from public.registration_answers a join public.registrations r on r.id = a.registration_id
                                where r.event_id = v_ev), 'personal answers deleted');
  perform tests.ok(not exists (select 1 from public.tickets where attendee_name = 'Doomed'), 'attendee names scrubbed from tickets');
  perform tests.is((select status from public.registrations where user_id = v_waiter and event_id = v_ev), 'offered',
                   'freed seat offered to the next waitlisted user');
  perform tests.ok(exists (select 1 from public.audit_events where action = 'account_anonymised' and entity_id = v_doomed),
                   'anonymisation audited');
  perform tests.is((select sold from public.ticket_tiers where id = v_tier), 0, 'forfeited paid ticket returned to inventory');
end
$$;

rollback;
