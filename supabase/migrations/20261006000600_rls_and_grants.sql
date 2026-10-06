-- =============================================================================
-- Zuno 0600: Row Level Security and table/column privileges (contract sect. 2)
--
-- Every public table has RLS enabled. Privileges are granted explicitly; the
-- defaults were revoked in 20261006000100. Server-owned columns are protected
-- with column-level INSERT/UPDATE grants, so a client can never write prices
-- after publication, balances, statuses, inventory counters, commission,
-- identity or verification status.
--
-- Tables with RLS enabled and NO client grant/policy (server/RPC only):
--   identity_digests, allowance_usage, rate_limits, audit_events,
--   event_settlements, registrations, registration_answers, tickets,
--   check_ins, payments
-- =============================================================================

-- ---------------------------------------------------------------------------
-- RLS helper predicates (security definer: they read rows the caller may not
-- see, avoiding recursive policy evaluation; they only return booleans).
-- ---------------------------------------------------------------------------
create or replace function private.is_organizer_owner(p_organizer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.organizer_profiles o
    where o.id = p_organizer_id and o.owner_id = auth.uid() and auth.uid() is not null
  );
$$;

create or replace function private.is_organizer_public(p_organizer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.organizer_profiles o
    where o.id = p_organizer_id and o.verification_status = 'verified'
  );
$$;

create or replace function private.is_event_owner(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.events e
    join public.organizer_profiles o on o.id = e.organizer_id
    where e.id = p_event_id and o.owner_id = auth.uid() and auth.uid() is not null
  );
$$;

create or replace function private.is_event_published(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.events e where e.id = p_event_id and e.status = 'published');
$$;

-- Owner AND the event is still a draft (organizer CRUD window).
create or replace function private.is_editable_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.events e
    join public.organizer_profiles o on o.id = e.organizer_id
    where e.id = p_event_id and e.status = 'draft' and o.owner_id = auth.uid() and auth.uid() is not null
  );
$$;

