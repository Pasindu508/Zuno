-- =============================================================================
-- Supabase environment stubs for vanilla PostgreSQL  (LOCAL VERIFICATION ONLY)
--
-- A hosted Supabase project already provides the roles, the `auth`, `storage`
-- and `extensions` schemas, the Realtime publication and the default
-- privileges below. This file recreates the minimum subset of that environment
-- on a plain PostgreSQL 17 cluster so that `supabase/migrations/*.sql` and
-- `supabase/seed.sql` can be applied and tested without Docker or the CLI.
--
-- It is NOT a migration and must never be applied to a Supabase project.
-- Shapes follow the GoTrue / Storage schemas closely enough for the columns
-- our migrations and seed touch; everything else is omitted.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Roles (Supabase: anon / authenticated are NOLOGIN, service_role BYPASSRLS,
-- PostgREST connects as authenticator and switches role per request).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
end
$$;

grant anon, authenticated, service_role to authenticator;

-- ---------------------------------------------------------------------------
-- Schemas and extensions (Supabase installs extensions into "extensions").
-- ---------------------------------------------------------------------------
create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

grant usage on schema public to anon, authenticated, service_role;

-- Supabase's default privileges: everything created by `postgres` in public is
-- granted to the API roles. Our migrations explicitly revoke these defaults, so
-- reproducing them here makes the least-privilege tests meaningful.
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- auth schema (subset of GoTrue)
-- ---------------------------------------------------------------------------
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table if not exists auth.users (
  instance_id uuid,
  id uuid primary key default gen_random_uuid(),
  aud varchar(255),
  role varchar(255),
  email varchar(255),
  encrypted_password varchar(255),
  email_confirmed_at timestamptz,
  invited_at timestamptz,
  confirmation_token varchar(255),
  confirmation_sent_at timestamptz,
  recovery_token varchar(255),
  recovery_sent_at timestamptz,
  email_change_token_new varchar(255),
  email_change varchar(255),
  email_change_sent_at timestamptz,
  email_change_token_current varchar(255) default '',
  email_change_confirm_status smallint default 0,
  reauthentication_token varchar(255) default '',
  last_sign_in_at timestamptz,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb,
  is_super_admin boolean,
  phone text unique default null,
  phone_confirmed_at timestamptz,
  banned_until timestamptz,
  is_sso_user boolean not null default false,
  is_anonymous boolean not null default false,
  deleted_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create unique index if not exists users_email_partial_key on auth.users (email) where is_sso_user = false;

create table if not exists auth.identities (
  id uuid primary key default gen_random_uuid(),
  provider_id text not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  identity_data jsonb not null,
  provider text not null,
  last_sign_in_at timestamptz,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  email text generated always as (lower(identity_data ->> 'email')) stored,
  constraint identities_provider_id_provider_unique unique (provider_id, provider)
);

-- auth.uid()/role()/jwt() read the claims PostgREST places in request.jwt.claims.
create or replace function auth.jwt() returns jsonb
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

create or replace function auth.uid() returns uuid
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

grant execute on function auth.uid(), auth.role(), auth.jwt() to anon, authenticated, service_role;
grant select on auth.users to service_role;

-- ---------------------------------------------------------------------------
-- storage schema (subset of supabase/storage)
-- ---------------------------------------------------------------------------
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;

create table if not exists storage.buckets (
  id text primary key,
  name text not null unique,
  owner uuid,
  owner_id text,
  public boolean default false,
  avif_autodetection boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text,
  owner uuid,
  owner_id text,
  metadata jsonb,
  path_tokens text[] generated always as (string_to_array(name, '/')) stored,
  version text,
  user_metadata jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  last_accessed_at timestamptz default now(),
  constraint bucketid_objname unique (bucket_id, name)
);

alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;
grant all on storage.buckets, storage.objects to anon, authenticated, service_role;

create or replace function storage.foldername(name text) returns text[]
language plpgsql immutable
as $$
declare
  _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end
$$;

create or replace function storage.filename(name text) returns text
language plpgsql immutable
as $$
declare
  _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[array_length(_parts, 1)];
end
$$;

grant execute on function storage.foldername(text), storage.filename(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Realtime publication (Supabase creates it empty; tables are added by apps).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end
$$;
