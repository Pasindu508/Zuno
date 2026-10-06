-- 100: search_events filters, get_event_detail shape, attendee read RPCs (seed data)
begin;

do $$
declare
  v_dev constant uuid := 'b0000000-0000-4000-8000-0000000000aa';
  v_hack constant uuid := 'e1000000-0000-4000-8000-000000000001';
  v_swift constant uuid := 'e1000000-0000-4000-8000-000000000002';
  v_drums constant uuid := 'e1000000-0000-4000-8000-000000000003';
  v_galle constant uuid := 'e1000000-0000-4000-8000-000000000004';
  v_jazz constant uuid := 'e1000000-0000-4000-8000-000000000006';
  v_negombo constant uuid := 'e1000000-0000-4000-8000-000000000009';
  v_oss constant uuid := 'e1000000-0000-4000-8000-000000000012';
  v_design constant uuid := 'e1000000-0000-4000-8000-000000000013';
  v_lagoon constant uuid := 'e1000000-0000-4000-8000-000000000016';
  v_detail jsonb;
  v_ids uuid[];
  v_starts timestamptz[];
  v_wallet jsonb;
begin
  perform tests.as_anon();
  -- Defaults: published, not ended, ordered by starts_at.
  select array_agg(id), array_agg(starts_at) into v_ids, v_starts from public.search_events();
  perform tests.is(cardinality(v_ids), 15, 'search: 15 published events that have not ended');
  perform tests.ok(not (v_lagoon = any (v_ids)), 'search: ended events are excluded');
  perform tests.ok(v_starts = (select array_agg(s order by s) from unnest(v_starts) s), 'search: ordered by starts_at');
  perform tests.is((select count(*)::int from public.search_events(null, '{}', 5, 0)), 5, 'search: p_limit');
  perform tests.is((select id from public.search_events(null, '{}', 1, 1)), v_ids[2], 'search: p_offset');

  -- Text matching across fields.
  perform tests.is((select array_agg(id) from public.search_events('hackathon')), array[v_hack], 'text: title / category');
  perform tests.is((select array_agg(id) from public.search_events('Jaffna')), array['e1000000-0000-4000-8000-000000000005'::uuid],
                   'text: city and university');
  perform tests.is((select count(*)::int from public.search_events('island sound')), 2, 'text: organizer name');
  perform tests.is((select array_agg(id) from public.search_events('arduino')), array['e1000000-0000-4000-8000-000000000010'::uuid],
                   'text: tags');
  perform tests.is((select array_agg(id) from public.search_events('Lakeside Pavilion')), array[v_drums], 'text: venue name');
  perform tests.ok(v_swift = any (select id from public.search_events('Moratuwa')), 'text: university / city');
  perform tests.is((select array_agg(id) from public.search_events('prototypes')), array[v_hack], 'text: description');
  perform tests.ok((select count(*) from public.search_events('Careers')) >= 2, 'text: category name');
  perform tests.is((select count(*)::int from public.search_events('hack%')), 0, 'text: LIKE wildcards are escaped');
  perform tests.ok(v_hack = any (select id from public.search_events('hack')), 'text: substring matching');

  -- Filters.
  perform tests.ok(not exists (select 1 from public.search_events(null, '{"price":"free"}') where not is_free), 'filter: price free');
  perform tests.is((select count(*)::int from public.search_events(null, '{"price":"paid"}')), 6, 'filter: price paid');
  perform tests.is((select array_agg(id order by starts_at) from public.search_events(null, '{"format":"online"}')),
                   (select array_agg(id order by starts_at) from public.events where id in (v_oss, v_design)),
                   'filter: online also matches hybrid');
  perform tests.ok(not exists (select 1 from public.search_events(null, '{"format":"physical"}') where format <> 'physical'), 'filter: physical');
  perform tests.is((select count(*)::int from public.search_events(null, '{"cities":["kandy"]}')), 2, 'filter: cities (case-insensitive)');
  perform tests.is((select count(*)::int from public.search_events(null, '{"districts":["Galle"]}')), 1, 'filter: districts');
  perform tests.is((select array_agg(id) from public.search_events(null, '{"near_lat":6.0329,"near_lng":80.2168,"radius_km":5}')),
                   array[v_galle], 'filter: haversine radius');
  perform tests.ok((select count(*) from public.search_events(null, '{"near_lat":6.9271,"near_lng":79.8612,"radius_km":15}')) >= 6,
                   'filter: radius around Colombo');
  perform tests.ok(not (v_negombo = any (select id from public.search_events(null, '{"available_only":true}'))),
                   'filter: available_only excludes sold-out events');
  perform tests.ok(v_negombo = any (select id from public.search_events(null, '{}')), 'sold-out events still searchable by default');
  perform tests.is((select count(*)::int from public.search_events(null, '{"organizer_ids":["6f1d0a3e-1c2b-4d5e-8f90-0a1b2c3d4e04"]}')), 4,
                   'filter: organizer_ids');
  perform tests.is((select count(*)::int from public.search_events(null, '{"category_ids":["music","sports"]}')), 3, 'filter: category_ids');
  perform tests.is((select array_agg(id) from public.search_events(null, '{"university":"moratuwa"}')), array[v_swift], 'filter: university');
  perform tests.is((select count(*)::int from public.search_events(null,
                     jsonb_build_object('date_from', now() + interval '8 days', 'date_to', now() + interval '10 days'))),
                   (select count(*)::int from public.events where status = 'published'
                      and ends_at >= now() + interval '8 days' and starts_at <= now() + interval '10 days'),
                   'filter: date range (overlap)');
  perform tests.is((select count(*)::int from public.search_events('music', '{"price":"paid","cities":["Colombo"]}')), 1,
                   'filters combine with text');
  perform tests.throws($q$select * from public.search_events(null, '{"price":"cheap"}')$q$, 'invalid_filters', 'bad price filter');
  perform tests.throws($q$select * from public.search_events(null, '{"organizer_ids":["not-a-uuid"]}')$q$, 'invalid_filters', 'bad uuid filter');
  perform tests.throws($q$select * from public.search_events(null, '{"date_from":"yesterday-ish"}')$q$, 'invalid_filters', 'bad date filter');
  perform tests.throws($q$select * from public.search_events(null, '{"radius_km":10}')$q$, 'invalid_filters', 'radius without a centre');

  -- get_event_detail shape (anon).
  v_detail := public.get_event_detail(v_drums);
  perform tests.ok(v_detail ?& array['event', 'tiers', 'questions', 'media', 'viewer'], 'detail: top-level keys');
  perform tests.ok((v_detail -> 'event') ?& array['id', 'title', 'summary', 'category_id', 'category_name', 'organizer_id', 'organizer_name',
      'venue_name', 'city', 'district', 'latitude', 'longitude', 'university', 'format', 'starts_at', 'ends_at', 'is_free', 'min_price_minor',
      'currency', 'capacity', 'seats_taken', 'seats_remaining', 'cover_path', 'cover_alt', 'tags', 'status', 'published_at',
      'description', 'agenda', 'speakers', 'refund_policy', 'registration_opens_at', 'registration_closes_at', 'registration_open', 'online_url',
      'address_line', 'organizer_slug', 'organizer_verified'],
    'detail: event object has every contract key');
  perform tests.is((v_detail -> 'event' ->> 'min_price_minor')::bigint, 150000::bigint, 'detail: min_price_minor');
  perform tests.is(v_detail -> 'event' ->> 'organizer_slug', 'kandy-arts-guild', 'detail: organizer_slug');
  perform tests.is(jsonb_array_length(v_detail -> 'tiers'), 2, 'detail: tiers');
  perform tests.ok((v_detail -> 'tiers' -> 0) ?& array['id', 'name', 'description', 'price_minor', 'currency', 'quantity', 'remaining',
      'max_per_order', 'sales_start_at', 'sales_end_at', 'on_sale'], 'detail: tier keys');
  perform tests.is((v_detail -> 'tiers' -> 0 ->> 'remaining')::int, 150 - 62, 'detail: remaining = quantity - sold - reserved');
  perform tests.is((v_detail -> 'tiers' -> 0 ->> 'on_sale')::boolean, true, 'detail: tier on sale');
  perform tests.is((public.get_event_detail(v_negombo) -> 'tiers' -> 0 ->> 'on_sale')::boolean, false, 'detail: sold-out tier not on sale');
  perform tests.is((v_detail -> 'viewer' ->> 'is_saved')::boolean, false, 'detail: anon viewer has no saves');
  perform tests.is(jsonb_array_length(public.get_event_detail(v_hack) -> 'questions'), 3, 'detail: questions');
  perform tests.is(public.get_event_detail(v_hack) -> 'questions' -> 1 -> 'options', '["Software","Data","Design","Hardware","Domain expert"]'::jsonb,
                   'detail: question options');
  perform tests.is(public.get_event_detail(v_hack) -> 'media' -> 0 ->> 'storage_path', 'seed/climate-ai-hackathon.jpg', 'detail: media');
  perform tests.is(public.get_event_detail(v_hack) -> 'event' ->> 'min_price_minor', null::text, 'detail: free events have null min price');
  perform tests.throws(format('select public.get_event_detail(%L)', v_lagoon), 'event_not_found', 'completed events hidden from strangers');
  perform tests.throws($q$select public.get_event_detail(gen_random_uuid())$q$, 'event_not_found', 'unknown event');

  -- Development user view.
  perform tests.as_user(v_dev);
  v_detail := public.get_event_detail(v_swift);
  perform tests.is(v_detail -> 'viewer' ->> 'registration_status', 'confirmed', 'viewer: registration_status');
  perform tests.ok((v_detail -> 'viewer' ->> 'registration_id') is not null, 'viewer: registration_id');
  perform tests.is((public.get_event_detail(v_galle) -> 'viewer' ->> 'is_saved')::boolean, true, 'viewer: is_saved');
  perform tests.ok(public.get_event_detail(v_oss) -> 'event' ->> 'online_url' like 'https://%', 'online_url disclosed to confirmed attendees');
  perform tests.is(public.get_event_detail(v_design) -> 'event' ->> 'online_url', null::text, 'online_url hidden from non-attendees');
  perform tests.is(public.get_event_detail(v_lagoon) -> 'event' ->> 'status', 'completed', 'past attendees can still open completed events');

  perform tests.is(jsonb_array_length(public.my_tickets()), 4, 'my_tickets: 4 tickets');
  perform tests.ok((select bool_and(t ?& array['ticket_id', 'code', 'qr_payload', 'status', 'tier_name', 'attendee_name', 'issued_at',
                                               'checked_in_at', 'registration_reference', 'order_id', 'event']
                                    and (t ->> 'qr_payload') ~ '^zuno:t:[A-Za-z0-9_-]{43}$'
                                    and (t -> 'event') ?& array['id', 'title', 'starts_at', 'ends_at', 'venue_name', 'city', 'cover_path',
                                                                'cover_alt', 'status', 'category_id'])
                      from jsonb_array_elements(public.my_tickets()) t),
                   'my_tickets: contract keys and QR payload format');
  perform tests.is((select count(*)::int from jsonb_array_elements(public.my_tickets()) t where t ->> 'status' = 'checked_in'), 1,
                   'my_tickets: past ticket is checked_in');
  perform tests.is((select t ->> 'attendee_name' from jsonb_array_elements(public.my_tickets()) t limit 1), 'Nethmi Perera',
                   'my_tickets: attendee name');
  perform tests.is(jsonb_array_length(public.my_registrations()), 4, 'my_registrations: 4 registrations');
  perform tests.ok((select bool_and(r ?& array['registration_id', 'reference', 'status', 'kind', 'fee_minor', 'created_at', 'event'])
                      from jsonb_array_elements(public.my_registrations()) r), 'my_registrations: contract keys');

  v_wallet := public.wallet_summary();
  perform tests.is((v_wallet ->> 'balance_minor')::bigint, 14000::bigint, 'wallet_summary: balance');
  perform tests.is((v_wallet ->> 'allowance_used')::int, 13, 'wallet_summary: allowance_used');
  perform tests.is((v_wallet ->> 'allowance_remaining')::int, 2, 'wallet_summary: allowance_remaining');
  perform tests.is((v_wallet ->> 'extra_fee_minor')::bigint, 250::bigint, 'wallet_summary: extra fee');
  perform tests.ok(v_wallet ?& array['balance_minor', 'currency', 'allowance_limit', 'allowance_used', 'allowance_remaining',
                                     'extra_fee_minor', 'month', 'pending_topups_minor'], 'wallet_summary: contract keys');
  perform tests.is((public.quote_free_registration(v_hack) ->> 'fee_minor')::bigint, 0::bigint,
                   'quote for the seeded user: still inside the allowance');
  perform tests.is((public.quote_free_registration('e1000000-0000-4000-8000-000000000011') ->> 'can_register')::boolean, true,
                   'the running 33-day exhibition still accepts registrations');
  perform tests.is((public.get_event_detail('e1000000-0000-4000-8000-000000000011') -> 'event' ->> 'registration_open')::boolean, true,
                   'event detail: exhibition registration_open');

  perform tests.ok(public.mark_all_notifications_read() >= 1, 'mark_all_notifications_read marks unread notifications');
  perform tests.is(public.mark_all_notifications_read(), 0, 'nothing left to mark');
  perform tests.is((select count(*)::int from public.notifications where read_at is null), 0, 'all notifications read');
  perform tests.as_postgres();
end
$$;

rollback;
