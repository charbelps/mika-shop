-- =====================================================================
-- Mika Shop: staff orders test (F7: staff_place_order, orders.source). ROLLED BACK.
-- (The phone_number setting was removed on 6 Oct: Call us uses the WhatsApp number.)
-- Needs the test data (supabase/tests/test_data.sql).
-- Run:  supabase db query --linked -f supabase/tests/staff_orders_test.sql
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
-- a customer for the test zone
create function pg_temp.cust(p_phone text default '71 555 666') returns jsonb language sql as $$
  select jsonb_build_object('name', '[TEST] Phone buyer', 'phone', p_phone, 'zone_id', pg_temp.v('zone'),
    'town', 'Testville', 'address', 'Bldg: staff', 'landmark', '', 'location_url', '') $$;
grant execute on function pg_temp.cust(text) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000e1', 'stafforder-admin@example.test',  'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000e2', 'stafforder-owner@example.test',  'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000e3', 'stafforder-driver@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000e1', 'STAFFORDER admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000e2', 'STAFFORDER owner', 'OWNER'),
  ('00000000-0000-4000-8000-0000000000e3', 'STAFFORDER driver', 'DRIVER');

insert into _v select 'zone', id::text from public.delivery_zones where district = '[TEST] District';
insert into _v select 'tsh_s', id::text from public.variants where sku = 'TEST-TSHIRT-01' and label_en = 'Size S / White';
insert into _v select 'mug0', stock::text from public.products where sku = 'TEST-MUG-01';
insert into _v select 'tsh_s0', stock::text from public.variants where id = (select v::bigint from _v where k = 'tsh_s');
insert into _v select 'mug_price', price::text from public.products where sku = 'TEST-MUG-01';
insert into _v select 'last0', stock::text from public.products where sku = 'TEST-LAST-01';

