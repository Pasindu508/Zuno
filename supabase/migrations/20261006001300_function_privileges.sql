-- =============================================================================
-- Zuno 1300: function privileges and self-checks
--
-- Every function starts closed (EXECUTE revoked from PUBLIC, anon,
-- authenticated and service_role) and is opened explicitly:
--   anon + authenticated : search_events, get_event_detail
--   authenticated        : attendee and organizer RPCs (contract section 3)
--   service_role only    : create_payment_order, apply_payhere_notification,
--                          expire_stale_orders, rate_limit_hit,
--                          record_identity_digest, prepare_account_deletion,
--                          organizer_export_data
--   private.* helpers    : only the side-effect-free predicates used inside RLS
--                          policies / storage policies are executable by the
--                          API roles (the private schema is not exposed by
--                          PostgREST, so they are not callable over HTTP).
-- =============================================================================

revoke all on all functions in schema public from public, anon, authenticated, service_role;
revoke all on all functions in schema private from public, anon, authenticated, service_role;

-- Public read RPCs
grant execute on function public.search_events(text, jsonb, integer, integer) to anon, authenticated;
grant execute on function public.get_event_detail(uuid) to anon, authenticated;

-- Attendee RPCs
grant execute on function public.quote_free_registration(uuid) to authenticated;
grant execute on function public.register_for_free_event(uuid, jsonb, bigint, text) to authenticated;
grant execute on function public.join_waitlist(uuid) to authenticated;
grant execute on function public.cancel_registration(uuid) to authenticated;
grant execute on function public.my_tickets() to authenticated;
grant execute on function public.my_registrations() to authenticated;
grant execute on function public.wallet_summary() to authenticated;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;

-- Organizer RPCs
grant execute on function public.organizer_dashboard() to authenticated;
grant execute on function public.organizer_event_stats(uuid) to authenticated;
grant execute on function public.organizer_attendees(uuid) to authenticated;
grant execute on function public.organizer_settlements() to authenticated;
grant execute on function public.submit_event_for_publish(uuid) to authenticated;
grant execute on function public.send_event_update(uuid, text, text) to authenticated;
grant execute on function public.cancel_event(uuid, text) to authenticated;
grant execute on function public.check_in_ticket(uuid, text) to authenticated;

-- Service-role-only RPCs (Edge Functions / pg_cron)
grant execute on function public.create_payment_order(uuid, text, uuid, jsonb, bigint, text, jsonb) to service_role;
grant execute on function public.apply_payhere_notification(uuid, text, integer, bigint, text, text, jsonb) to service_role;
grant execute on function public.expire_stale_orders() to service_role;
grant execute on function public.rate_limit_hit(text, integer, integer) to service_role;
grant execute on function public.record_identity_digest(uuid, text, integer) to service_role;
grant execute on function public.prepare_account_deletion(uuid) to service_role;
grant execute on function public.organizer_export_data(uuid, uuid) to service_role;

-- Predicates evaluated as the client role inside RLS / storage policies.
grant execute on function
  private.is_organizer_owner(uuid),
  private.is_organizer_public(uuid),
  private.is_event_owner(uuid),
  private.is_event_published(uuid),
  private.is_editable_event(uuid),
  private.is_venue_in_use(uuid),
  private.is_order_owner(uuid),
  private.owns_organizer_folder(text),
  private.is_valid_org_media_path(uuid, text),
  private.fail(text, text)
to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Self-checks: fail the migration if a hardening rule is violated.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad text;
begin
  -- 1. RLS enabled on every table in public.
  select string_agg(c.relname, ', ') into v_bad
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  if v_bad is not null then
    raise exception 'RLS disabled on: %', v_bad;
  end if;

  -- 2. Every SECURITY DEFINER function pins search_path = ''.
  select string_agg(n.nspname || '.' || p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef
     and not coalesce(p.proconfig @> array['search_path=""'], false);
  if v_bad is not null then
    raise exception 'SECURITY DEFINER without search_path='''': %', v_bad;
  end if;

  -- 3. No public function is executable by PUBLIC.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private')
     and has_function_privilege('public', p.oid, 'execute');
  if v_bad is not null then
    raise exception 'functions executable by PUBLIC: %', v_bad;
  end if;

  -- 4. event_cards is a security_invoker view.
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'event_cards'
       and c.reloptions @> array['security_invoker=true']
  ) then
    raise exception 'event_cards must be security_invoker';
  end if;
end
$$;
