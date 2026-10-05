-- =====================================================================
-- Mika Shop: staff safety test (staff_guard trigger, service_role grant). ROLLED BACK.
-- Run:  supabase db query --linked -f supabase/tests/staff_guard_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to anon, authenticated, service_role;
grant all on sequence _r_n_seq to anon, authenticated, service_role;

create function pg_temp.try(p_test text, p_sql text, p_expected text)
returns void language plpgsql as $$
declare v_got text;
begin
  begin
    execute p_sql into v_got;
  exception when others then
    v_got := 'error:' || sqlstate || case when sqlstate = 'P0001' then ':' || sqlerrm else '' end;
  end;
  insert into pg_temp._r (test, expected, got) values (p_test, p_expected, coalesce(v_got, 'null'));
end $$;
create function pg_temp.as_user(p_uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
end $$;

-- start from a known state: only test people in staff (rolled back at the end)
alter table public.staff disable trigger staff_guard;
delete from public.staff;
alter table public.staff enable trigger staff_guard;
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000c1', 'guardtest-a@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000c2', 'guardtest-b@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000c3', 'guardtest-c@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000c1', 'GUARD admin A', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000c2', 'GUARD owner B', 'OWNER');

-- as admin A (logged in)
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000c1');
select pg_temp.try('A deactivates themselves -> CANNOT_CHANGE_SELF',
  $q$update public.staff set active = false where user_id = '00000000-0000-4000-8000-0000000000c1'$q$, 'error:P0001:CANNOT_CHANGE_SELF');
select pg_temp.try('A demotes themselves -> CANNOT_CHANGE_SELF',
  $q$update public.staff set role = 'OWNER' where user_id = '00000000-0000-4000-8000-0000000000c1'$q$, 'error:P0001:CANNOT_CHANGE_SELF');
select pg_temp.try('A deletes themselves -> CANNOT_CHANGE_SELF',
  $q$delete from public.staff where user_id = '00000000-0000-4000-8000-0000000000c1'$q$, 'error:P0001:CANNOT_CHANGE_SELF');
select pg_temp.try('A renames themselves -> fine',
  $q$with u as (update public.staff set name = 'GUARD admin A2' where user_id = '00000000-0000-4000-8000-0000000000c1' returning name) select name from u$q$, 'GUARD admin A2');
select pg_temp.try('A changes owner B -> fine',
  $q$with u as (update public.staff set role = 'DRIVER', active = false where user_id = '00000000-0000-4000-8000-0000000000c2' returning role || active) select * from u$q$, 'DRIVERfalse');
reset role;

-- no one logged in (SQL editor / service): the last admin still can't go
select set_config('request.jwt.claims', '', true);
select pg_temp.try('last active admin deactivated (no login) -> LAST_ADMIN',
  $q$update public.staff set active = false where user_id = '00000000-0000-4000-8000-0000000000c1'$q$, 'error:P0001:LAST_ADMIN');
select pg_temp.try('last active admin deleted (no login) -> LAST_ADMIN',
  $q$delete from public.staff where user_id = '00000000-0000-4000-8000-0000000000c1'$q$, 'error:P0001:LAST_ADMIN');

-- with a second admin C, A can be demoted by C
insert into public.staff (user_id, name, role) values ('00000000-0000-4000-8000-0000000000c3', 'GUARD admin C', 'ADMIN');
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000c3');
select pg_temp.try('C demotes A (C stays admin) -> fine',
  $q$with u as (update public.staff set role = 'OWNER' where user_id = '00000000-0000-4000-8000-0000000000c1' returning role) select role from u$q$, 'OWNER');
select pg_temp.try('C is now the last admin, deactivating themselves -> refused',
  $q$update public.staff set active = false where user_id = '00000000-0000-4000-8000-0000000000c3'$q$, 'error:P0001:CANNOT_CHANGE_SELF');
reset role;

-- the Edge Function's key may read / add / change staff, not delete
set local role service_role;
select pg_temp.try('service_role reads staff', $q$select count(*)::text from public.staff$q$, '3');
select pg_temp.try('service_role cannot delete staff', $q$delete from public.staff where user_id = '00000000-0000-4000-8000-0000000000c2'$q$, 'error:42501');
reset role;

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