-- ---------- schema ----------
select pg_temp.try('orders.source: default WEBSITE, 4 allowed values',
  $q$select (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'orders' and column_name = 'source')
     || ' ' || (select pg_get_constraintdef(oid) ~ 'WEBSITE.*PHONE.*INSTAGRAM.*WHATSAPP' from pg_constraint where conname = 'orders_source_check')::text$q$,
  '''WEBSITE''::text true');
select pg_temp.try('setting phone_number gone (Call us = WhatsApp number)', $q$select count(*)::text from public.settings where key = 'phone_number'$q$, '0');

-- ---------- visitor ----------
set local role anon; select pg_temp.as_user(null);
select pg_temp.try('visitor can read whatsapp_number (used by Call us)', $q$select count(*)::text from public.settings where key = 'whatsapp_number'$q$, '1');
select pg_temp.try('visitor staff_place_order -> refused',
  $q$select public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE')$q$, 'error:42501');
select pg_temp.try('visitor place_order_core -> refused',
  $q$select public.place_order_core(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE', 'CONFIRMED')$q$, 'error:42501');
-- the shop's own checkout still works and is marked WEBSITE / NEW, answer has no order_id
select pg_temp.try('visitor place_order still works, answer without order_id',
  $q$with r as (select public.place_order(pg_temp.cust('71 555 000'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD') o)
     select (o ? 'order_no')::text || ',' || (o ? 'order_id')::text from r$q$, 'true,false');
reset role;
select pg_temp.try('website order saved as WEBSITE / NEW',
  $q$select source || ' ' || status from public.orders where phone = '+96171555000' order by id desc limit 1$q$, 'WEBSITE NEW');

-- ---------- OWNER / DRIVER ----------
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000e2');
select pg_temp.try('OWNER staff_place_order -> refused',
  $q$select public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE')$q$, 'error:42501');
reset role;
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000e3');
select pg_temp.try('DRIVER staff_place_order -> refused',
  $q$select public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE')$q$, 'error:42501');
reset role;

-- ---------- ADMIN ----------
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000e1');
select pg_temp.try('ADMIN: bad source WEBSITE -> INVALID_INPUT',
  $q$select public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'WEBSITE')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('ADMIN: bad source null -> INVALID_INPUT',
  $q$select public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', null)$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('ADMIN: bad phone -> INVALID_PHONE',
  $q$select public.staff_place_order(pg_temp.cust('123'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE')$q$, 'error:P0001:INVALID_PHONE');
select pg_temp.try('ADMIN: Whish while whish_number empty -> PAYMENT_NOT_AVAILABLE',
  $q$select public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'WHISH', 'PHONE')$q$, 'error:P0001:PAYMENT_NOT_AVAILABLE');
select pg_temp.try('ADMIN: hidden product -> ITEM_UNAVAILABLE',
  $q$select public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-BOARD-01","qty":1}]', 'COD', 'PHONE')$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('ADMIN: more than stock -> OUT_OF_STOCK',
  $q$select public.staff_place_order(pg_temp.cust(), jsonb_build_array(jsonb_build_object('sku', 'TEST-LAST-01', 'qty', pg_temp.v('last0')::int + 1)), 'COD', 'PHONE')$q$, 'error:P0001:OUT_OF_STOCK');
select pg_temp.try('ADMIN: notes over 1000 chars -> INVALID_INPUT',
  $q$select public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'PHONE', repeat('x', 1001))$q$, 'error:P0001:INVALID_INPUT');

-- a real phone order: 2 mugs (browser price ignored) + 1 T-shirt S, Instagram, with notes
insert into _v select 'ord', public.staff_place_order(pg_temp.cust('+961 71-555-666'),
  jsonb_build_array(jsonb_build_object('sku', 'TEST-MUG-01', 'qty', 2, 'price', 0),
                    jsonb_build_object('sku', 'TEST-TSHIRT-01', 'variant_id', pg_temp.v('tsh_s')::bigint, 'qty', 1)),
  'COD', 'INSTAGRAM', '  Gift wrap please  ')::text;
reset role;

select pg_temp.try('answer has order_id + order_no',
  $q$select ((pg_temp.v('ord')::jsonb ? 'order_id') and (pg_temp.v('ord')::jsonb ? 'order_no'))::text$q$, 'true');
select pg_temp.try('order saved: INSTAGRAM, CONFIRMED, COD UNPAID, phone normalized, notes trimmed',
  $q$select source || ' ' || status || ' ' || payment_method || ' ' || payment_status || ' ' || phone || ' ' || notes
     from public.orders where id = (pg_temp.v('ord')::jsonb->>'order_id')::bigint$q$,
  'INSTAGRAM CONFIRMED COD UNPAID +96171555666 Gift wrap please');
select pg_temp.try('prices from the database (2 x mug price + T-shirt + fee 2.50)',
  $q$select (o.subtotal = 2 * pg_temp.v('mug_price')::numeric + (select coalesce(v.price, p.price) from public.variants v join public.products p using (sku) where v.id = pg_temp.v('tsh_s')::bigint)
            and o.delivery_fee = 2.50 and o.total = o.subtotal + 2.50)::text
     from public.orders o where o.id = (pg_temp.v('ord')::jsonb->>'order_id')::bigint$q$, 'true');
select pg_temp.try('2 order lines saved',
  $q$select count(*)::text from public.order_items where order_id = (pg_temp.v('ord')::jsonb->>'order_id')::bigint$q$, '2');
select pg_temp.try('stock taken: mug -2, T-shirt S -1',
  $q$select (pg_temp.v('mug0')::int - (select stock from public.products where sku = 'TEST-MUG-01') - 1) || ',' ||
            (pg_temp.v('tsh_s0')::int - (select stock from public.variants where id = pg_temp.v('tsh_s')::bigint))$q$, '2,1');
select pg_temp.try('2 SALE log rows linked to the order, by the admin',
  $q$select count(*)::text || ' ' || bool_and(by_user = '00000000-0000-4000-8000-0000000000e1')::text from public.stock_log
     where order_id = (pg_temp.v('ord')::jsonb->>'order_id')::bigint and reason = 'SALE'$q$, '2 true');
select pg_temp.try('customer upserted with the phone',
  $q$select name || ' ' || orders_count from public.customers where phone = '+96171555666'$q$, '[TEST] Phone buyer 1');

-- Whish allowed for staff once the shop has a Whish number (same rule as the website)
update public.settings set value = '76 000 000' where key = 'whish_number';   -- rolled back
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000e1');
insert into _v select 'ordw', public.staff_place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'WHISH', 'WHATSAPP')::text;
reset role;
select pg_temp.try('Whish staff order: WHATSAPP, CONFIRMED, AWAITING, empty notes stay null',
  $q$select source || ' ' || status || ' ' || payment_status || ' ' || coalesce(notes, 'null')
     from public.orders where id = (pg_temp.v('ordw')::jsonb->>'order_id')::bigint$q$, 'WHATSAPP CONFIRMED AWAITING null');

-- a staff order can be cancelled like any other (stock comes back)
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000e1');
select pg_temp.try('cancel the Instagram order',
  $q$select public.cancel_order((pg_temp.v('ord')::jsonb->>'order_id')::bigint, '[TEST] staff order cancel')$q$, 'CANCELLED');
reset role;
select pg_temp.try('mug stock back (only the website + Whish orders still hold 1 each)',
  $q$select (pg_temp.v('mug0')::int - (select stock from public.products where sku = 'TEST-MUG-01'))::text$q$, '2');

-- OWNER can see the source (read-only orders screen)
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000e2');
select pg_temp.try('OWNER reads the source',
  $q$select source from public.orders where id = (pg_temp.v('ordw')::jsonb->>'order_id')::bigint$q$, 'WHATSAPP');
reset role;

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
