-- =====================================================================
-- Mika Shop: "delivery fee to be confirmed" switch (migration 24, C1). ROLLED BACK.
-- Needs the test data (supabase/tests/test_data.sql) and at least one active area with no fee.
-- Run:  supabase db query --linked -f supabase/tests/fee_tbc_test.sql
-- =====================================================================
begin;

-- Since migration 32 the website allows only N unfinished orders per phone. These checks place
-- many orders from one phone, so the limit is off inside this (rolled back) test; the limit
-- itself is tested in open_orders_limit_test.sql.
update public.settings set value = '' where key = 'max_open_orders_per_phone';

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
create function pg_temp.cust(p_zone text, p_phone text default '70 888 111') returns jsonb language sql as $$
  select jsonb_build_object('name', '[TEST] Fee buyer', 'phone', p_phone, 'zone_id', p_zone,
    'town', 'Testville', 'address', 'Bldg: fee', 'landmark', '', 'location_url', '') $$;
grant execute on function pg_temp.cust(text, text) to anon, authenticated;
-- the order behind a place_order answer: "fee_tbc fee total"
create function pg_temp.o(p_res jsonb) returns text language sql security definer as $$
  select fee_tbc || ' ' || delivery_fee || ' ' || total from public.orders where order_no = p_res->>'order_no' $$;
grant execute on function pg_temp.o(jsonb) to anon, authenticated;
create function pg_temp.id_of(p_res jsonb) returns bigint language sql security definer as $$
  select id from public.orders where order_no = p_res->>'order_no' $$;
grant execute on function pg_temp.id_of(jsonb) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000b1', 'feetest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000b2', 'feetest-owner@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000b1', 'FEETEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000b2', 'FEETEST owner', 'OWNER');

insert into _v select 'nofee', min(id)::text from public.delivery_zones where active and fee is null;
insert into _v select 'fee',   id::text from public.delivery_zones where district = '[TEST] District';
update public.settings set value = '76 000 000' where key = 'whish_number';

-- ---------- schema + setting ----------
select pg_temp.try('there is an active area without a fee to test with', $q$select (pg_temp.v('nofee') is not null)::text$q$, 'true');
select pg_temp.try('switch exists, public, OFF by default', $q$select is_public || ' [' || value || ']' from public.settings where key = 'fee_tbc_enabled'$q$, 'true []');
select pg_temp.try('older orders: fee_tbc false', $q$select count(*)::text from public.orders where fee_tbc$q$, '0');

