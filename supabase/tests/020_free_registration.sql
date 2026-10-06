-- 020: free registration - monthly allowance, fees, confirmation, rollback,
--      duplicates, capacity, idempotency, answers, identity
begin;

create temporary table t_ctx (key text primary key, id uuid) on commit drop;
grant all on t_ctx to anon, authenticated, service_role;

do $$
declare
  v_owner uuid := tests.new_user('owner');
  v_org uuid;
  v_events uuid[] := '{}';
begin
  v_org := tests.new_organizer(v_owner, true);
  for i in 1 .. 20 loop
    v_events := v_events || tests.new_event(v_org, true, 100);
  end loop;
  insert into t_ctx select 'ev' || i, v_events[i] from generate_series(1, 20) i;
  insert into t_ctx values ('org', v_org), ('owner', v_owner),
    ('u', tests.new_user('attendee')),
    ('tiny', tests.new_event(v_org, true, 1)),
    ('paid', tests.new_event(v_org, false, 10)),
    ('draft', tests.new_event(v_org, true, 10, 'draft')),
    ('closed', tests.new_event(v_org, true, 10)),
    ('quiz', tests.new_event(v_org, true, 10)),
    ('started_single', tests.new_event(v_org, true, 10)),
    ('started_multi', tests.new_event(v_org, true, 10));
  update public.events set registration_closes_at = now() - interval '1 minute' where id = (select id from t_ctx where key = 'closed');
  -- single session (3 h) that started an hour ago; multi-day (5 days) that started yesterday
  update public.events set starts_at = now() - interval '1 hour', ends_at = now() + interval '2 hours'
   where id = (select id from t_ctx where key = 'started_single');
  update public.events set starts_at = now() - interval '1 day', ends_at = now() + interval '4 days'
   where id = (select id from t_ctx where key = 'started_multi');
end
$$;

-- ---------------------------------------------------------------------------
-- Allowance: first registration is free, quote matches
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := (select id from t_ctx where key = 'u');
  v_ev1 uuid := (select id from t_ctx where key = 'ev1');
  v_quote jsonb;
  v_res jsonb;
  v_replay jsonb;
  v_seats int := tests.seats_taken(v_ev1);
begin
  perform tests.as_user(v_u);
  v_quote := public.quote_free_registration(v_ev1);
  perform tests.is((v_quote ->> 'allowance_limit')::int, 15, 'quote: allowance limit 15');
  perform tests.is((v_quote ->> 'allowance_used')::int, 0, 'quote: nothing used yet');
  perform tests.is((v_quote ->> 'fee_minor')::bigint, 0::bigint, 'quote: first registration is free');
  perform tests.is((v_quote ->> 'can_register')::boolean, true, 'quote: can register');
  perform tests.is(v_quote ->> 'month', to_char(now() at time zone 'Asia/Colombo', 'YYYY-MM'), 'quote: month is the Colombo month');
  perform tests.ok(v_quote ? 'reason' and v_quote -> 'reason' = 'null'::jsonb, 'quote: reason is null when allowed');

  v_res := public.register_for_free_event(v_ev1, '[]'::jsonb, 0, 'idem-key-0001');
  perform tests.is(v_res ->> 'status', 'confirmed', 'register: confirmed');
  perform tests.is((v_res ->> 'fee_minor')::bigint, 0::bigint, 'register: no fee within allowance');
  perform tests.is((v_res ->> 'allowance_remaining')::int, 14, 'register: allowance_remaining 14');
  perform tests.ok((v_res ->> 'reference') ~ '^ZR-[0-9A-HJKMNP-TV-Z]{8}$', 'register: reference format ZR-XXXXXXXX');
  perform tests.ok(v_res ? 'ticket_id' and v_res ? 'registration_id' and v_res ? 'wallet_balance_minor', 'register: response has contract keys');
  perform tests.is(jsonb_array_length(public.my_tickets()), 1, 'register: ticket issued');
  perform tests.is(public.my_tickets() -> 0 ->> 'status', 'valid', 'register: ticket is valid');

  -- Idempotent replay returns the original result; nothing new is created.
  v_replay := public.register_for_free_event(v_ev1, '[]'::jsonb, 0, 'idem-key-0001');
  perform tests.is(v_replay, v_res, 'replaying the idempotency key returns the original result');
  perform tests.is(jsonb_array_length(public.my_tickets()), 1, 'replay issues no second ticket');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'idem-key-0001')$q$,
                              (select id from t_ctx where key = 'ev2')),
                       'idempotency_conflict', 'reusing a key for another event is rejected');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'idem-key-0002')$q$, v_ev1),
                       'already_registered', 'duplicate registration is rejected');
  perform tests.is((public.quote_free_registration(v_ev1) ->> 'reason'), 'already_registered', 'quote reports already_registered');

  perform tests.as_postgres();
  perform tests.is(tests.seats_taken(v_ev1), v_seats + 1, 'seats_taken incremented exactly once');
  perform tests.is(tests.allowance_used(v_u), 1, 'allowance counter incremented exactly once');
  perform tests.is((select count(*)::int from public.notifications where user_id = v_u and kind = 'registration_confirmed'), 1,
                   'registration_confirmed notification written');
  perform tests.is((select count(*)::int from public.audit_events where actor_id = v_u and action = 'free_registration'), 1,
                   'registration audited');
  perform tests.is((select count(*)::int from public.wallet_ledger where user_id = v_u and entry_type = 'free_registration_fee'), 0,
                   'no ledger debit within the allowance');
