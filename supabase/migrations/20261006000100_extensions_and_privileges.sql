-- =============================================================================
-- Zuno 0100: extensions, schemas and the least-privilege baseline
--
-- * Extensions live in the `extensions` schema (Supabase convention).
-- * `private` holds helper / trigger functions. It is NOT exposed through
--   PostgREST (only `public` and `graphql_public` are), so nothing in it is
--   callable over HTTP. Usage is granted only so RLS policies evaluated as the
--   client role may call the few helpers explicitly granted to them.
-- * Supabase grants ALL on new public objects to anon/authenticated by default.
--   Zuno revokes those defaults: every client-visible privilege in later
--   migrations is granted explicitly and column-by-column where relevant.
-- =============================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_trgm with schema extensions;

create schema if not exists private;
comment on schema private is 'Zuno internal helpers and trigger functions. Not exposed via the Data API.';
revoke all on schema private from public;
grant usage on schema private to anon, authenticated, service_role;

-- Remove Supabase's permissive defaults for objects created by this role.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;
-- PostgreSQL grants EXECUTE on new functions to PUBLIC globally; revoke that too
-- so every function starts closed and is opened explicitly in 20261006001300.
alter default privileges revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- Generic helpers that do not depend on application tables.
-- ---------------------------------------------------------------------------

-- Server timestamps: every mutable table gets this BEFORE UPDATE trigger.
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Crockford base32 (0-9, A-Z without I, L, O, U). 256 % 32 = 0, so taking a
-- random byte modulo 32 is unbiased.
create or replace function private.random_crockford(p_length integer)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_bytes bytea := extensions.gen_random_bytes(p_length);
  v_out text := '';
begin
  for i in 0 .. p_length - 1 loop
    v_out := v_out || substr(v_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
  end loop;
  return v_out;
end;
$$;

-- 32 random bytes, base64url without padding = 43 characters (contract section 7).
create or replace function private.generate_qr_token()
returns text
language sql
volatile
set search_path = ''
as $$
  select rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
$$;

-- First day of the current calendar month in the business time zone.
create or replace function private.colombo_month(p_at timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select date_trunc('month', p_at at time zone 'Asia/Colombo')::date;
$$;

-- Raise a machine-readable error (contract section 3).
create or replace function private.fail(p_code text, p_detail text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_detail is null then
    raise exception using errcode = 'P0001', message = p_code;
  else
    raise exception using errcode = 'P0001', message = p_code, detail = p_detail;
  end if;
end;
$$;

-- Guard used by append-only tables against TRUNCATE.
create or replace function private.forbid_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = 'P0001', message = 'append_only_table', detail = tg_table_name;
end;
$$;
