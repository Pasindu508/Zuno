-- 070: wallet / ledger integrity guards (enforced even for the table owner)
begin;

do $$
declare
  v_u uuid := tests.new_user('ledger');
  v_entry uuid;
  v_pending uuid;
  v_row public.wallet_ledger;
begin
  perform tests.fund_wallet(v_u, 1000);
  select id into v_entry from public.wallet_ledger where user_id = v_u;

  perform tests.throws(format('update public.wallet_ledger set amount_minor = 999999 where id = %L', v_entry),
                       'ledger_append_only', 'ledger amounts cannot be rewritten');
  perform tests.throws(format($q$update public.wallet_ledger set description = 'edited' where id = %L$q$, v_entry),
                       'ledger_append_only', 'ledger descriptions cannot be rewritten');
  perform tests.throws(format('delete from public.wallet_ledger where id = %L', v_entry),
                       'ledger_append_only', 'ledger rows cannot be deleted');
  perform tests.throws('truncate public.wallet_ledger', 'append_only_table', 'ledger cannot be truncated');
  perform tests.throws(format('update public.wallets set balance_minor = 5 where user_id = %L', v_u),
                       'wallet_balance_ledger_only', 'wallet balance cannot change outside ledger posting');
  perform tests.throws(format('delete from public.wallets where user_id = %L', v_u),
                       'wallet_delete_forbidden', 'wallets cannot be deleted outside account deletion');
  perform tests.throws(format($q$update public.wallets set currency = 'USD' where user_id = %L$q$, v_u),
                       'wallet_immutable', 'wallet currency cannot change');

  -- Overdraft is impossible.
  perform tests.throws(format($q$select private.ledger_post(%L, 'free_registration_fee', -1001, 'manual', null, 'x')$q$, v_u),
                       'insufficient_balance', 'a debit larger than the balance is rejected');
  perform tests.is(tests.balance(v_u), 1000::bigint, 'balance unchanged after rejected debit');
  perform set_config('zuno.wallet_from_ledger', 'on', true);
  perform tests.throws_state(format('update public.wallets set balance_minor = -1 where user_id = %L', v_u), '23514',
                             'CHECK balance_minor >= 0 is the final backstop');
  perform set_config('zuno.wallet_from_ledger', 'off', true);

  perform tests.throws_state(format($q$insert into public.wallet_ledger (user_id, entry_type, amount_minor, reference_type) values (%L, 'topup', -5, 'manual')$q$, v_u),
                             '23514', 'top-ups must be credits (sign constraint)');
  perform tests.throws_state(format($q$insert into public.wallet_ledger (user_id, entry_type, amount_minor, reference_type) values (%L, 'free_registration_fee', 5, 'manual')$q$, v_u),
                             '23514', 'fees must be debits (sign constraint)');
  perform tests.throws(format($q$insert into public.wallet_ledger (user_id, entry_type, amount_minor, status, reference_type) values (%L, 'topup', 5, 'failed', 'manual')$q$, v_u),
                       'ledger_invalid_status', 'entries cannot be created as failed');

  -- Pending -> posted only through the definer settle function.
  v_pending := private.ledger_add_pending(v_u, 'topup', 500, 'manual', null, 'pending test');
  perform tests.is(tests.balance(v_u), 1000::bigint, 'pending entry has no balance effect');
  perform tests.throws(format($q$update public.wallet_ledger set status = 'posted' where id = %L$q$, v_pending),
                       'ledger_append_only', 'direct pending -> posted without the writer flag is rejected');
  perform tests.ok(private.ledger_settle(v_pending, true), 'ledger_settle posts the pending entry');
  select * into v_row from public.wallet_ledger where id = v_pending;
  perform tests.is(v_row.status, 'posted', 'entry posted');
  perform tests.is(v_row.balance_after_minor, 1500::bigint, 'balance_after_minor recorded on posting');
  perform tests.is(tests.balance(v_u), 1500::bigint, 'balance applied on posting');
  perform tests.ok(not private.ledger_settle(v_pending, false), 'a posted entry cannot be settled again');
  perform set_config('zuno.ledger_writer', 'on', true);
  perform tests.throws(format($q$update public.wallet_ledger set status = 'failed' where id = %L$q$, v_pending),
                       'ledger_append_only', 'posted -> failed is rejected even with the writer flag');
  perform tests.throws(format($q$update public.wallet_ledger set status = 'posted', amount_minor = 9999 where id = %L$q$,
                              private.ledger_add_pending(v_u, 'topup', 700, 'manual', null, 'p2')),
                       'ledger_append_only', 'settlement cannot change the amount');
  perform set_config('zuno.ledger_writer', 'off', true);
  perform tests.is(tests.ledger_sum(v_u), tests.balance(v_u), 'ledger sum equals balance after all guard tests');

  -- audit_events is append-only too.
  perform private.audit('test_action', 'test', null, null, '{}'::jsonb, v_u);
  perform tests.throws($q$update public.audit_events set action = 'tampered' where action = 'test_action'$q$,
                       'audit_append_only', 'audit events cannot be modified');
  perform tests.throws($q$delete from public.audit_events where action = 'test_action'$q$,
                       'audit_append_only', 'audit events cannot be deleted');
end
$$;

rollback;
