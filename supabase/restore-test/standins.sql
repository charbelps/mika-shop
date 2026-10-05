-- =====================================================================
-- Mika Shop restore test (Phase 1, step 13): stand-ins for the Supabase parts a plain
-- PostgreSQL doesn't have, so the public schema from a nightly dump can be restored
-- into a THROWAWAY local database. Never run this against TEST or LIVE.
--   * roles anon / authenticated / service_role (the GRANTs in the dump need them)
--   * schema auth + auth.uid() / auth.role() / auth.jwt() reading the test claims
--     (auth.users itself comes from the dump)
--   * net.http_post(): records the call in net.calls instead of sending anything,
--     so a restored copy can never call the real alert function
--   * empty publication supabase_realtime (the dump adds the orders table to it)
-- Not provided on purpose: Storage (photos are not in database dumps) and pg_cron.
-- =====================================================================
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create role supabase_admin nologin;   -- only named in the dump's default-privilege entries

create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                         nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid
$$;
create function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
$$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
grant execute on all functions in schema auth to anon, authenticated, service_role;

create schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;

create schema net;
create table net.calls (id bigserial primary key, url text, body jsonb, called_at timestamptz default now());
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
                              headers jsonb default '{}', timeout_milliseconds int default 5000)
returns bigint language sql as $$
  insert into net.calls (url, body) values (url, body) returning id
$$;

create publication supabase_realtime;
