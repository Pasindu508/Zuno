-- =============================================================================
-- Zuno 1200: storage buckets + policies, Realtime publication, pg_cron job
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Storage buckets (contract section 5)
--   event-media: public read, 8 MB, images only
--   avatars:     authenticated read, 3 MB, images only
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('event-media', 'event-media', true, 8388608, array['image/jpeg', 'image/png', 'image/heic', 'image/webp']),
  ('avatars', 'avatars', false, 3145728, array['image/jpeg', 'image/png', 'image/heic', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Does the current user own the organizer whose id is this folder name?
create or replace function private.owns_organizer_folder(p_folder text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.organizer_profiles o
    where o.id::text = p_folder and o.owner_id = auth.uid()
  );
$$;

-- event-media: anyone may read; writes only under "<organizer_id>/..." by that
-- organizer's owner. (Seed images under "seed/" are uploaded with the service
-- role, which bypasses RLS.)
drop policy if exists zuno_event_media_read on storage.objects;
create policy zuno_event_media_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'event-media');

drop policy if exists zuno_event_media_insert on storage.objects;
create policy zuno_event_media_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'event-media' and private.owns_organizer_folder((storage.foldername(name))[1]));

drop policy if exists zuno_event_media_update on storage.objects;
create policy zuno_event_media_update on storage.objects
  for update to authenticated
  using (bucket_id = 'event-media' and private.owns_organizer_folder((storage.foldername(name))[1]))
  with check (bucket_id = 'event-media' and private.owns_organizer_folder((storage.foldername(name))[1]));

drop policy if exists zuno_event_media_delete on storage.objects;
create policy zuno_event_media_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'event-media' and private.owns_organizer_folder((storage.foldername(name))[1]));

-- avatars: signed-in users may read; writes only under "<auth.uid()>/...".
drop policy if exists zuno_avatars_read on storage.objects;
create policy zuno_avatars_read on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars');

drop policy if exists zuno_avatars_insert on storage.objects;
create policy zuno_avatars_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists zuno_avatars_update on storage.objects;
create policy zuno_avatars_update on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists zuno_avatars_delete on storage.objects;
create policy zuno_avatars_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------------------------------------------------------------------------
-- Realtime (contract section 6): notifications, orders, wallet_ledger.
-- RLS applies to Realtime postgres_changes subscriptions.
-- ---------------------------------------------------------------------------
do $$
declare
  v_table text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if (select puballtables from pg_publication where pubname = 'supabase_realtime') then
    return;
  end if;
  foreach v_table in array array['notifications', 'orders', 'wallet_ledger'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_table
    ) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- pg_cron: expire stale orders / offers every minute, only if pg_cron exists.
-- (Enable the extension in the dashboard, then re-run this block; see
-- docs/backend/SUPABASE_SETUP.md.)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $cron$
      select cron.unschedule(jobid) from cron.job where jobname = 'zuno-expire-stale-orders'
    $cron$;
    execute $cron$
      select cron.schedule('zuno-expire-stale-orders', '* * * * *', 'select public.expire_stale_orders()')
    $cron$;
  else
    raise notice 'pg_cron is not installed: schedule public.expire_stale_orders() once it is enabled';
  end if;
end
$$;