end
$$;

-- ---------------------------------------------------------------------------
-- 15th registration still free; 16th costs the extra fee
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := (select id from t_ctx where key = 'u');
  v_ev2 uuid := (select id from t_ctx where key = 'ev2');
  v_ev3 uuid := (select id from t_ctx where key = 'ev3');
  v_ev4 uuid := (select id from t_ctx where key = 'ev4');
  v_res jsonb;
  v_seats3 int := tests.seats_taken(v_ev3);
  v_balance bigint;
begin
  perform tests.set_allowance_used(v_u, 14);
  perform tests.as_user(v_u);
  v_res := public.register_for_free_event(v_ev2, '[]'::jsonb, 0, 'idem-key-0015');
  perform tests.is((v_res ->> 'fee_minor')::bigint, 0::bigint, '15th registration of the month is free');
  perform tests.is((v_res ->> 'allowance_remaining')::int, 0, 'allowance exhausted after 15');

  perform tests.is((public.quote_free_registration(v_ev3) ->> 'fee_minor')::bigint, 250::bigint, '16th registration quotes the 250 fee');
  perform tests.is(public.quote_free_registration(v_ev3) ->> 'reason', 'insufficient_balance', 'quote: insufficient_balance with empty wallet');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'idem-key-0016')$q$, v_ev3),
                       'fee_changed', 'unconfirmed fee (expected 0, actual 250) is rejected with fee_changed');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', null, 'idem-key-0016')$q$, v_ev3),
                       'fee_changed', 'missing expected fee is rejected with fee_changed');

  -- Insufficient balance: everything rolls back.
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 250, 'idem-key-0016')$q$, v_ev3),
                       'insufficient_balance', 'fee with an empty wallet is rejected');
  perform tests.as_postgres();
  perform tests.is((select count(*)::int from public.registrations where user_id = v_u and event_id = v_ev3), 0,
                   'insufficient balance: no registration row');
  perform tests.is((select count(*)::int from public.wallet_ledger where user_id = v_u), 0, 'insufficient balance: no ledger row');
  perform tests.is(tests.seats_taken(v_ev3), v_seats3, 'insufficient balance: seats unchanged');
  perform tests.is(tests.allowance_used(v_u), 15, 'insufficient balance: allowance unchanged');
  perform tests.is((select count(*)::int from public.tickets where user_id = v_u and event_id = v_ev3), 0, 'insufficient balance: no ticket');

  -- Fund the wallet and confirm the fee.
  perform tests.fund_wallet(v_u, 1000);
  perform tests.as_user(v_u);
  v_res := public.register_for_free_event(v_ev3, '[]'::jsonb, 250, 'idem-key-0016');
  perform tests.is((v_res ->> 'fee_minor')::bigint, 250::bigint, 'paid-fee registration charged 250');
  perform tests.is((v_res ->> 'wallet_balance_minor')::bigint, 750::bigint, 'response reports the new wallet balance');
  perform tests.as_postgres();
  perform tests.is(tests.balance(v_u), 750::bigint, 'wallet debited by 250');
  perform tests.is(tests.ledger_sum(v_u), tests.balance(v_u), 'ledger and balance agree after the fee');
  perform tests.ok(exists (select 1 from public.wallet_ledger where user_id = v_u and entry_type = 'free_registration_fee'
                            and amount_minor = -250 and balance_after_minor = 750 and status = 'posted'
                            and reference_type = 'registration'),
                   'ledger row: free_registration_fee -250, balance_after 750');
  perform tests.ok(exists (select 1 from public.registrations where user_id = v_u and event_id = v_ev3
                            and not used_allowance and fee_minor = 250 and kind = 'free'),
                   'registration records fee and that the allowance was not used');
  perform tests.is(tests.allowance_used(v_u), 15, 'allowance counter does not exceed the limit');

  -- Fee changes between quote and confirm (operator raises it to 300).
  update public.platform_settings set value = 300 where key = 'extra_free_registration_fee_minor';
  perform tests.as_user(v_u);
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 250, 'idem-key-0017')$q$, v_ev4),
                       'fee_changed', 'fee raised to 300 after the quote: fee_changed');
  v_res := public.register_for_free_event(v_ev4, '[]'::jsonb, 300, 'idem-key-0017');
  perform tests.is((v_res ->> 'wallet_balance_minor')::bigint, 450::bigint, 'confirmed 300 fee leaves 450');
  perform tests.as_postgres();
  update public.platform_settings set value = 250 where key = 'extra_free_registration_fee_minor';
  perform tests.is(tests.ledger_sum(v_u), 450::bigint, 'ledger sum 450');

  -- A previous month's usage does not count against this month.
  delete from public.allowance_usage where user_id = v_u;
  insert into public.allowance_usage (user_id, month, used)
  values (v_u, (private.colombo_month() - interval '1 month')::date, 15);
  perform tests.as_user(v_u);
  perform tests.is((public.quote_free_registration((select id from t_ctx where key = 'ev5')) ->> 'fee_minor')::bigint, 0::bigint,
                   'allowance resets each Colombo calendar month');
  perform tests.as_postgres();
