-- =====================================================================
-- Mika Shop: packing tab ticks (migration 22, P1). ROLLED BACK.
-- Needs the test data (supabase/tests/test_data.sql).
-- Run:  supabase db query --linked -f supabase/tests/packing_test.sql
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
-- ticks of one order as "picked/checked" pairs, in item order
create function pg_temp.ticks(p_order text) returns text language sql security definer as $$
  select string_agg(picked::text || '/' || checked::text, ' ' order by id) from public.order_items where order_id = p_order::bigint $$;
grant execute on function pg_temp.ticks(text) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000c1', 'packtest-admin@example.test',   'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000c2', 'packtest-owner@example.test',   'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000c3', 'packtest-driver@example.test',  'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000c4', 'packtest-nostaff@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000c1', 'PACKTEST admin',  'ADMIN'),
  ('00000000-0000-4000-8000-0000000000c2', 'PACKTEST owner',  'OWNER'),
  ('00000000-0000-4000-8000-0000000000c3', 'PACKTEST driver', 'DRIVER');

-- two COD orders from the shop: A (mug + candle), B (mug)
create function pg_temp.place(p_name text, p_items text) returns text language plpgsql as $$
declare v_no text;
begin
  v_no := public.place_order(jsonb_build_object('name', p_name, 'phone', '70 444 555',
    'zone_id', (select id from public.delivery_zones where district = '[TEST] District'),
    'town', 'Testville', 'address', 'Bldg: pack'), p_items::jsonb, 'COD') ->> 'order_no';
  return (select id::text from public.orders where order_no = v_no);
end $$;
insert into _v select 'A', pg_temp.place('[TEST] pack A', '[{"sku":"TEST-MUG-01","qty":2},{"sku":"TEST-CANDLE-01","qty":1}]');
insert into _v select 'B', pg_temp.place('[TEST] pack B', '[{"sku":"TEST-MUG-01","qty":1}]');
insert into _v select 'A1', min(id)::text from public.order_items where order_id = pg_temp.v('A')::bigint;
insert into _v select 'A2', max(id)::text from public.order_items where order_id = pg_temp.v('A')::bigint;
insert into _v select 'B1', min(id)::text from public.order_items where order_id = pg_temp.v('B')::bigint;

-- ---------- schema ----------
select pg_temp.try('new items start unticked', $q$select pg_temp.ticks(pg_temp.v('A'))$q$, 'false/false false/false');
select pg_temp.try('older items unticked too (default false)', $q$select count(*)::text from public.order_items where picked or checked$q$, '0');
select pg_temp.try('order_items in the realtime publication',
  $q$select count(*)::text from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'order_items'$q$, '1');

-- ---------- who may tick ----------
set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('visitor cannot tick', $q$select public.staff_tick_items(array[pg_temp.v('A1')::bigint], 'checked', true)::text$q$, 'error:42501');
select pg_temp.try('visitor cannot read items', $q$select count(*)::text from public.order_items$q$, 'error:42501');
reset role;
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000c4');
select pg_temp.try('logged-in non-staff cannot tick', $q$select public.staff_tick_items(array[pg_temp.v('A1')::bigint], 'checked', true)::text$q$, 'error:42501');
select pg_temp.as_user('00000000-0000-4000-8000-0000000000c2');
select pg_temp.try('OWNER cannot tick', $q$select public.staff_tick_items(array[pg_temp.v('A1')::bigint], 'checked', true)::text$q$, 'error:42501');
select pg_temp.try('OWNER can see the ticks', $q$select (picked or checked)::text from public.order_items where id = pg_temp.v('A1')::bigint$q$, 'false');
select pg_temp.as_user('00000000-0000-4000-8000-0000000000c3');
select pg_temp.try('DRIVER cannot tick', $q$select public.staff_tick_items(array[pg_temp.v('A1')::bigint], 'checked', true)::text$q$, 'error:42501');
reset role;

-- ---------- ADMIN ----------
set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000c1');
select pg_temp.try('ADMIN ticks both items of A as in the box', $q$select public.staff_tick_items(array[pg_temp.v('A1')::bigint, pg_temp.v('A2')::bigint], 'checked', true)::text$q$, '2');
select pg_temp.try('... checked set, picked untouched', $q$select pg_temp.ticks(pg_temp.v('A'))$q$, 'false/true false/true');
select pg_temp.try('pick list tick: mugs of A and B picked in one call', $q$select public.staff_tick_items(array[pg_temp.v('A1')::bigint, pg_temp.v('B1')::bigint], 'picked', true)::text$q$, '2');
select pg_temp.try('... A: mug picked + checked, candle checked only', $q$select pg_temp.ticks(pg_temp.v('A'))$q$, 'true/true false/true');
select pg_temp.try('... B: mug picked', $q$select pg_temp.ticks(pg_temp.v('B'))$q$, 'true/false');
select pg_temp.try('untick', $q$select public.staff_tick_items(array[pg_temp.v('A2')::bigint], 'checked', false)::text$q$, '1');
select pg_temp.try('... candle back to unticked', $q$select pg_temp.ticks(pg_temp.v('A'))$q$, 'true/true false/false');
select pg_temp.try('unknown field refused', $q$select public.staff_tick_items(array[pg_temp.v('A1')::bigint], 'price', true)::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('empty list refused', $q$select public.staff_tick_items(array[]::bigint[], 'checked', true)::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('no value refused', $q$select public.staff_tick_items(array[pg_temp.v('A1')::bigint], 'checked', null)::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('unknown item id: nothing changed', $q$select public.staff_tick_items(array[999999999::bigint], 'checked', true)::text$q$, '0');
select pg_temp.try('confirmed order can still be ticked',
  $q$select public.staff_set_status(pg_temp.v('B')::bigint, 'CONFIRMED') || ' ' || public.staff_tick_items(array[pg_temp.v('B1')::bigint], 'checked', true)$q$, 'CONFIRMED 1');
select pg_temp.try('mark A packed (ticks never block)', $q$select public.staff_set_status(pg_temp.v('A')::bigint, 'PACKED')$q$, 'PACKED');
select pg_temp.try('packed order: ticks frozen', $q$select public.staff_tick_items(array[pg_temp.v('A2')::bigint], 'checked', true)::text$q$, '0');
select pg_temp.try('... and unchanged', $q$select pg_temp.ticks(pg_temp.v('A'))$q$, 'true/true false/false');
select pg_temp.try('cancelled order: ticks frozen',
  $q$select public.cancel_order(pg_temp.v('B')::bigint, '[TEST] pack test', false)::text is not null and public.staff_tick_items(array[pg_temp.v('B1')::bigint], 'checked', false) = 0$q$, 'true');
reset role;

select test, expected, got, expected = got as pass from _r order by n;
rollback;
