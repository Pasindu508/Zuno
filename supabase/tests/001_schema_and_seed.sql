-- 001: schema hardening invariants and seed integrity
begin;
do $$
declare
  v_dev constant uuid := 'b0000000-0000-4000-8000-0000000000aa';
  v_swift constant uuid := 'e1000000-0000-4000-8000-000000000002';
begin
  -- Hardening ---------------------------------------------------------------
  perform tests.ok(not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
    'RLS is enabled on every public table');

  perform tests.ok(not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private') and p.prosecdef
       and not coalesce(p.proconfig @> array['search_path=""'], false)),
    'every SECURITY DEFINER function pins search_path to empty');

  perform tests.ok(not exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and grantee in ('anon', 'authenticated')
       and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')),
    'API roles have no TRUNCATE/REFERENCES/TRIGGER privileges');

  perform tests.ok(not exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and grantee = 'anon' and privilege_type <> 'SELECT'),
    'anon has no write privilege on any public table');

  perform tests.ok(
    not has_table_privilege('anon', 'public.registrations', 'select')
    and not has_table_privilege('authenticated', 'public.registrations', 'select')
    and not has_table_privilege('authenticated', 'public.tickets', 'select')
    and not has_table_privilege('authenticated', 'public.payments', 'select')
    and not has_table_privilege('authenticated', 'public.check_ins', 'select')
    and not has_table_privilege('authenticated', 'public.audit_events', 'select')
    and not has_table_privilege('authenticated', 'public.rate_limits', 'select')
    and not has_table_privilege('authenticated', 'public.allowance_usage', 'select')
    and not has_table_privilege('authenticated', 'public.registration_answers', 'select'),
    'server-only tables are not readable by clients');

  perform tests.ok(
    not has_table_privilege('anon', 'public.identity_digests', 'select')
    and not has_table_privilege('authenticated', 'public.identity_digests', 'select')
    and not has_table_privilege('service_role', 'public.identity_digests', 'select')
    and not has_table_privilege('service_role', 'public.identity_digests', 'insert'),
    'identity_digests has no table access for any API role');

  perform tests.ok(
    not has_table_privilege('service_role', 'public.wallets', 'update')
    and not has_table_privilege('service_role', 'public.wallet_ledger', 'insert')
    and not has_table_privilege('service_role', 'public.wallet_ledger', 'update')
    and not has_table_privilege('service_role', 'public.wallet_ledger', 'delete'),
    'service_role cannot write wallets or the ledger directly');

  perform tests.ok(
    not has_column_privilege('authenticated', 'public.profiles', 'identity_status', 'update')
    and not has_column_privilege('authenticated', 'public.profiles', 'identity_status', 'insert'),
    'clients cannot set profiles.identity_status');
  perform tests.ok(
    not has_column_privilege('authenticated', 'public.organizer_profiles', 'verification_status', 'update')
    and not has_column_privilege('authenticated', 'public.organizer_profiles', 'verification_status', 'insert'),
    'clients cannot set organizer verification_status');
  perform tests.ok(
    not has_column_privilege('authenticated', 'public.events', 'status', 'update')
    and not has_column_privilege('authenticated', 'public.events', 'status', 'insert')
    and not has_column_privilege('authenticated', 'public.events', 'seats_taken', 'update')
    and not has_column_privilege('authenticated', 'public.events', 'creation_fee_paid_at', 'update')
    and not has_column_privilege('authenticated', 'public.events', 'published_at', 'insert'),
    'clients cannot set event status, seats_taken, creation_fee_paid_at or published_at');
  perform tests.ok(
    not has_column_privilege('authenticated', 'public.ticket_tiers', 'sold', 'update')
    and not has_column_privilege('authenticated', 'public.ticket_tiers', 'reserved', 'update')
    and not has_column_privilege('authenticated', 'public.ticket_tiers', 'sold', 'insert'),
    'clients cannot set tier sold/reserved counters');
  perform tests.ok(
    not has_table_privilege('authenticated', 'public.orders', 'update')
    and not has_table_privilege('authenticated', 'public.orders', 'insert')
    and not has_table_privilege('authenticated', 'public.wallets', 'update')
    and not has_table_privilege('authenticated', 'public.wallet_ledger', 'insert')
    and not has_table_privilege('authenticated', 'public.notifications', 'update'),
    'clients cannot write orders, wallets, ledger or notification state');
  perform tests.ok(
    not has_column_privilege('anon', 'public.events', 'online_url', 'select')
    and not has_column_privilege('anon', 'public.organizer_profiles', 'contact_email', 'select')
    and not has_column_privilege('anon', 'public.organizer_profiles', 'owner_id', 'select'),
    'anon cannot read online_url, organizer contact e-mail or owner');

  perform tests.ok(
    not has_function_privilege('authenticated', 'public.create_payment_order(uuid, text, uuid, jsonb, bigint, text, jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public.apply_payhere_notification(uuid, text, integer, bigint, text, text, jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public.expire_stale_orders()', 'execute')
    and not has_function_privilege('authenticated', 'public.rate_limit_hit(text, integer, integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.record_identity_digest(uuid, text, integer)', 'execute')
    and not has_function_privilege('authenticated', 'public.prepare_account_deletion(uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.organizer_export_data(uuid, uuid)', 'execute'),
    'payment/identity/maintenance RPCs are not executable by authenticated');
  perform tests.ok(
    has_function_privilege('service_role', 'public.create_payment_order(uuid, text, uuid, jsonb, bigint, text, jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.apply_payhere_notification(uuid, text, integer, bigint, text, text, jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.expire_stale_orders()', 'execute'),
    'service-role-only RPCs are executable by service_role');
  perform tests.ok(
    has_function_privilege('anon', 'public.search_events(text, jsonb, integer, integer)', 'execute')
    and has_function_privilege('anon', 'public.get_event_detail(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.register_for_free_event(uuid, jsonb, bigint, text)', 'execute')
    and not has_function_privilege('anon', 'public.my_tickets()', 'execute')
    and not has_function_privilege('anon', 'public.check_in_ticket(uuid, text)', 'execute'),
    'anon may only call search_events and get_event_detail');
  perform tests.ok(not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private') and has_function_privilege('public', p.oid, 'execute')),
    'no function is executable by PUBLIC');

  perform tests.is((select count(*)::int from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public'
                       and tablename in ('notifications', 'orders', 'wallet_ledger')), 3,
                   'Realtime publication contains notifications, orders, wallet_ledger');
  perform tests.ok(exists (
    select 1 from storage.buckets where id = 'event-media' and public and file_size_limit = 8388608
      and allowed_mime_types @> array['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
    'event-media bucket: public, 8 MB, image types');
  perform tests.ok(exists (
    select 1 from storage.buckets where id = 'avatars' and not public and file_size_limit = 3145728),
    'avatars bucket: private, 3 MB');

  -- Platform settings constraint ----------------------------------------------
  perform tests.throws_state($q$update public.platform_settings set value = 249 where key = 'extra_free_registration_fee_minor'$q$,
                             '23514', 'extra fee below 250 is rejected');
  perform tests.throws_state($q$update public.platform_settings set value = 301 where key = 'extra_free_registration_fee_minor'$q$,
                             '23514', 'extra fee above 300 is rejected');
  perform tests.lives($q$update public.platform_settings set value = 300 where key = 'extra_free_registration_fee_minor'$q$,
                      'extra fee of 300 is accepted');
  perform tests.is((select value from public.platform_settings where key = 'commission_bps'), 500::bigint,
                   'commission default is 500 bps');

  -- Seed --------------------------------------------------------------------
  perform tests.is((select count(*)::int from public.events), 16, 'seed: 16 events');
  perform tests.is((select count(*)::int from public.categories), 10, 'seed: 10 categories');
  perform tests.is((select symbol_name from public.categories where id = 'hackathons'), 'laptopcomputer',
                   'seed: category symbols come from zuno_seed.json');
  perform tests.is((select count(*)::int from public.organizer_profiles where verification_status = 'verified'), 5,
                   'seed: 5 verified organizers');
  perform tests.is((select count(*)::int from public.events where status = 'completed'), 1,
                   'seed: the event that already ended is completed');
  perform tests.ok(not exists (select 1 from auth.users where email not like '%.example'),
                   'seed: every auth user uses a .example address');
  perform tests.is((select count(*)::int from public.profiles), (select count(*)::int from auth.users),
                   'handle_new_user created a profile per auth user');
  perform tests.is((select count(*)::int from public.wallets), (select count(*)::int from auth.users),
                   'handle_new_user created a wallet per auth user');
  perform tests.is((select count(*)::int from public.notification_preferences), (select count(*)::int from auth.users),
                   'handle_new_user created notification preferences per auth user');
  perform tests.is((select count(*)::int from public.user_identities where unlinked_at is null),
                   (select count(*)::int from auth.identities),
                   'user_identities mirrors auth.identities');
  perform tests.is(tests.balance(v_dev), 14000::bigint, 'seed: development wallet balance is 14000');
  perform tests.is(tests.ledger_sum(v_dev), tests.balance(v_dev), 'seed: development ledger sums to the balance');
  perform tests.ok(not exists (
    select 1 from public.wallets w
     where w.balance_minor <> coalesce((select sum(l.amount_minor) from public.wallet_ledger l
                                         where l.user_id = w.user_id and l.status = 'posted'), 0)),
    'every wallet reconciles with its posted ledger entries');
  perform tests.is(tests.allowance_used(v_dev), 13, 'seed: 13 allowance registrations used this month');
  perform tests.is((select count(*)::int from public.tickets where user_id = v_dev), 4, 'seed: development user holds 4 tickets');
  perform tests.is((select count(*)::int from public.saved_events where user_id = v_dev), 3, 'seed: 3 saved events');
  perform tests.is((select identity_status from public.profiles where id = v_dev), 'verified_unique',
                   'seed: development user is identity-verified');
  perform tests.ok(not exists (
    select 1 from public.tickets
     where code !~ '^ZN-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$' or qr_token !~ '^[A-Za-z0-9_-]{43}$'),
    'ticket codes and QR tokens follow the contract formats');
  perform tests.ok(not exists (select 1 from public.registrations where reference !~ '^ZR-[0-9A-HJKMNP-TV-Z]{8}$'),
                   'registration references follow ZR-XXXXXXXX');
  perform tests.is(to_char((select starts_at from public.events where id = v_swift) at time zone 'Asia/Colombo', 'HH24:MI'),
                   '14:00', 'seed start_time is Asia/Colombo local time');
  perform tests.is(((select starts_at from public.events where id = v_swift) at time zone 'Asia/Colombo')::date
                   - (now() at time zone 'Asia/Colombo')::date, 2, 'seed start_offset_days is applied');
  perform tests.is((select cover_path from public.events where id = v_swift), 'seed/swiftui-workshop.jpg',
                   'seed cover_path is seed/<slug>.jpg');
  perform tests.is((select seats_taken from public.events where id = 'e1000000-0000-4000-8000-000000000006'),
                   188 + 71, 'seed: paid event seats_taken equals tickets sold');
  perform tests.is((select jsonb_array_length(agenda) from public.events where id = 'e1000000-0000-4000-8000-000000000001'), 4,
                   'seed agenda converted to timestamps');
  perform tests.is((select (agenda -> 3 ->> 'ends_at')::timestamptz - starts_at from public.events
                     where id = 'e1000000-0000-4000-8000-000000000001'), interval '36 hours',
                   'seed agenda offsets/durations are exact');
  perform tests.ok(not exists (
    select 1 from public.events e join public.venues v on v.id = e.venue_id where v.organizer_id <> e.organizer_id),
    'seed: every event uses a venue of its own organizer');
  perform tests.is((select commission_minor from public.orders where idempotency_key = 'seed-jazz-under-the-stars-dev'),
                   15000::bigint, 'seed order commission uses half-up rounding');
end
$$;
rollback;