end
$$;

-- ---------------------------------------------------------------------------
-- 15 real registrations through the RPC, then the 16th needs the fee
-- ---------------------------------------------------------------------------
do $$
declare
  v_user uuid := tests.new_user('fifteen');
  v_res jsonb;
begin
  perform tests.fund_wallet(v_user, 300);
  perform tests.as_user(v_user);
  for i in 1 .. 15 loop
    v_res := public.register_for_free_event((select id from t_ctx where key = 'ev' || i), '[]', 0, 'loop-key-' || lpad(i::text, 4, '0'));
    if (v_res ->> 'fee_minor')::bigint <> 0 or (v_res ->> 'allowance_remaining')::int <> 15 - i then
      raise exception 'FAIL: registration % of the month was not free (%)', i, v_res;
    end if;
  end loop;
  perform tests.ok(true, '15 consecutive free registrations used the whole allowance at no cost');
  perform tests.is((public.wallet_summary() ->> 'allowance_remaining')::int, 0, 'wallet_summary: allowance exhausted');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'loop-key-0016')$q$, (select id from t_ctx where key = 'ev16')),
                       'fee_changed', '16th registration requires confirming the extra fee');
  v_res := public.register_for_free_event((select id from t_ctx where key = 'ev16'), '[]', 250, 'loop-key-0016');
  perform tests.is((v_res ->> 'wallet_balance_minor')::bigint, 50::bigint, '16th registration deducted 250 from the wallet');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 250, 'loop-key-0017')$q$, (select id from t_ctx where key = 'ev17')),
                       'insufficient_balance', '17th registration with 50 left is rejected');
  perform tests.as_postgres();
  perform tests.is(tests.allowance_used(v_user), 15, 'allowance counter stops at 15');
  perform tests.is(tests.ledger_sum(v_user), 50::bigint, 'ledger reflects exactly one fee');
  perform tests.is((select count(*)::int from public.tickets where user_id = v_user), 16, '16 tickets issued');
