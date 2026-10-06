-- =============================================================================
-- Zuno 0700: event_cards view and read-only RPCs
-- =============================================================================

-- ---------------------------------------------------------------------------
-- event_cards (contract section 2). security_invoker = true: the caller's RLS
-- applies, so non-owners only ever see published events of verified organizers.
-- seats_taken counts confirmed registrations plus active waitlist offers (free
-- events) or sold tickets (paid events); seats_remaining also subtracts pending
-- order reservations for paid events.
-- ---------------------------------------------------------------------------
create or replace view public.event_cards
with (security_invoker = true)
as
select
  e.id,
  e.title,
  e.summary,
  e.category_id,
  c.name as category_name,
  e.organizer_id,
  o.name as organizer_name,
  v.name as venue_name,
  v.city,
  v.district,
  v.latitude,
  v.longitude,
  e.university,
  e.format,
  e.starts_at,
  e.ends_at,
  e.is_free,
  case when e.is_free then null::bigint else t.min_price_minor end as min_price_minor,
  'LKR'::text as currency,
  e.capacity,
  e.seats_taken,
  greatest(
    0,
    case
      when e.is_free then e.capacity - e.seats_taken
      else least(e.capacity - e.seats_taken - coalesce(t.reserved, 0), coalesce(t.available, 0))
    end
  )::integer as seats_remaining,
  e.cover_path,
  e.cover_alt,
  e.tags,
  e.status,
  e.published_at
from public.events e
join public.categories c on c.id = e.category_id
join public.organizer_profiles o on o.id = e.organizer_id
left join public.venues v on v.id = e.venue_id
left join lateral (
  select
    min(tt.price_minor) as min_price_minor,
    sum(tt.reserved)::integer as reserved,
    sum(tt.quantity - tt.sold - tt.reserved)::integer as available
  from public.ticket_tiers tt
  where tt.event_id = e.id
) t on true;

comment on view public.event_cards is 'Contract section 2. security_invoker view; published events only for non-owners.';
grant select on public.event_cards to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------
create or replace function private.haversine_km(
  p_lat1 double precision, p_lng1 double precision,
  p_lat2 double precision, p_lng2 double precision
)
returns double precision
language sql
immutable
set search_path = ''
as $$
  select 2 * 6371.0088 * asin(least(1.0, sqrt(
      power(sin(radians(p_lat2 - p_lat1) / 2), 2)
    + cos(radians(p_lat1)) * cos(radians(p_lat2)) * power(sin(radians(p_lng2 - p_lng1) / 2), 2)
  )));
$$;

