-- =============================================================================
-- Zuno 1100: identity digests and account deletion
-- =============================================================================

-- ---------------------------------------------------------------------------
-- record_identity_digest (SERVICE ROLE ONLY; called by nic-digest).
-- The Edge Function canonicalises the NIC and computes
-- HMAC-SHA-256(NIC_HMAC_KEY, canonical NIC); the raw NIC never reaches the DB.
-- Returns {"status": "verified_unique" | "duplicate"}.
-- ---------------------------------------------------------------------------
create or replace function public.record_identity_digest(p_user_id uuid, p_digest text, p_key_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.identity_digests;
  v_inserted uuid;
begin
  if p_user_id is null or not exists (select 1 from auth.users where id = p_user_id) then
    perform private.fail('user_not_found');
  end if;
  if p_digest is null or p_digest !~ '^[0-9a-f]{64}$' then
    perform private.fail('invalid_digest');
  end if;
  if p_key_version is null or p_key_version < 1 then
    perform private.fail('invalid_key_version');
  end if;

  -- Serialise per user on the profile row.
  perform 1 from public.profiles where id = p_user_id for update;

  select * into v_existing from public.identity_digests where user_id = p_user_id;
  if found then
    if v_existing.digest = p_digest then
      update public.profiles set identity_status = 'verified_unique'
       where id = p_user_id and identity_status <> 'verified_unique';
      return jsonb_build_object('status', 'verified_unique');
    end if;
    -- One identity per account; changing it requires support.
    perform private.fail('already_verified');
  end if;

  insert into public.identity_digests (user_id, digest, key_version)
  values (p_user_id, p_digest, p_key_version)
  on conflict (digest) do nothing
  returning user_id into v_inserted;

  if v_inserted is null then
    -- The same NIC is already bound to another account.
    update public.profiles set identity_status = 'duplicate' where id = p_user_id;
    perform private.audit('identity_duplicate', 'user', p_user_id, null, jsonb_build_object('key_version', p_key_version), p_user_id);
    return jsonb_build_object('status', 'duplicate');
  end if;

  update public.profiles set identity_status = 'verified_unique' where id = p_user_id;
  perform private.audit('identity_verified', 'user', p_user_id, null, jsonb_build_object('key_version', p_key_version), p_user_id);
  return jsonb_build_object('status', 'verified_unique');
end;
$$;

-- ---------------------------------------------------------------------------
-- Account anonymisation. Retained financial / operational rows (ledger,
-- orders, payments, tickets, registrations, check-ins, audit) are kept for
-- accounting but detached from the person; personal answers are deleted.
-- Sets the transaction-local flag `zuno.anonymise` that the append-only
-- guards accept for user_id -> NULL and that allows the wallet row to be
-- removed by the auth.users cascade.
-- ---------------------------------------------------------------------------
create or replace function private.anonymise_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rec record;
begin
  perform set_config('zuno.anonymise', 'on', true);

  -- Pending checkouts: release holds (lock order: event, then order).
  for v_rec in
    select id, event_id from public.orders where user_id = p_user_id and status = 'pending' order by event_id nulls first, id
  loop
    if v_rec.event_id is not null then
      perform 1 from public.events where id = v_rec.event_id for update;
    end if;
    perform private.close_order(v_rec.id, 'cancelled', 'account_deleted');
  end loop;

  -- Active registrations for events that have not ended free their seats
  -- (waitlist offers are passed on). Paid tickets are forfeited, not refunded.
  for v_rec in
    select r.id, r.event_id
      from public.registrations r
      join public.events e on e.id = r.event_id
     where r.user_id = p_user_id and r.status in ('confirmed', 'waitlisted', 'offered') and e.ends_at > now()
     order by r.event_id, r.id
  loop
    perform 1 from public.events where id = v_rec.event_id for update;
    perform private.cancel_registration_internal(v_rec.id, 'account_deleted');
  end loop;

  delete from public.registration_answers
   where registration_id in (select id from public.registrations where user_id = p_user_id);
  update public.tickets set user_id = null, attendee_name = null where user_id = p_user_id;
  update public.registrations set user_id = null, result = null, idempotency_key = null where user_id = p_user_id;
  update public.orders set user_id = null, answers = null where user_id = p_user_id;
  update public.wallet_ledger set user_id = null where user_id = p_user_id;
  update public.audit_events set actor_id = null where actor_id = p_user_id;
  update public.ai_drafts set created_by = null where created_by = p_user_id;
  update public.event_updates set sent_by = null where sent_by = p_user_id;
  update public.check_ins set checked_in_by = null where checked_in_by = p_user_id;
  update public.organizer_profiles
     set owner_id = null, contact_email = null, verification_status = 'suspended'
   where owner_id = p_user_id;
  delete from public.rate_limits where key like '%' || p_user_id::text || '%';

  insert into public.audit_events (actor_id, action, entity_type, entity_id, data)
  values (null, 'account_anonymised', 'user', p_user_id, '{}'::jsonb);
end;
$$;

-- Any deletion of an auth user (Admin API, dashboard, SQL) anonymises first.
create or replace function private.handle_user_deleting()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.anonymise_user(old.id);
  return old;
end;
$$;

drop trigger if exists zuno_on_auth_user_deleting on auth.users;
create trigger zuno_on_auth_user_deleting
  before delete on auth.users
  for each row execute function private.handle_user_deleting();

-- ---------------------------------------------------------------------------
-- prepare_account_deletion (SERVICE ROLE ONLY; called by delete-account
-- before storage cleanup and auth.admin.deleteUser). It only validates and
-- reports the storage prefixes to remove; the anonymisation itself runs in the
-- BEFORE DELETE trigger above, atomically with the auth user deletion.
-- ---------------------------------------------------------------------------
create or replace function public.prepare_account_deletion(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_ids uuid[];
begin
  if p_user_id is null or not exists (select 1 from auth.users where id = p_user_id) then
    perform private.fail('user_not_found');
  end if;
  if exists (
    select 1
      from public.events e
      join public.organizer_profiles o on o.id = e.organizer_id
     where o.owner_id = p_user_id and e.status in ('published', 'pending_review') and e.ends_at > now()
  ) then
    perform private.fail('organizer_has_active_events');
  end if;

  select coalesce(array_agg(id), '{}') into v_org_ids from public.organizer_profiles where owner_id = p_user_id;

  return jsonb_build_object(
    'user_id', p_user_id,
    'avatar_prefix', p_user_id::text,
    'organizer_ids', to_jsonb(v_org_ids)
  );
end;
$$;