end
$$;

-- ---------------------------------------------------------------------------
-- Capacity, eligibility and errors
-- ---------------------------------------------------------------------------
do $$
declare
  v_tiny uuid := (select id from t_ctx where key = 'tiny');
  v_first uuid := tests.new_user('first');
  v_second uuid := tests.new_user('second');
  v_unverified uuid := tests.new_user('unverified', false);
begin
  perform tests.as_user(v_first);
  perform tests.lives(format($q$select public.register_for_free_event(%L, '[]', 0, 'cap-key-0001')$q$, v_tiny),
                      'last seat can be taken');
  perform tests.as_user(v_second);
  perform tests.is(public.quote_free_registration(v_tiny) ->> 'reason', 'sold_out', 'quote: sold_out');
  perform tests.is((public.quote_free_registration(v_tiny) ->> 'seats_remaining')::int, 0, 'quote: 0 seats remaining');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'cap-key-0002')$q$, v_tiny),
                       'sold_out', 'registration beyond capacity is rejected');
  perform tests.as_postgres();
  perform tests.is(tests.seats_taken(v_tiny), 1, 'capacity never exceeded');
  perform tests.throws_state(format('update public.events set seats_taken = 2 where id = %L', v_tiny), '23514',
                             'CHECK seats_taken <= capacity holds at the table level');

  perform tests.as_user(v_unverified);
  perform tests.is(public.quote_free_registration((select id from t_ctx where key = 'ev6')) ->> 'reason', 'identity_required',
                   'quote: identity_required for unverified users');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'idn-key-0001')$q$, (select id from t_ctx where key = 'ev6')),
                       'identity_required', 'unverified users cannot use the free allowance');

  perform tests.as_user(v_second);
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'err-key-0001')$q$, (select id from t_ctx where key = 'paid')),
                       'not_free_event', 'paid events are rejected');
  perform tests.is(public.quote_free_registration((select id from t_ctx where key = 'paid')) ->> 'reason', 'not_free_event',
                   'quote: not_free_event');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'err-key-0002')$q$, (select id from t_ctx where key = 'draft')),
                       'event_not_found', 'drafts are not found');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'err-key-0003')$q$, gen_random_uuid()),
                       'event_not_found', 'unknown events are not found');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'err-key-0004')$q$, (select id from t_ctx where key = 'closed')),
                       'registration_closed', 'closed registration window is rejected');
  perform tests.is(public.quote_free_registration((select id from t_ctx where key = 'closed')) ->> 'reason', 'registration_closed',
                   'quote: registration_closed');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'err-key-0006')$q$, (select id from t_ctx where key = 'started_single')),
                       'registration_closed', 'single-session events close at starts_at by default');
  perform tests.is(public.register_for_free_event((select id from t_ctx where key = 'started_multi'), '[]', 0, 'err-key-0007') ->> 'status',
                   'confirmed', 'multi-day events stay open until ends_at by default');
  perform tests.is((public.get_event_detail((select id from t_ctx where key = 'started_multi')) -> 'event' ->> 'registration_closes_at')::timestamptz,
                   (select ends_at from public.events where id = (select id from t_ctx where key = 'started_multi')),
                   'event detail reports the effective registration close time');
  perform tests.is((public.get_event_detail((select id from t_ctx where key = 'started_single')) -> 'event' ->> 'registration_open')::boolean,
                   false, 'event detail reports registration_open = false once a single session started');
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'short')$q$, (select id from t_ctx where key = 'ev7')),
                       'invalid_idempotency_key', 'too-short idempotency keys are rejected');

  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'err-key-0005')$q$, (select id from t_ctx where key = 'ev7')),
                       'not_authenticated', 'a request without a user is not_authenticated');
  perform tests.as_postgres();
