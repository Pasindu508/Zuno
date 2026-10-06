-- 110: real concurrency with two sessions (dblink). Proves the FOR UPDATE
-- locking order: a competing registration for the last seat waits for the
-- event row lock and then sees sold_out; a concurrent idempotent replay
-- returns the original result; a concurrent second scan of a ticket waits
-- and reports already_used.
-- NOTE: fixtures are committed through a separate dblink session (the other
-- sessions must see them). This file runs last; it skips if dblink is absent.
do $$
declare
  v_conn text := format('host=127.0.0.1 port=%s dbname=%s user=postgres', current_setting('port'), current_database());
  v_fx jsonb;
  v_event uuid;
  v_u1 uuid;
  v_u2 uuid;
  v_owner uuid;
  v_ticket_code text;
  v_a text;
  v_b text;
  v_busy int;
begin
  if not exists (select 1 from pg_available_extensions where name = 'dblink') then
    raise notice 'SKIP: dblink extension not available - concurrency tests skipped';
    return;
  end if;
  execute 'create extension if not exists dblink';

  -- Committed fixtures (autocommit session).
  perform dblink_connect('zuno_setup', v_conn);
  select x::jsonb into v_fx from dblink('zuno_setup', $q$
    select jsonb_build_object(
      'owner', o.owner, 'event', tests.new_event(o.org, true, 1), 'u1', tests.new_user('race1'), 'u2', tests.new_user('race2'),
      'scan_event', tests.new_event(o.org, true, 10))::text
    from (select owner, tests.new_organizer(owner, true) as org from (select tests.new_user('raceowner') as owner) s) o
  $q$) as t(x text);
  v_event := (v_fx ->> 'event')::uuid;
  v_u1 := (v_fx ->> 'u1')::uuid;
  v_u2 := (v_fx ->> 'u2')::uuid;
  v_owner := (v_fx ->> 'owner')::uuid;

  -- (1) Last seat race ------------------------------------------------------
  perform dblink_connect('zuno_a', v_conn);
  perform dblink_connect('zuno_b', v_conn);
  perform dblink_exec('zuno_a', 'begin');
  perform dblink_exec('zuno_a', format('set local request.jwt.claims = %L', json_build_object('sub', v_u1, 'role', 'authenticated')));
  perform dblink_exec('zuno_a', 'set local role authenticated');
  select r into v_a from dblink('zuno_a', format($q$select public.register_for_free_event(%L, '[]', 0, 'race-key-0001') ->> 'status'$q$, v_event)) as t(r text);
  perform tests.is(v_a, 'confirmed', 'session A takes the last seat (uncommitted, holding the event lock)');

  perform dblink_exec('zuno_b', 'begin');
  perform dblink_exec('zuno_b', format('set local request.jwt.claims = %L', json_build_object('sub', v_u2, 'role', 'authenticated')));
  perform dblink_exec('zuno_b', 'set local role authenticated');
  perform dblink_send_query('zuno_b', format($q$
    select coalesce((select public.register_for_free_event(%L, '[]', 0, 'race-key-0002') ->> 'status'), 'none')
  $q$, v_event));
  perform pg_sleep(0.5);
  v_busy := dblink_is_busy('zuno_b');
  perform tests.is(v_busy, 1, 'session B blocks on the event row lock while A is uncommitted');
  perform dblink_exec('zuno_a', 'commit');
  -- fail_on_error = false: the remote error is reported via dblink_error_message.
  select r into v_b from dblink_get_result('zuno_b', false) as t(r text);
  v_b := coalesce(v_b, dblink_error_message('zuno_b'));
  perform * from dblink_get_result('zuno_b', false) as t(r text);  -- drain (async protocol)
  perform tests.ok(v_b like '%sold_out%', 'after A commits, B sees sold_out (got: ' || coalesce(v_b, 'null') || ')');
  perform dblink_exec('zuno_b', 'rollback');
  perform tests.is((select seats_taken from public.events where id = v_event), 1, 'capacity 1 -> exactly one seat taken');
  perform tests.is((select count(*)::int from public.registrations where event_id = v_event and status = 'confirmed'), 1,
                   'exactly one confirmed registration');

  -- (2) Concurrent idempotent replay -----------------------------------------
  perform dblink_exec('zuno_a', 'begin');
  perform dblink_exec('zuno_a', format('set local request.jwt.claims = %L', json_build_object('sub', v_u2, 'role', 'authenticated')));
  perform dblink_exec('zuno_a', 'set local role authenticated');
  select r into v_a from dblink('zuno_a', format($q$select public.register_for_free_event(%L, '[]', 0, 'same-key-0001') ->> 'registration_id'$q$,
                                                (v_fx ->> 'scan_event'))) as t(r text);
  perform dblink_exec('zuno_b', 'begin');
  perform dblink_exec('zuno_b', format('set local request.jwt.claims = %L', json_build_object('sub', v_u2, 'role', 'authenticated')));
  perform dblink_exec('zuno_b', 'set local role authenticated');
  perform dblink_send_query('zuno_b', format($q$select public.register_for_free_event(%L, '[]', 0, 'same-key-0001') ->> 'registration_id'$q$,
                                             (v_fx ->> 'scan_event')));
  perform pg_sleep(0.3);
  perform dblink_exec('zuno_a', 'commit');
  select r into v_b from dblink_get_result('zuno_b') as t(r text);
  perform * from dblink_get_result('zuno_b') as t(r text);  -- drain (async protocol)
  perform dblink_exec('zuno_b', 'commit');
  perform tests.is(v_b, v_a, 'a concurrent request with the same idempotency key returns the original registration');
  perform tests.is((select count(*)::int from public.registrations where user_id = v_u2 and event_id = (v_fx ->> 'scan_event')::uuid), 1,
                   'no duplicate registration from the concurrent replay');

  -- (3) Concurrent double scan -------------------------------------------------
  select t.code into v_ticket_code from public.tickets t
    join public.registrations r on r.id = t.registration_id
   where r.id = v_a::uuid;
  perform dblink_exec('zuno_a', 'begin');
  perform dblink_exec('zuno_a', format('set local request.jwt.claims = %L', json_build_object('sub', v_owner, 'role', 'authenticated')));
  perform dblink_exec('zuno_a', 'set local role authenticated');
  select r into v_a from dblink('zuno_a', format($q$select public.check_in_ticket(%L, %L) ->> 'result'$q$, (v_fx ->> 'scan_event'), v_ticket_code)) as t(r text);
  perform dblink_exec('zuno_b', 'begin');
  perform dblink_exec('zuno_b', format('set local request.jwt.claims = %L', json_build_object('sub', v_owner, 'role', 'authenticated')));
  perform dblink_exec('zuno_b', 'set local role authenticated');
  perform dblink_send_query('zuno_b', format($q$select public.check_in_ticket(%L, %L) ->> 'result'$q$, (v_fx ->> 'scan_event'), v_ticket_code));
  perform pg_sleep(0.3);
  perform tests.is(dblink_is_busy('zuno_b'), 1, 'second scanner waits on the ticket row');
  perform dblink_exec('zuno_a', 'commit');
  select r into v_b from dblink_get_result('zuno_b') as t(r text);
  perform * from dblink_get_result('zuno_b') as t(r text);  -- drain (async protocol)
  perform dblink_exec('zuno_b', 'commit');
  perform tests.is(v_a, 'valid', 'first concurrent scan is valid');
  perform tests.is(v_b, 'already_used', 'second concurrent scan is already_used');
  perform tests.is((select count(*)::int from public.check_ins c join public.tickets t on t.id = c.ticket_id where t.code = v_ticket_code), 1,
                   'exactly one check-in row');

  perform dblink_disconnect('zuno_a');
  perform dblink_disconnect('zuno_b');
  perform dblink_disconnect('zuno_setup');
end
$$;
