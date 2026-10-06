-- 080: storage.objects policies (event-media / avatars path-prefix ownership)
begin;

do $$
declare
  v_owner uuid := tests.new_user('owner');
  v_org uuid := tests.new_organizer(v_owner, true);
  v_other_org uuid := tests.new_organizer(tests.new_user('otherowner'), true);
  v_u uuid := tests.new_user('member');
  v_v uuid := tests.new_user('member2');
  v_rows int;
begin
  insert into storage.objects (bucket_id, name) values ('avatars', v_v::text || '/avatar.jpg');
  insert into storage.objects (bucket_id, name) values ('event-media', v_other_org::text || '/cover.jpg');

  perform tests.as_user(v_owner);
  perform tests.lives(format($q$insert into storage.objects (bucket_id, name) values ('event-media', %L)$q$, v_org::text || '/events/cover.jpg'),
                      'organizer can upload under their organizer folder');
  perform tests.throws_state(format($q$insert into storage.objects (bucket_id, name) values ('event-media', %L)$q$, v_other_org::text || '/x.jpg'),
                             '42501', 'organizer cannot upload into another organizer''s folder');
  perform tests.throws_state($q$insert into storage.objects (bucket_id, name) values ('event-media', 'seed/x.jpg')$q$,
                             '42501', 'clients cannot write the seed/ folder');
  perform tests.throws_state($q$insert into storage.objects (bucket_id, name) values ('event-media', 'loose.jpg')$q$,
                             '42501', 'uploads outside any folder are rejected');
  update storage.objects set metadata = '{}' where bucket_id = 'event-media' and name = v_other_org::text || '/cover.jpg';
  get diagnostics v_rows = row_count;
  perform tests.is(v_rows, 0, 'organizer cannot modify another organizer''s media');
  delete from storage.objects where bucket_id = 'event-media' and name = v_other_org::text || '/cover.jpg';
  get diagnostics v_rows = row_count;
  perform tests.is(v_rows, 0, 'organizer cannot delete another organizer''s media');

  perform tests.as_user(v_u);
  perform tests.throws_state(format($q$insert into storage.objects (bucket_id, name) values ('event-media', %L)$q$, v_org::text || '/y.jpg'),
                             '42501', 'non-owners cannot upload event media');
  perform tests.lives(format($q$insert into storage.objects (bucket_id, name) values ('avatars', %L)$q$, v_u::text || '/avatar.jpg'),
                      'user can upload an avatar under their own folder');
  perform tests.throws_state(format($q$insert into storage.objects (bucket_id, name) values ('avatars', %L)$q$, v_v::text || '/evil.jpg'),
                             '42501', 'user cannot upload into another user''s avatar folder');
  delete from storage.objects where bucket_id = 'avatars' and name = v_v::text || '/avatar.jpg';
  get diagnostics v_rows = row_count;
  perform tests.is(v_rows, 0, 'user cannot delete another user''s avatar');
  perform tests.ok((select count(*) from storage.objects where bucket_id = 'avatars') >= 2, 'signed-in users can read avatars');
  perform tests.lives(format($q$update public.profiles set avatar_path = %L where id = %L$q$, v_u::text || '/avatar.jpg', v_u),
                      'profile avatar_path inside own folder is accepted');
  perform tests.throws(format($q$update public.profiles set avatar_path = %L where id = %L$q$, v_v::text || '/avatar.jpg', v_u),
                       'invalid_avatar_path', 'profile avatar_path must be inside the user''s folder');

  perform tests.as_anon();
  perform tests.ok((select count(*) from storage.objects where bucket_id = 'event-media') >= 1, 'anon can read event-media');
  perform tests.is((select count(*)::int from storage.objects where bucket_id = 'avatars'), 0, 'anon cannot read avatars');
  perform tests.throws_state($q$insert into storage.objects (bucket_id, name) values ('event-media', 'x/y.jpg')$q$, '42501',
                             'anon cannot upload');
  perform tests.as_postgres();
end
$$;

rollback;