end
$$;

-- ---------------------------------------------------------------------------
-- Registration answers
-- ---------------------------------------------------------------------------
do $$
declare
  v_quiz uuid := (select id from t_ctx where key = 'quiz');
  v_user uuid := tests.new_user('quizzer');
  v_choice uuid;
  v_yes uuid;
  v_multi uuid;
  v_text uuid;
  v_res jsonb;
begin
  v_choice := tests.new_question(v_quiz, 'single_choice', true, '["Software","Data"]');
  v_yes := tests.new_question(v_quiz, 'yes_no', true);
  v_multi := tests.new_question(v_quiz, 'multi_choice', false, '["A","B","C"]');
  v_text := tests.new_question(v_quiz, 'short_text', false);

  perform tests.as_user(v_user);
  perform tests.throws(format($q$select public.register_for_free_event(%L, '[]', 0, 'ans-key-0001')$q$, v_quiz),
                       'answers_invalid', 'missing required answers are rejected');
  perform tests.throws(format($q$select public.register_for_free_event(%L, %L, 0, 'ans-key-0002')$q$, v_quiz,
                              jsonb_build_array(jsonb_build_object('question_id', v_choice, 'value', 'Hardware'),
                                                jsonb_build_object('question_id', v_yes, 'value', true))),
                       'answers_invalid', 'a choice outside the options is rejected');
  perform tests.throws(format($q$select public.register_for_free_event(%L, %L, 0, 'ans-key-0003')$q$, v_quiz,
                              jsonb_build_array(jsonb_build_object('question_id', v_choice, 'value', 'Data'),
                                                jsonb_build_object('question_id', v_yes, 'value', 'yes'))),
                       'answers_invalid', 'yes_no requires a boolean');
  perform tests.throws(format($q$select public.register_for_free_event(%L, %L, 0, 'ans-key-0004')$q$, v_quiz,
                              jsonb_build_array(jsonb_build_object('question_id', v_choice, 'value', 'Data'),
                                                jsonb_build_object('question_id', v_yes, 'value', true),
                                                jsonb_build_object('question_id', gen_random_uuid(), 'value', 'x'))),
                       'answers_invalid', 'unknown question ids are rejected');
  perform tests.throws(format($q$select public.register_for_free_event(%L, %L, 0, 'ans-key-0005')$q$, v_quiz,
                              jsonb_build_array(jsonb_build_object('question_id', v_choice, 'value', 'Data'),
                                                jsonb_build_object('question_id', v_yes, 'value', true),
                                                jsonb_build_object('question_id', v_multi, 'value', '["A","Z"]'::jsonb))),
                       'answers_invalid', 'multi_choice values must be options');
  v_res := public.register_for_free_event(v_quiz,
             jsonb_build_array(jsonb_build_object('question_id', v_choice, 'value', '["Data"]'::jsonb),
                               jsonb_build_object('question_id', v_yes, 'value', false),
                               jsonb_build_object('question_id', v_multi, 'value', '["A","C"]'::jsonb),
                               jsonb_build_object('question_id', v_text, 'value', '  Team Rocket  ')),
             0, 'ans-key-0006');
  perform tests.is(v_res ->> 'status', 'confirmed', 'valid answers register successfully');
  perform tests.as_postgres();
  perform tests.is((select count(*)::int from public.registration_answers where registration_id = (v_res ->> 'registration_id')::uuid), 4,
                   'all answers stored');
  perform tests.is((select value from public.registration_answers where question_id = v_choice), '"Data"'::jsonb,
                   'single_choice ["Data"] normalised to "Data"');
  perform tests.is((select value from public.registration_answers where question_id = v_text), '"Team Rocket"'::jsonb,
                   'text answers are trimmed');
end
$$;

rollback;