-- A venue referenced by any non-draft event is frozen (changes to a published
-- event's location must go through send_event_update('venue_change', ...)).
create or replace function private.is_venue_in_use(p_venue_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.events e where e.venue_id = p_venue_id and e.status <> 'draft');
$$;

create or replace function private.is_order_owner(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.orders o where o.id = p_order_id and o.user_id = auth.uid() and auth.uid() is not null
  );
$$;

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------------------
alter table public.platform_settings enable row level security;
alter table public.categories enable row level security;
alter table public.profiles enable row level security;
alter table public.user_identities enable row level security;
alter table public.identity_digests enable row level security;
alter table public.wallets enable row level security;
alter table public.wallet_ledger enable row level security;
alter table public.allowance_usage enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.push_devices enable row level security;
alter table public.rate_limits enable row level security;
alter table public.audit_events enable row level security;
alter table public.organizer_profiles enable row level security;
alter table public.venues enable row level security;
alter table public.events enable row level security;
alter table public.ticket_tiers enable row level security;
alter table public.registration_questions enable row level security;
alter table public.event_media enable row level security;
alter table public.ai_drafts enable row level security;
alter table public.event_updates enable row level security;
alter table public.event_settlements enable row level security;
alter table public.saved_events enable row level security;
alter table public.saved_organizers enable row level security;
alter table public.notifications enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.registrations enable row level security;
alter table public.registration_answers enable row level security;
alter table public.tickets enable row level security;
alter table public.check_ins enable row level security;
alter table public.payments enable row level security;

-- Start from zero for the API roles (belt and braces after 0100).
revoke all on all tables in schema public from anon, authenticated;

-- service_role (Edge Functions) keeps Supabase's table defaults EXCEPT for the
-- money/identity/audit tables, which are written only by definer functions.
revoke insert, update, delete, truncate on public.wallets, public.wallet_ledger, public.audit_events from service_role;
revoke all on public.identity_digests from service_role;

-- ---------------------------------------------------------------------------
-- Reference data (public read)
-- ---------------------------------------------------------------------------
create policy platform_settings_read on public.platform_settings
  for select to anon, authenticated using (true);
grant select on public.platform_settings to anon, authenticated;

create policy categories_read on public.categories
  for select to anon, authenticated using (true);
grant select on public.categories to anon, authenticated;

-- ---------------------------------------------------------------------------
-- profiles: own row; only editable columns are insertable/updatable
-- ---------------------------------------------------------------------------
create policy profiles_select_own on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy profiles_insert_own on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

grant select on public.profiles to authenticated;
grant insert (id, display_name, avatar_path, city, district, preferred_categories, language,
              accessibility_needs, phone, onboarding_completed_at)
  on public.profiles to authenticated;
grant update (display_name, avatar_path, city, district, preferred_categories, language,
              accessibility_needs, phone, onboarding_completed_at)
  on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Own-row read-only tables
-- ---------------------------------------------------------------------------
create policy user_identities_select_own on public.user_identities
  for select to authenticated using (user_id = (select auth.uid()));
grant select on public.user_identities to authenticated;

create policy wallets_select_own on public.wallets
  for select to authenticated using (user_id = (select auth.uid()));
grant select on public.wallets to authenticated;

create policy wallet_ledger_select_own on public.wallet_ledger
  for select to authenticated using (user_id = (select auth.uid()));
grant select on public.wallet_ledger to authenticated;

create policy notifications_select_own on public.notifications
  for select to authenticated using (user_id = (select auth.uid()));
grant select on public.notifications to authenticated;

create policy orders_select_own on public.orders
  for select to authenticated using (user_id = (select auth.uid()));
grant select on public.orders to authenticated;

create policy order_items_select_own on public.order_items
  for select to authenticated using (private.is_order_owner(order_id));
grant select on public.order_items to authenticated;

-- ---------------------------------------------------------------------------
-- notification_preferences: own row select/update (booleans only)
-- ---------------------------------------------------------------------------
create policy notification_preferences_select_own on public.notification_preferences
  for select to authenticated using (user_id = (select auth.uid()));
create policy notification_preferences_update_own on public.notification_preferences
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
grant select on public.notification_preferences to authenticated;
grant update (event_reminders, payment_updates, event_changes, waitlist_updates, organizer_news, push_enabled)
  on public.notification_preferences to authenticated;

-- ---------------------------------------------------------------------------
-- push_devices: own rows select/insert/delete
-- ---------------------------------------------------------------------------
create policy push_devices_select_own on public.push_devices
  for select to authenticated using (user_id = (select auth.uid()));
create policy push_devices_insert_own on public.push_devices
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy push_devices_delete_own on public.push_devices
  for delete to authenticated using (user_id = (select auth.uid()));
grant select, delete on public.push_devices to authenticated;
grant insert (id, user_id, apns_token, environment) on public.push_devices to authenticated;

-- ---------------------------------------------------------------------------
-- saved_events / saved_organizers: own rows select/insert/delete
-- ---------------------------------------------------------------------------
create policy saved_events_select_own on public.saved_events
  for select to authenticated using (user_id = (select auth.uid()));
create policy saved_events_insert_own on public.saved_events
  for insert to authenticated
  with check (user_id = (select auth.uid()) and private.is_event_published(event_id));
create policy saved_events_delete_own on public.saved_events
  for delete to authenticated using (user_id = (select auth.uid()));
grant select, delete on public.saved_events to authenticated;
grant insert (user_id, event_id) on public.saved_events to authenticated;

create policy saved_organizers_select_own on public.saved_organizers
  for select to authenticated using (user_id = (select auth.uid()));
create policy saved_organizers_insert_own on public.saved_organizers
  for insert to authenticated
  with check (user_id = (select auth.uid()) and private.is_organizer_public(organizer_id));
create policy saved_organizers_delete_own on public.saved_organizers
  for delete to authenticated using (user_id = (select auth.uid()));
grant select, delete on public.saved_organizers to authenticated;
grant insert (user_id, organizer_id) on public.saved_organizers to authenticated;

-- ---------------------------------------------------------------------------
-- organizer_profiles
--   anon: verified profiles, public columns only (id, name, slug, bio, logo_path)
--   authenticated: verified profiles + own profile (all columns: the owner
--   needs them and PostgREST `insert ... returning` requires SELECT on them)
-- ---------------------------------------------------------------------------
create policy organizer_profiles_read_anon on public.organizer_profiles
  for select to anon using (verification_status = 'verified');
create policy organizer_profiles_read_authenticated on public.organizer_profiles
  for select to authenticated
  using (verification_status = 'verified' or owner_id = (select auth.uid()));
create policy organizer_profiles_insert_own on public.organizer_profiles
  for insert to authenticated
  with check (owner_id = (select auth.uid()) and verification_status = 'pending');
create policy organizer_profiles_update_own on public.organizer_profiles
  for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

grant select (id, name, slug, bio, logo_path) on public.organizer_profiles to anon;
grant select on public.organizer_profiles to authenticated;
grant insert (id, owner_id, name, slug, bio, logo_path, contact_email) on public.organizer_profiles to authenticated;
grant update (name, slug, bio, logo_path, contact_email) on public.organizer_profiles to authenticated;

-- ---------------------------------------------------------------------------
-- venues
-- ---------------------------------------------------------------------------
create policy venues_read on public.venues
  for select to anon, authenticated
  using (private.is_organizer_public(organizer_id) or private.is_organizer_owner(organizer_id));
create policy venues_insert_own on public.venues
  for insert to authenticated with check (private.is_organizer_owner(organizer_id));
create policy venues_update_own on public.venues
  for update to authenticated
  using (private.is_organizer_owner(organizer_id) and not private.is_venue_in_use(id))
  with check (private.is_organizer_owner(organizer_id));
create policy venues_delete_own on public.venues
  for delete to authenticated
  using (private.is_organizer_owner(organizer_id) and not private.is_venue_in_use(id));

grant select on public.venues to anon, authenticated;
grant insert (id, organizer_id, name, address_line, city, district, latitude, longitude) on public.venues to authenticated;
grant update (name, address_line, city, district, latitude, longitude) on public.venues to authenticated;
grant delete on public.venues to authenticated;

-- ---------------------------------------------------------------------------
-- events: published for everyone, own events for the organizer;
-- organizers insert/update their own events only while status = 'draft'.
-- ---------------------------------------------------------------------------
create policy events_read on public.events
  for select to anon, authenticated
  using (status = 'published' or private.is_organizer_owner(organizer_id));
create policy events_insert_own_draft on public.events
  for insert to authenticated
  with check (status = 'draft' and private.is_organizer_owner(organizer_id));
create policy events_update_own_draft on public.events
  for update to authenticated
  using (status = 'draft' and private.is_organizer_owner(organizer_id))
  with check (status = 'draft' and private.is_organizer_owner(organizer_id));

-- anon: everything except the online joining link and internal search columns.
grant select (id, organizer_id, category_id, venue_id, title, summary, description, format, starts_at, ends_at,
              timezone, capacity, is_free, university, tags, cover_path, cover_alt, agenda, speakers,
              refund_policy, registration_opens_at, registration_closes_at, status, seats_taken,
              creation_fee_paid_at, published_at, cancelled_at, created_at, updated_at)
  on public.events to anon;
grant select on public.events to authenticated;
grant insert (id, organizer_id, category_id, venue_id, title, summary, description, format, starts_at, ends_at,
              timezone, capacity, is_free, university, tags, cover_path, cover_alt, agenda, speakers,
              refund_policy, registration_opens_at, registration_closes_at, online_url)
  on public.events to authenticated;
grant update (category_id, venue_id, title, summary, description, format, starts_at, ends_at,
              timezone, capacity, is_free, university, tags, cover_path, cover_alt, agenda, speakers,
              refund_policy, registration_opens_at, registration_closes_at, online_url)
  on public.events to authenticated;

-- ---------------------------------------------------------------------------
-- ticket_tiers / registration_questions / event_media: organizer CRUD while
-- the event is a draft; everyone reads those of published events.
-- ---------------------------------------------------------------------------
create policy ticket_tiers_read on public.ticket_tiers
  for select to anon, authenticated
  using (private.is_event_published(event_id) or private.is_event_owner(event_id));
create policy ticket_tiers_insert_draft on public.ticket_tiers
  for insert to authenticated with check (private.is_editable_event(event_id));
create policy ticket_tiers_update_draft on public.ticket_tiers
  for update to authenticated
  using (private.is_editable_event(event_id))
  with check (private.is_editable_event(event_id));
create policy ticket_tiers_delete_draft on public.ticket_tiers
  for delete to authenticated using (private.is_editable_event(event_id));

grant select on public.ticket_tiers to anon, authenticated;
grant insert (id, event_id, name, description, price_minor, currency, quantity, max_per_order,
              sales_start_at, sales_end_at, sort_order)
  on public.ticket_tiers to authenticated;
grant update (name, description, price_minor, quantity, max_per_order, sales_start_at, sales_end_at, sort_order)
  on public.ticket_tiers to authenticated;
grant delete on public.ticket_tiers to authenticated;

create policy registration_questions_read on public.registration_questions
  for select to anon, authenticated
  using (private.is_event_published(event_id) or private.is_event_owner(event_id));
create policy registration_questions_insert_draft on public.registration_questions
  for insert to authenticated with check (private.is_editable_event(event_id));
create policy registration_questions_update_draft on public.registration_questions
  for update to authenticated
  using (private.is_editable_event(event_id))
  with check (private.is_editable_event(event_id));
create policy registration_questions_delete_draft on public.registration_questions
  for delete to authenticated using (private.is_editable_event(event_id));

grant select on public.registration_questions to anon, authenticated;
grant insert (id, event_id, prompt, kind, options, required, sort_order) on public.registration_questions to authenticated;
grant update (prompt, kind, options, required, sort_order) on public.registration_questions to authenticated;
grant delete on public.registration_questions to authenticated;

create policy event_media_read on public.event_media
  for select to anon, authenticated
  using (private.is_event_published(event_id) or private.is_event_owner(event_id));
create policy event_media_insert_draft on public.event_media
  for insert to authenticated with check (private.is_editable_event(event_id));
create policy event_media_update_draft on public.event_media
  for update to authenticated
  using (private.is_editable_event(event_id))
  with check (private.is_editable_event(event_id));
create policy event_media_delete_draft on public.event_media
  for delete to authenticated using (private.is_editable_event(event_id));

grant select on public.event_media to anon, authenticated;
grant insert (id, event_id, storage_path, kind, alt_text, width, height, sort_order) on public.event_media to authenticated;
grant update (kind, alt_text, width, height, sort_order) on public.event_media to authenticated;
grant delete on public.event_media to authenticated;

-- ---------------------------------------------------------------------------
-- ai_drafts: organizer reads; may only move a draft to approved|discarded
-- ---------------------------------------------------------------------------
create policy ai_drafts_select_owner on public.ai_drafts
  for select to authenticated using (private.is_organizer_owner(organizer_id));
create policy ai_drafts_review_owner on public.ai_drafts
  for update to authenticated
  using (private.is_organizer_owner(organizer_id) and status in ('succeeded', 'approved', 'discarded'))
  with check (private.is_organizer_owner(organizer_id) and status in ('approved', 'discarded'));
grant select on public.ai_drafts to authenticated;
grant update (status) on public.ai_drafts to authenticated;

-- ---------------------------------------------------------------------------
-- event_updates: organizer reads (created through send_event_update)
-- ---------------------------------------------------------------------------
create policy event_updates_select_owner on public.event_updates
  for select to authenticated using (private.is_event_owner(event_id));
grant select on public.event_updates to authenticated;