-- ---------- switch OFF: refused as before ----------
set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('OFF: area without fee refused', $q$select public.place_order(pg_temp.cust(pg_temp.v('nofee')), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', '')::text$q$, 'error:P0001:ZONE_FEE_NOT_SET');
select pg_temp.try('OFF: area with a fee works as before', $q$select pg_temp.o(public.place_order(pg_temp.cust(pg_temp.v('fee')), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', ''))$q$, 'false 2.50 10.50');
reset role;

-- ---------- who may flip the switch ----------
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000b2');
select pg_temp.try('OWNER cannot switch it on', $q$select public.admin_save_settings('{"fee_tbc_enabled":"on"}')::text$q$, 'error:42501');
select pg_temp.as_user('00000000-0000-4000-8000-0000000000b1');
select pg_temp.try('only "" or "on" accepted', $q$select public.admin_save_settings('{"fee_tbc_enabled":"yes"}')::text$q$, 'error:P0001:BAD_SWITCH');
select pg_temp.try('ADMIN switches it on', $q$select public.admin_save_settings('{"fee_tbc_enabled":"on"}')::text$q$, '1');
reset role;

-- ---------- switch ON ----------
set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('ON: website COD order in an area without fee goes through',
  $q$select pg_temp.o(public.place_order(pg_temp.cust(pg_temp.v('nofee')), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', ''))$q$, 'true 0.00 8.00');
select pg_temp.try('... the shop is told the fee is to be confirmed',
  $q$select (public.place_order(pg_temp.cust(pg_temp.v('nofee')), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', '')->>'fee_to_confirm')$q$, 'true');
insert into _v select 'w', pg_temp.id_of(public.place_order(pg_temp.cust(pg_temp.v('nofee'), '70 888 222'), '[{"sku":"TEST-MUG-01","qty":2}]', 'WHISH', ''))::text;
select pg_temp.try('ON: Whish still offered there (items only)', $q$select (pg_temp.v('w') is not null)::text$q$, 'true');
select pg_temp.try('ON: area WITH a fee unchanged', $q$select pg_temp.o(public.place_order(pg_temp.cust(pg_temp.v('fee')), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', ''))$q$, 'false 2.50 10.50');
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000b1');
insert into _v select 's', (public.staff_place_order(pg_temp.cust(pg_temp.v('nofee'), '70 888 333'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE', '')->>'order_id');
select pg_temp.try('ON: staff phone order in an area without fee', $q$select fee_tbc || ' ' || status from public.orders where id = pg_temp.v('s')::bigint$q$, 'true CONFIRMED');
reset role;

-- ---------- setting the fee afterwards ----------
set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('visitor cannot set a fee', $q$select public.staff_set_delivery_fee(pg_temp.v('s')::bigint, 4.5)::text$q$, 'error:42501');
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000b2');
select pg_temp.try('OWNER cannot set a fee', $q$select public.staff_set_delivery_fee(pg_temp.v('s')::bigint, 4.5)::text$q$, 'error:42501');
select pg_temp.as_user('00000000-0000-4000-8000-0000000000b1');
insert into _v select 'spent0', total_spent::text from public.customers where phone = '+96170888333';
select pg_temp.try('ADMIN sets 4.50 -> total 12.50', $q$select public.staff_set_delivery_fee(pg_temp.v('s')::bigint, 4.5)->>'total'$q$, '12.50');
select pg_temp.try('... order: fee, total, set time', $q$select delivery_fee || ' ' || total || ' ' || (fee_set_at is not null) || ' ' || fee_tbc from public.orders where id = pg_temp.v('s')::bigint$q$, '4.50 12.50 true true');
select pg_temp.try('... customer total spent +4.50', $q$select (total_spent - pg_temp.v('spent0')::numeric)::text from public.customers where phone = '+96170888333'$q$, '4.50');
select pg_temp.try('correction to 5 -> total 13.00', $q$select public.staff_set_delivery_fee(pg_temp.v('s')::bigint, 5)->>'total'$q$, '13.00');
select pg_temp.try('... customer total spent +5 in all', $q$select (total_spent - pg_temp.v('spent0')::numeric)::text from public.customers where phone = '+96170888333'$q$, '5.00');
select pg_temp.try('negative fee refused', $q$select public.staff_set_delivery_fee(pg_temp.v('s')::bigint, -1)::text$q$, 'error:P0001:BAD_FEE');
select pg_temp.try('3 decimals refused', $q$select public.staff_set_delivery_fee(pg_temp.v('s')::bigint, 1.234)::text$q$, 'error:P0001:BAD_FEE');
select pg_temp.try('order with a normal fee: refused', $q$select public.staff_set_delivery_fee((select id from public.orders where fee_tbc = false order by id desc limit 1), 3)::text$q$, 'error:P0001:FEE_NOT_TO_CONFIRM');
select pg_temp.try('Whish order: fee set, items stay what was paid',
  $q$select public.staff_set_delivery_fee(pg_temp.v('w')::bigint, 3)->>'total' || ' ' || (select subtotal from public.orders where id = pg_temp.v('w')::bigint)$q$, '19.00 16.00');
select pg_temp.try('cancelled order: refused',
  $q$select public.cancel_order(pg_temp.v('w')::bigint, '[TEST] fee test', false)::text is not null and public.staff_set_delivery_fee(pg_temp.v('w')::bigint, 2)::text is not null$q$, 'error:P0001:BAD_STATUS_CHANGE');
select pg_temp.try('switch off again', $q$select public.admin_save_settings('{"fee_tbc_enabled":""}')::text$q$, '1');
reset role;
set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('OFF again: refused again', $q$select public.place_order(pg_temp.cust(pg_temp.v('nofee')), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', '')::text$q$, 'error:P0001:ZONE_FEE_NOT_SET');
reset role;

select test, expected, got, expected = got as pass from _r order by n;
rollback;