create or replace function private.like_escape(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(p_text, '\', '\\'), '%', '\%'), '_', '\_');
$$;

-- Compact event object embedded in my_tickets / my_registrations.
create or replace function private.event_summary_json(p_event_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', e.id,
    'title', e.title,
    'starts_at', e.starts_at,
    'ends_at', e.ends_at,
    'venue_name', v.name,
    'city', v.city,
    'cover_path', e.cover_path,
    'cover_alt', e.cover_alt,
    'status', e.status,
    'category_id', e.category_id
  )
  from public.events e
  left join public.venues v on v.id = e.venue_id
  where e.id = p_event_id;
$$;

-- Effective registration close time. When registration_closes_at is null:
--   * multi-day events (longer than 24 hours, e.g. a 33-day exhibition) stay
--     open until ends_at, so people can still register while it runs;
--   * single-session events close when they start (starts_at).
create or replace function private.registration_closes_at(p_event public.events)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select coalesce(
    p_event.registration_closes_at,
    case when p_event.ends_at - p_event.starts_at > interval '24 hours' then p_event.ends_at else p_event.starts_at end
  );
$$;

-- Is registration currently open for this event row?
create or replace function private.registration_open(p_event public.events)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_event.status = 'published'
     and now() < p_event.ends_at
     and (p_event.registration_opens_at is null or now() >= p_event.registration_opens_at)
     and now() < private.registration_closes_at(p_event);
$$;

create or replace function private.require_user()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    perform private.fail('not_authenticated');
  end if;
  return v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- search_events (contract section 3)
-- ---------------------------------------------------------------------------
create or replace function public.search_events(
  p_query text default null,
  p_filters jsonb default '{}'::jsonb,
  p_limit integer default 50,
  p_offset integer default 0
)
returns setof public.event_cards
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
  v_f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_tsq tsquery;
  v_like text;
  v_date_from timestamptz;
  v_date_to timestamptz;
  v_cities text[];
  v_districts text[];
  v_lat double precision;
  v_lng double precision;
  v_radius double precision;
  v_price text;
  v_format text;
  v_available boolean := false;
  v_org_ids uuid[];
  v_cat_ids text[];
  v_university text;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_valid boolean := true;
begin
  if jsonb_typeof(v_f) <> 'object' then
    perform private.fail('invalid_filters');
  end if;
  if v_q is not null and char_length(v_q) > 200 then
    perform private.fail('invalid_query');
  end if;

  -- Parse filters; any malformed value is reported as invalid_filters.
  begin
    v_date_from := nullif(v_f ->> 'date_from', '')::timestamptz;
    v_date_to := nullif(v_f ->> 'date_to', '')::timestamptz;
    v_lat := nullif(v_f ->> 'near_lat', '')::double precision;
    v_lng := nullif(v_f ->> 'near_lng', '')::double precision;
    v_radius := nullif(v_f ->> 'radius_km', '')::double precision;
    v_price := nullif(v_f ->> 'price', '');
    v_format := nullif(v_f ->> 'format', '');
    v_available := coalesce((v_f ->> 'available_only')::boolean, false);
    v_university := nullif(btrim(coalesce(v_f ->> 'university', '')), '');
    if jsonb_typeof(v_f -> 'cities') = 'array' then
      select array_agg(lower(btrim(x))) into v_cities from jsonb_array_elements_text(v_f -> 'cities') x;
    elsif v_f ? 'cities' and jsonb_typeof(v_f -> 'cities') <> 'null' then
      v_valid := false;
    end if;
    if jsonb_typeof(v_f -> 'districts') = 'array' then
      select array_agg(lower(btrim(x))) into v_districts from jsonb_array_elements_text(v_f -> 'districts') x;
    elsif v_f ? 'districts' and jsonb_typeof(v_f -> 'districts') <> 'null' then
      v_valid := false;
    end if;
    if jsonb_typeof(v_f -> 'organizer_ids') = 'array' then
      select array_agg(x::uuid) into v_org_ids from jsonb_array_elements_text(v_f -> 'organizer_ids') x;
    elsif v_f ? 'organizer_ids' and jsonb_typeof(v_f -> 'organizer_ids') <> 'null' then
      v_valid := false;
    end if;
    if jsonb_typeof(v_f -> 'category_ids') = 'array' then
      select array_agg(btrim(x)) into v_cat_ids from jsonb_array_elements_text(v_f -> 'category_ids') x;
    elsif v_f ? 'category_ids' and jsonb_typeof(v_f -> 'category_ids') <> 'null' then
      v_valid := false;
    end if;
  exception
    when invalid_text_representation or invalid_datetime_format or datetime_field_overflow
      or numeric_value_out_of_range or invalid_parameter_value or data_exception then
      v_valid := false;
  end;

  if not v_valid
     or (v_price is not null and v_price not in ('free', 'paid'))
     or (v_format is not null and v_format not in ('physical', 'online'))
     or ((v_lat is null) <> (v_lng is null))
     or (v_lat is not null and (v_lat not between -90 and 90 or v_lng not between -180 and 180))
     or (v_radius is not null and (v_radius <= 0 or v_radius > 1000 or v_lat is null))
     or (v_university is not null and char_length(v_university) > 120) then
    perform private.fail('invalid_filters');
  end if;

  -- near_lat/near_lng without radius_km: default to a 25 km radius.
  if v_lat is not null and v_radius is null then
    v_radius := 25;
  end if;

  if v_q is not null then
    v_tsq := websearch_to_tsquery('simple', v_q);
    v_like := '%' || private.like_escape(lower(v_q)) || '%';
  end if;

  return query
  select c.*
  from public.event_cards c
  join public.events e on e.id = c.id
  where e.status = 'published'
    and e.ends_at > now()
    and (v_q is null or e.search_vector @@ v_tsq or e.search_document like v_like)
    and (v_date_from is null or e.ends_at >= v_date_from)
    and (v_date_to is null or e.starts_at <= v_date_to)
    and (v_cities is null or lower(c.city) = any (v_cities))
    and (v_districts is null or lower(c.district) = any (v_districts))
    and (v_price is null or (v_price = 'free' and e.is_free) or (v_price = 'paid' and not e.is_free))
    and (v_format is null or e.format = v_format or (v_format = 'online' and e.format = 'hybrid'))
    and (not v_available or c.seats_remaining > 0)
    and (v_org_ids is null or e.organizer_id = any (v_org_ids))
    and (v_cat_ids is null or e.category_id = any (v_cat_ids))
    and (v_university is null or e.university ilike '%' || private.like_escape(v_university) || '%')
    and (v_radius is null or (
          c.latitude is not null
          and private.haversine_km(v_lat, v_lng, c.latitude, c.longitude) <= v_radius))
  order by e.starts_at, e.id
  limit v_limit
  offset v_offset;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_event_detail (contract section 3)
-- ---------------------------------------------------------------------------
create or replace function public.get_event_detail(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_org public.organizer_profiles;
  v_card jsonb;
  v_is_owner boolean;
  v_reg public.registrations;
  v_has_history boolean := false;
  v_address text;
  v_position integer;
begin
  select * into v_event from public.events where id = p_event_id;
  if not found then
    perform private.fail('event_not_found');
  end if;
  select * into v_org from public.organizer_profiles where id = v_event.organizer_id;
  v_is_owner := v_uid is not null and v_org.owner_id = v_uid;

  if v_uid is not null then
    select * into v_reg
      from public.registrations
     where event_id = p_event_id and user_id = v_uid and status in ('confirmed', 'waitlisted', 'offered')
     order by created_at desc
     limit 1;
    v_has_history := exists (select 1 from public.registrations where event_id = p_event_id and user_id = v_uid);
  end if;

  -- Non-owners see published events; attendees keep access to cancelled or
  -- completed events they registered for. Everything else is "not found".
  if v_event.status <> 'published'
     and not v_is_owner
     and not (v_event.status in ('cancelled', 'completed') and v_has_history) then
    perform private.fail('event_not_found');
  end if;

  select to_jsonb(c) into v_card from public.event_cards c where c.id = p_event_id;
  select address_line into v_address from public.venues where id = v_event.venue_id;

  if v_reg.status = 'waitlisted' then
    select count(*)::integer into v_position
      from public.registrations w
     where w.event_id = p_event_id and w.status = 'waitlisted'
       and (w.created_at, w.id) <= (v_reg.created_at, v_reg.id);
  end if;

  return jsonb_build_object(
    'event', v_card || jsonb_build_object(
      'description', v_event.description,
      'agenda', v_event.agenda,
      'speakers', v_event.speakers,
      'refund_policy', v_event.refund_policy,
      'registration_opens_at', v_event.registration_opens_at,
      -- effective close time (see private.registration_closes_at for the default)
      'registration_closes_at', private.registration_closes_at(v_event),
      'registration_open', private.registration_open(v_event),
      -- The joining link is only disclosed to confirmed attendees and the organizer.
      'online_url', case when v_is_owner or v_reg.status = 'confirmed' then v_event.online_url end,
      'address_line', v_address,
      'organizer_slug', v_org.slug,
      'organizer_verified', v_org.verification_status = 'verified'
    ),
    'tiers', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'name', t.name,
          'description', t.description,
          'price_minor', t.price_minor,
          'currency', t.currency,
          'quantity', t.quantity,
          'remaining', greatest(t.quantity - t.sold - t.reserved, 0),
          'max_per_order', t.max_per_order,
          'sales_start_at', t.sales_start_at,
          'sales_end_at', t.sales_end_at,
          'on_sale', private.registration_open(v_event)
                     and not v_event.is_free
                     and (t.sales_start_at is null or t.sales_start_at <= now())
                     and (t.sales_end_at is null or t.sales_end_at > now())
                     and t.quantity - t.sold - t.reserved > 0
        ) order by t.sort_order, t.price_minor, t.id)
      from public.ticket_tiers t
      where t.event_id = p_event_id
    ), '[]'::jsonb),
    'questions', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', q.id,
          'prompt', q.prompt,
          'kind', q.kind,
          'options', q.options,
          'required', q.required
        ) order by q.sort_order, q.id)
      from public.registration_questions q
      where q.event_id = p_event_id
    ), '[]'::jsonb),
    'media', coalesce((
      select jsonb_agg(jsonb_build_object(
          'storage_path', m.storage_path,
          'kind', m.kind,
          'alt_text', m.alt_text
        ) order by m.sort_order, m.id)
      from public.event_media m
      where m.event_id = p_event_id
    ), '[]'::jsonb),
    'viewer', jsonb_build_object(
      'is_saved', v_uid is not null and exists (
        select 1 from public.saved_events s where s.user_id = v_uid and s.event_id = p_event_id),
      'registration_status', v_reg.status,
      'registration_id', v_reg.id,
      'waitlisted', coalesce(v_reg.status = 'waitlisted', false),
      'waitlist_position', v_position,
      'offer_expires_at', v_reg.offer_expires_at,
      'is_organizer', coalesce(v_is_owner, false)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- my_tickets / my_registrations
-- ---------------------------------------------------------------------------
create or replace function public.my_tickets()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'ticket_id', t.id,
        'code', t.code,
        'qr_payload', 'zuno:t:' || t.qr_token,
        'status', t.status,
        'tier_name', coalesce(tt.name, 'General admission'),
        'attendee_name', t.attendee_name,
        'issued_at', t.issued_at,
        'checked_in_at', t.checked_in_at,
        'registration_reference', r.reference,
        'order_id', t.order_id,
        'event', private.event_summary_json(t.event_id)
      ) order by e.starts_at, t.issued_at, t.id)
    from public.tickets t
    join public.registrations r on r.id = t.registration_id
    join public.events e on e.id = t.event_id
    left join public.ticket_tiers tt on tt.id = t.tier_id
    where t.user_id = v_uid
  ), '[]'::jsonb);
