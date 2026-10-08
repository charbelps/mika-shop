-- =====================================================================
-- Mika Shop: order language + payment texts (migration 21, 8 Oct 2026). ROLLED BACK.
-- Needs the test data (supabase/tests/test_data.sql).
-- Run:  supabase db query --linked -f supabase/tests/order_lang_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to anon, authenticated;
grant all on sequence _r_n_seq to anon, authenticated;
create temp table _v (k text primary key, v text);
grant all on _v to anon, authenticated;

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
create function pg_temp.v(p_k text) returns text language sql as $$ select v from pg_temp._v where k = p_k $$;
grant execute on function pg_temp.v(text) to anon, authenticated;
create function pg_temp.as_user(p_uid text) returns void language plpgsql as $$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  else
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  end if;
end $$;
grant execute on function pg_temp.as_user(text) to anon, authenticated;
-- a customer for the test zone, with an optional language
create function pg_temp.cust(p_lang text) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('name', '[TEST] Lang buyer', 'phone', '71 555 777', 'zone_id', pg_temp.v('zone'),
    'town', 'Testville', 'address', 'Bldg: lang', 'landmark', '', 'location_url', '', 'lang', p_lang)) $$;
grant execute on function pg_temp.cust(text) to anon, authenticated;
-- the language stored on the order with this number
create function pg_temp.lang_of(p_result jsonb) returns text language sql security definer as $$
  select coalesce(lang, 'null') from public.orders where order_no = p_result->>'order_no' $$;
grant execute on function pg_temp.lang_of(jsonb) to anon, authenticated;
create function pg_temp.status_of(p_result jsonb) returns text language sql security definer as $$
  select status from public.orders where order_no = p_result->>'order_no' $$;
grant execute on function pg_temp.status_of(jsonb) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000d1', 'langtest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d2', 'langtest-owner@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000d1', 'LANGTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000d2', 'LANGTEST owner', 'OWNER');
insert into _v select 'zone', id::text from public.delivery_zones where district = '[TEST] District';

-- ---------- schema ----------
select pg_temp.try('orders.lang exists, allows en / ar only',
  $q$select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.orders'::regclass and pg_get_constraintdef(oid) like '%lang%'$q$,
  'CHECK ((lang = ANY (ARRAY[''en''::text, ''ar''::text])))');
select pg_temp.try('older orders keep an empty language', $q$select count(*)::text from public.orders where lang is not null and created_at < '2026-10-08'$q$, '0');
select pg_temp.try('visitor cannot run the language trigger function',
  $q$select has_function_privilege('anon', 'public.set_order_lang()', 'execute')::text$q$, 'false');

-- ---------- website orders (visitor) ----------
set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('Arabic shop -> order lang ar',
  $q$select pg_temp.lang_of(public.place_order(pg_temp.cust('ar'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', ''))$q$, 'ar');
select pg_temp.try('English shop -> order lang en',
  $q$select pg_temp.lang_of(public.place_order(pg_temp.cust('en'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', ''))$q$, 'en');
select pg_temp.try('no language sent (old shop page) -> empty',
  $q$select pg_temp.lang_of(public.place_order(pg_temp.cust(null), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', ''))$q$, 'null');
select pg_temp.try('unknown language "fr" -> empty, order still placed',
  $q$select pg_temp.lang_of(public.place_order(pg_temp.cust('fr'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', ''))$q$, 'null');
select pg_temp.try('website answer still has no order_id',
  $q$select (public.place_order(pg_temp.cust('ar'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', '') ? 'order_id')::text$q$, 'false');
select pg_temp.try('honeypot still refused',
  $q$select public.place_order(pg_temp.cust('ar'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'bot')::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('visitor still cannot read orders', $q$select count(*)::text from public.orders$q$, 'error:42501');
reset role;

-- ---------- staff orders ----------
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000d1');
select pg_temp.try('staff order with Arabic picked -> ar',
  $q$select pg_temp.lang_of(public.staff_place_order(pg_temp.cust('ar'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE', ''))$q$, 'ar');
select pg_temp.try('staff order still starts CONFIRMED',
  $q$select pg_temp.status_of(public.staff_place_order(pg_temp.cust('en'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'WHATSAPP', ''))$q$, 'CONFIRMED');
select pg_temp.try('ADMIN reads the language on the order',
  $q$select lang from public.orders where name = '[TEST] Lang buyer' and source = 'WHATSAPP'$q$, 'en');
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000d2');
select pg_temp.try('OWNER still cannot enter orders',
  $q$select public.staff_place_order(pg_temp.cust('ar'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE', '')::text$q$, 'error:42501');
reset role;

-- ---------- payment texts ----------
select pg_temp.try('8 payment texts exist, all public, all empty',
  $q$select count(*)::text from public.settings where key in ('whish_checkout_en','whish_checkout_ar','whish_confirm_en','whish_confirm_ar',
    'omt_checkout_en','omt_checkout_ar','omt_confirm_en','omt_confirm_ar') and is_public and value = ''$q$, '8');
set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('visitor reads a payment text', $q$select count(*)::text from public.settings where key = 'whish_confirm_ar'$q$, '1');
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000d1');
select pg_temp.try('ADMIN saves Whish text EN + AR',
  $q$select public.admin_save_settings('{"whish_confirm_en":"Send {total} to {number}, note {no}.","whish_confirm_ar":"حوّل {total} على {number}"}')::text$q$, '2');
select pg_temp.try('... saved exactly', $q$select value from public.settings where key = 'whish_confirm_ar'$q$, 'حوّل {total} على {number}');
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000d2');
select pg_temp.try('OWNER cannot change payment texts', $q$select public.admin_save_settings('{"omt_checkout_en":"x"}')::text$q$, 'error:42501');
reset role;

select test, expected, got, expected = got as pass from _r order by n;
rollback;
