-- =====================================================================
-- Mika Shop: staff web-push subscriptions (Phase 1c, A4). ROLLED BACK.
-- Run: supabase db query --linked -f supabase/tests/order_push_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to anon, authenticated;
grant all on sequence _r_n_seq to anon, authenticated;

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
  if p_uid is null then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  else
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  end if;
end $$;
grant execute on function pg_temp.as_user(text) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000e1', 'pushtest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000e2', 'pushtest-owner@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000e3', 'pushtest-nostaff@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000e1', 'PUSHTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000e2', 'PUSHTEST owner', 'OWNER');

select pg_temp.try('public VAPID key setting exists', $q$select is_public::text from public.settings where key = 'push_public_key'$q$, 'true');
select pg_temp.try('push table has private language preference', $q$select column_name from information_schema.columns where table_schema = 'public' and table_name = 'push_subscriptions' and column_name = 'lang'$q$, 'lang');

set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('visitor cannot read device subscriptions', $q$select count(*)::text from public.push_subscriptions$q$, 'error:42501');
select pg_temp.try('visitor cannot save a device', $q$select public.save_push_subscription('https://push.example.test/anon', '123456789012345678901234567890', '1234567890', null, 'en')::text$q$, 'error:42501');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000e3');
select pg_temp.try('non-staff cannot save a device', $q$select public.save_push_subscription('https://push.example.test/nonstaff', '123456789012345678901234567890', '1234567890', null, 'en')::text$q$, 'error:42501');
select pg_temp.try('non-staff cannot see devices', $q$select count(*)::text from public.push_subscriptions$q$, '0');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000e1');
select pg_temp.try('ADMIN saves their own device', $q$select public.save_push_subscription('https://push.example.test/admin', '123456789012345678901234567890', '1234567890', 'PUSHTEST browser', 'ar')::text$q$, 'true');
select pg_temp.try('ADMIN sees own device and language', $q$select lang from public.push_subscriptions where endpoint = 'https://push.example.test/admin'$q$, 'ar');
select pg_temp.try('legacy four-argument save still works', $q$select public.save_push_subscription('https://push.example.test/legacy', '123456789012345678901234567890', '1234567890', 'PUSHTEST old browser')::text$q$, 'true');
select pg_temp.try('legacy save defaults to English', $q$select lang from public.push_subscriptions where endpoint = 'https://push.example.test/legacy'$q$, 'en');
select pg_temp.try('ADMIN cannot directly insert devices', $q$insert into public.push_subscriptions (user_id, endpoint, p256dh, auth) values (auth.uid(), 'https://push.example.test/direct', '123456789012345678901234567890', '1234567890') returning id::text$q$, 'error:42501');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000e2');
select pg_temp.try('OWNER cannot see another staff member device', $q$select count(*)::text from public.push_subscriptions$q$, '0');
select pg_temp.try('OWNER cannot take another staff member endpoint', $q$select public.save_push_subscription('https://push.example.test/admin', '123456789012345678901234567890', '1234567890', null, 'en')::text$q$, 'error:P0001:ENDPOINT_IN_USE');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000e1');
select pg_temp.try('ADMIN removes their own device', $q$select public.remove_push_subscription('https://push.example.test/admin')::text$q$, 'true');
select pg_temp.try('removed device no longer exists', $q$select count(*)::text from public.push_subscriptions where endpoint = 'https://push.example.test/admin'$q$, '0');
reset role;

select test, expected, got, expected = got as pass from _r order by n;
rollback;