end;
$$;

create or replace function public.my_registrations()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'registration_id', r.id,
        'reference', r.reference,
        'status', r.status,
        'kind', r.kind,
        'fee_minor', r.fee_minor,
        'order_id', r.order_id,
        'offer_expires_at', r.offer_expires_at,
        'created_at', r.created_at,
        'event', private.event_summary_json(r.event_id)
      ) order by r.created_at desc, r.id)
    from public.registrations r
    where r.user_id = v_uid
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- wallet_summary
-- ---------------------------------------------------------------------------
create or replace function public.wallet_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_month date := private.colombo_month();
  v_limit bigint := private.setting('free_allowance_per_month');
  v_used integer;
  v_balance bigint;
begin
  select coalesce((select used from public.allowance_usage where user_id = v_uid and month = v_month), 0) into v_used;
  select balance_minor into v_balance from public.wallets where user_id = v_uid;
  return jsonb_build_object(
    'balance_minor', coalesce(v_balance, 0),
    'currency', 'LKR',
    'allowance_limit', v_limit,
    'allowance_used', v_used,
    'allowance_remaining', greatest(v_limit - v_used, 0),
    'extra_fee_minor', private.setting('extra_free_registration_fee_minor'),
    'month', to_char(v_month, 'YYYY-MM'),
    'pending_topups_minor', coalesce((
      select sum(l.amount_minor)
      from public.wallet_ledger l
      where l.user_id = v_uid and l.entry_type = 'topup' and l.status = 'pending'
    ), 0)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Notification read state (only through these RPCs)
-- ---------------------------------------------------------------------------
create or replace function public.mark_notifications_read(p_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_count integer;
begin
  if p_ids is null or cardinality(p_ids) = 0 then
    return 0;
  end if;
  if cardinality(p_ids) > 500 then
    perform private.fail('too_many_ids');
  end if;
  update public.notifications
     set read_at = now()
   where user_id = v_uid and id = any (p_ids) and read_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.mark_all_notifications_read()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_user();
  v_count integer;
begin
  update public.notifications
     set read_at = now()
   where user_id = v_uid and read_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
