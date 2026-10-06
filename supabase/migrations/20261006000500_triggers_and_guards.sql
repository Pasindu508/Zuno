-- =============================================================================
-- Zuno 0500: auth hooks, wallet/ledger integrity, search maintenance and
-- validation triggers.
--
-- Wallet integrity model
-- ----------------------
-- * wallets.balance_minor can ONLY change inside private.wallet_ledger_apply,
--   i.e. as the side effect of inserting a `posted` ledger row or moving a
--   `pending` row to `posted`. The wallets guard rejects any other balance
--   change (the apply trigger raises a transaction-local flag while it writes).
-- * wallet_ledger is append-only: DELETE/TRUNCATE always fail; UPDATE is only
--   allowed for pending -> posted|failed transitions performed by definer
--   functions (flag `zuno.ledger_writer`) and for account-deletion
--   anonymisation (user_id -> NULL, flag `zuno.anonymise`).
-- * CHECK (balance_minor >= 0) is the final backstop against overdraft.
-- Clients and service_role have no INSERT/UPDATE/DELETE grants on either table.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- auth.users -> profile, wallet, notification preferences
-- ---------------------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  v_name := nullif(left(btrim(coalesce(
    new.raw_user_meta_data ->> 'display_name',
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name',
    ''
  )), 80), '');

  insert into public.profiles (id, display_name) values (new.id, v_name)
  on conflict (id) do nothing;
  insert into public.wallets (user_id) values (new.id)
  on conflict (user_id) do nothing;
  insert into public.notification_preferences (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists zuno_on_auth_user_created on auth.users;
create trigger zuno_on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- auth.identities -> public.user_identities mirror
-- ---------------------------------------------------------------------------
create or replace function private.handle_identity_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.user_identities (user_id, identity_id, provider, linked_at)
    values (new.user_id, new.id::text, new.provider, coalesce(new.created_at, now()))
    on conflict (identity_id) where unlinked_at is null do nothing;
    return new;
  end if;

  update public.user_identities
     set unlinked_at = now()
   where identity_id = old.id::text
     and unlinked_at is null;
  return old;
end;
$$;

drop trigger if exists zuno_on_auth_identity_inserted on auth.identities;
create trigger zuno_on_auth_identity_inserted
  after insert on auth.identities
  for each row execute function private.handle_identity_change();

drop trigger if exists zuno_on_auth_identity_deleted on auth.identities;
create trigger zuno_on_auth_identity_deleted
  after delete on auth.identities
  for each row execute function private.handle_identity_change();

-- ---------------------------------------------------------------------------
-- Wallet guard
-- ---------------------------------------------------------------------------
create or replace function private.wallets_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    -- Only the account-deletion path (auth.users cascade) may remove a wallet.
    if coalesce(current_setting('zuno.anonymise', true), '') <> 'on' then
      perform private.fail('wallet_delete_forbidden');
    end if;
    return old;
  end if;

  if new.user_id <> old.user_id or new.currency <> old.currency then
    perform private.fail('wallet_immutable');
  end if;
  if new.balance_minor <> old.balance_minor
     and coalesce(current_setting('zuno.wallet_from_ledger', true), '') <> 'on' then
    perform private.fail('wallet_balance_ledger_only');
  end if;
  return new;
end;
$$;

create trigger wallets_a_guard
  before update or delete on public.wallets
  for each row execute function private.wallets_guard();

create trigger wallets_b_set_updated_at
  before update on public.wallets
  for each row execute function private.set_updated_at();

create trigger wallets_no_truncate
  before truncate on public.wallets
  for each statement execute function private.forbid_truncate();

-- ---------------------------------------------------------------------------
-- Ledger guard (append-only) and posting
-- Trigger names are ordered: a_guard runs before b_apply.
-- ---------------------------------------------------------------------------
create or replace function private.wallet_ledger_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform private.fail('ledger_append_only');
  end if;

  -- (1) Account deletion: user_id may be cleared, nothing else may change.
  if coalesce(current_setting('zuno.anonymise', true), '') = 'on'
     and old.user_id is not null and new.user_id is null
     and new.id = old.id
     and new.entry_type = old.entry_type
     and new.amount_minor = old.amount_minor
     and new.balance_after_minor is not distinct from old.balance_after_minor
     and new.status = old.status
     and new.reference_type = old.reference_type
     and new.reference_id is not distinct from old.reference_id
     and new.description = old.description
     and new.created_at = old.created_at
     and new.posted_at is not distinct from old.posted_at then
    return new;
  end if;

  -- (2) Settlement of a pending entry by a definer function. Only status may
  --     change here; balance_after_minor/posted_at are set by the apply trigger.
  if coalesce(current_setting('zuno.ledger_writer', true), '') = 'on'
     and old.status = 'pending'
     and new.status in ('posted', 'failed')
     and new.id = old.id
     and new.user_id is not distinct from old.user_id
     and new.entry_type = old.entry_type
     and new.amount_minor = old.amount_minor
     and new.reference_type = old.reference_type
     and new.reference_id is not distinct from old.reference_id
     and new.description = old.description
     and new.created_at = old.created_at then
    return new;
  end if;

  perform private.fail('ledger_append_only');
  return null;
end;
$$;

create or replace function private.wallet_ledger_apply()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_balance bigint;
begin
  if tg_op = 'INSERT' then
    if new.status = 'pending' then
      new.balance_after_minor := null;
      new.posted_at := null;
      return new;
    elsif new.status <> 'posted' then
      perform private.fail('ledger_invalid_status');
    end if;
  elsif not (old.status = 'pending' and new.status = 'posted') then
    -- pending -> failed or anonymisation: no balance effect.
    return new;
  end if;

  if new.user_id is null then
    perform private.fail('ledger_user_required');
  end if;

  -- Row lock on the wallet serialises every balance change for this user.
  select balance_minor into v_balance
    from public.wallets
   where user_id = new.user_id
   for update;
  if not found then
    perform private.fail('wallet_not_found');
  end if;
  if v_balance + new.amount_minor < 0 then
    perform private.fail('insufficient_balance');
  end if;

  perform set_config('zuno.wallet_from_ledger', 'on', true);
  update public.wallets
     set balance_minor = v_balance + new.amount_minor
   where user_id = new.user_id;
  perform set_config('zuno.wallet_from_ledger', 'off', true);

  new.balance_after_minor := v_balance + new.amount_minor;
  new.posted_at := now();
  return new;
end;
$$;

create trigger wallet_ledger_a_guard
  before update or delete on public.wallet_ledger
  for each row execute function private.wallet_ledger_guard();

create trigger wallet_ledger_b_apply
  before insert or update on public.wallet_ledger
  for each row execute function private.wallet_ledger_apply();

create trigger wallet_ledger_no_truncate
  before truncate on public.wallet_ledger
  for each statement execute function private.forbid_truncate();

-- Post a ledger entry immediately (credits and debits). Returns the row.
create or replace function private.ledger_post(
  p_user_id uuid,
  p_entry_type text,
  p_amount_minor bigint,
  p_reference_type text,
  p_reference_id uuid,
  p_description text
)
returns public.wallet_ledger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.wallet_ledger;
begin
  insert into public.wallet_ledger (user_id, entry_type, amount_minor, status, reference_type, reference_id, description)
  values (p_user_id, p_entry_type, p_amount_minor, 'posted', p_reference_type, p_reference_id, left(coalesce(p_description, ''), 300))
  returning * into v_row;
  return v_row;
end;
$$;

-- Record a pending credit (e.g. a top-up awaiting payment). No balance effect.
create or replace function private.ledger_add_pending(
  p_user_id uuid,
  p_entry_type text,
  p_amount_minor bigint,
  p_reference_type text,
  p_reference_id uuid,
  p_description text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.wallet_ledger (user_id, entry_type, amount_minor, status, reference_type, reference_id, description)
  values (p_user_id, p_entry_type, p_amount_minor, 'pending', p_reference_type, p_reference_id, left(coalesce(p_description, ''), 300))
  returning id into v_id;
  return v_id;
end;
$$;

-- Settle a pending entry: posted (applies the balance) or failed.
create or replace function private.ledger_settle(p_ledger_id uuid, p_posted boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  perform set_config('zuno.ledger_writer', 'on', true);
  update public.wallet_ledger
     set status = case when p_posted then 'posted' else 'failed' end
   where id = p_ledger_id
     and status = 'pending';
  get diagnostics v_count = row_count;
  perform set_config('zuno.ledger_writer', 'off', true);
  return v_count > 0;
end;
$$;

-- ---------------------------------------------------------------------------
-- audit_events: append-only (actor may only be cleared by account deletion)
-- ---------------------------------------------------------------------------
create or replace function private.audit_events_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and coalesce(current_setting('zuno.anonymise', true), '') = 'on'
     and old.actor_id is not null and new.actor_id is null
     and (new.id, new.action, new.entity_type, new.created_at) = (old.id, old.action, old.entity_type, old.created_at)
     and new.entity_id is not distinct from old.entity_id
     and new.event_id is not distinct from old.event_id
     and new.data = old.data then
    return new;
  end if;
  perform private.fail('audit_append_only');
  return null;
end;
$$;

create trigger audit_events_guard
  before update or delete on public.audit_events
  for each row execute function private.audit_events_guard();

create trigger audit_events_no_truncate
  before truncate on public.audit_events
  for each statement execute function private.forbid_truncate();

-- ---------------------------------------------------------------------------
-- Storage path ownership helpers (used by triggers and storage policies)
-- Seed images under `seed/` may only be referenced by server-side writers
-- (no end-user JWT, e.g. seed.sql or service-role Edge Functions).
-- ---------------------------------------------------------------------------
create or replace function private.is_valid_org_media_path(p_organizer_id uuid, p_path text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_path is null
      or p_path like p_organizer_id::text || '/_%'
      or (p_path like 'seed/_%' and auth.uid() is null);
$$;

-- ---------------------------------------------------------------------------
-- organizer_profiles validation + search refresh on rename
-- ---------------------------------------------------------------------------
create or replace function private.organizer_profiles_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT' or new.logo_path is distinct from old.logo_path)
     and not private.is_valid_org_media_path(new.id, new.logo_path) then
    perform private.fail('invalid_media_path');
  end if;
  return new;
end;
$$;

create trigger organizer_profiles_validate
  before insert or update on public.organizer_profiles
  for each row execute function private.organizer_profiles_validate();

-- ---------------------------------------------------------------------------
-- events: validation (venue ownership, media path) and denormalised search
-- ---------------------------------------------------------------------------
create or replace function private.events_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.venue_id is not null
     and (tg_op = 'INSERT' or new.venue_id is distinct from old.venue_id or new.organizer_id <> old.organizer_id)
     and not exists (
       select 1 from public.venues v where v.id = new.venue_id and v.organizer_id = new.organizer_id
     ) then
    perform private.fail('venue_not_owned');
  end if;
  if (tg_op = 'INSERT' or new.cover_path is distinct from old.cover_path)
     and not private.is_valid_org_media_path(new.organizer_id, new.cover_path) then
    perform private.fail('invalid_media_path');
  end if;
  return new;
end;
$$;

create trigger events_a_validate
  before insert or update on public.events
  for each row execute function private.events_validate();

create or replace function private.events_refresh_search()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org text;
  v_cat text;
  v_venue text;
  v_tags text := array_to_string(new.tags, ' ');
begin
  select o.name into v_org from public.organizer_profiles o where o.id = new.organizer_id;
  select c.name into v_cat from public.categories c where c.id = new.category_id;
  select concat_ws(' ', v.name, v.city, v.district, v.address_line) into v_venue
    from public.venues v where v.id = new.venue_id;

  new.search_document := lower(concat_ws(' ',
    new.title, new.summary, new.description, v_org, v_cat, v_venue, new.university, v_tags));
  new.search_vector :=
       setweight(to_tsvector('simple', coalesce(new.title, '')), 'A')
    || setweight(to_tsvector('simple', concat_ws(' ', new.summary, v_tags, v_org, v_cat)), 'B')
    || setweight(to_tsvector('simple', concat_ws(' ', v_venue, new.university)), 'C')
    || setweight(to_tsvector('simple', coalesce(new.description, '')), 'D');
  return new;
end;
$$;

create trigger events_b_refresh_search
  before insert or update of title, summary, description, organizer_id, category_id, venue_id, university, tags, search_document
  on public.events
  for each row execute function private.events_refresh_search();

-- Renaming an organizer / venue / category re-derives the search document of
-- its events (touching search_document re-runs events_b_refresh_search).
create or replace function private.refresh_related_event_search()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Nested IFs: PL/pgSQL resolves record fields per expression, and the
  -- venue columns do not exist on the other two tables.
  if tg_table_name = 'organizer_profiles' then
    if new.name is distinct from old.name then
      update public.events set search_document = '' where organizer_id = new.id;
    end if;
  elsif tg_table_name = 'venues' then
    if (new.name, new.city, new.district, new.address_line)
       is distinct from (old.name, old.city, old.district, old.address_line) then
      update public.events set search_document = '' where venue_id = new.id;
    end if;
  elsif tg_table_name = 'categories' then
    if new.name is distinct from old.name then
      update public.events set search_document = '' where category_id = new.id;
    end if;
  end if;
  return null;
end;
$$;

create trigger organizer_profiles_refresh_event_search
  after update of name on public.organizer_profiles
  for each row execute function private.refresh_related_event_search();

create trigger venues_refresh_event_search
  after update of name, city, district, address_line on public.venues
  for each row execute function private.refresh_related_event_search();

create trigger categories_refresh_event_search
  after update of name on public.categories
  for each row execute function private.refresh_related_event_search();

-- ---------------------------------------------------------------------------
-- registration_questions: option list shape
-- ---------------------------------------------------------------------------
create or replace function private.registration_questions_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.kind in ('single_choice', 'multi_choice') then
    if jsonb_array_length(new.options) < 2
       or exists (
         select 1 from jsonb_array_elements(new.options) e
         where jsonb_typeof(e) <> 'string' or char_length(btrim(e #>> '{}')) not between 1 and 100
       )
       or (select count(distinct e #>> '{}') from jsonb_array_elements(new.options) e) <> jsonb_array_length(new.options) then
      perform private.fail('invalid_options');
    end if;
  else
    -- Text and yes/no questions carry no options.
    new.options := '[]'::jsonb;
  end if;
  return new;
end;
$$;

create trigger registration_questions_validate
  before insert or update on public.registration_questions
  for each row execute function private.registration_questions_validate();

-- ---------------------------------------------------------------------------
-- event_media: storage path must be inside the organizer's folder
-- ---------------------------------------------------------------------------
create or replace function private.event_media_validate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  select organizer_id into v_org from public.events where id = new.event_id;
  if (tg_op = 'INSERT' or new.storage_path is distinct from old.storage_path)
     and not private.is_valid_org_media_path(v_org, new.storage_path) then
    perform private.fail('invalid_media_path');
  end if;
  return new;
end;
$$;

create trigger event_media_validate
  before insert or update on public.event_media
  for each row execute function private.event_media_validate();
