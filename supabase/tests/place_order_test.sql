-- =====================================================================
-- Mika Shop: place_order + normalize_phone test, as a logged-out visitor. ROLLED BACK.
-- Needs the test data (supabase/tests/test_data.sql): [TEST] Zone (fee 2.50), TEST- products.
-- Run:  supabase db query --linked -f supabase/tests/place_order_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to anon;
grant all on sequence _r_n_seq to anon;
create temp table _v (k text primary key, v text);
grant all on _v to anon;

-- try(test, sql, expected): runs sql as the CURRENT role; records its single value or error code.
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

-- ids we need (as postgres)
insert into _v select 'zone', id::text from public.delivery_zones where district = '[TEST] District';
insert into _v select 'beirut', id::text from public.delivery_zones where district = 'Beirut';
insert into _v select 'tsh_l', id::text from public.variants where sku = 'TEST-TSHIRT-01' and label_en = 'Size L / Black';
insert into _v select 'hood_m', id::text from public.variants where sku = 'TEST-HOODIE-01' and label_en = 'Size M';
insert into _v select 'mug_stock', stock::text from public.products where sku = 'TEST-MUG-01';
insert into _v select 'l_stock', stock::text from public.variants where sku = 'TEST-TSHIRT-01' and label_en = 'Size L / Black';
insert into _v select 'orders_before', count(*)::text from public.orders;

-- phone normalization
select pg_temp.try('normalize_phone: 12 formats',
  $q$select string_agg(coalesce(public.normalize_phone(x), 'NULL'), ',' order by o) from unnest(array[
    '70 123 456', '070123456', '+961 70 123 456', '00961-70-123456', '96170123456', '03 123 456',
    '(01) 234-567', '٧٠١٢٣٤٥٦', '+44 7700 900123', '123', '70 123 4567', '+961 03 123456']) with ordinality t(x, o)$q$,
  '+96170123456,+96170123456,+96170123456,+96170123456,+96170123456,+9613123456,+9611234567,+96170123456,NULL,NULL,NULL,+9613123456');

-- helper to build a customer for the test zone
create function pg_temp.cust(p_phone text default '70 000 111', p_zone text default null) returns jsonb language sql as $$
  select jsonb_build_object('name', '[TEST] SQL buyer', 'phone', p_phone,
    'zone_id', coalesce(p_zone, (select v from pg_temp._v where k = 'zone')),
    'town', 'Testville', 'address', 'Bldg: 1', 'landmark', 'test', 'location_url', '') $$;
grant execute on function pg_temp.cust(text, text) to anon;

-- ================= as a logged-out visitor =================
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

select pg_temp.try('COD order: 2 mugs + 1 T-shirt L (browser price 0 ignored)',
  $q$with r as (select public.place_order(pg_temp.cust(),
     jsonb_build_array(jsonb_build_object('sku', 'TEST-MUG-01', 'qty', 2, 'price', 0),
                       jsonb_build_object('sku', 'TEST-TSHIRT-01', 'variant_id', (select v from pg_temp._v where k = 'tsh_l'), 'qty', 1)),
     'COD') o)
     select (o->>'subtotal') || '+' || (o->>'delivery_fee') || '=' || (o->>'total') || ' ' || (o->>'payment_status') || ' ' ||
            ((o->>'order_no') ~ '^[0-9]{5,}$')::text || ' items:' || jsonb_array_length(o->'items')
     from r$q$,
  '31.00+2.50=33.50 UNPAID true items:2');
select pg_temp.try('visitor still cannot read orders', 'select count(*)::text from public.orders', 'error:42501');

select pg_temp.try('same phone typed differently, duplicate lines merged',
  $q$select (public.place_order(pg_temp.cust('+961 70-000-111'),
     '[{"sku":"TEST-MUG-01","qty":1},{"sku":"TEST-MUG-01","qty":2}]'::jsonb, 'COD') -> 'items' -> 0 ->> 'qty')$q$, '3');

-- refusals
select pg_temp.try('honeypot filled -> INVALID_INPUT',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD', 'http://spam')::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('bad phone -> INVALID_PHONE',
  $q$select public.place_order(pg_temp.cust('12345'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD')::text$q$, 'error:P0001:INVALID_PHONE');
select pg_temp.try('district without fee -> ZONE_FEE_NOT_SET',
  $q$select public.place_order(pg_temp.cust('70000111', (select v from pg_temp._v where k = 'beirut')), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD')::text$q$, 'error:P0001:ZONE_FEE_NOT_SET');
select pg_temp.try('unknown district -> ZONE_NOT_FOUND',
  $q$select public.place_order(pg_temp.cust('70000111', '999999'), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD')::text$q$, 'error:P0001:ZONE_NOT_FOUND');
select pg_temp.try('empty cart -> EMPTY_CART',
  $q$select public.place_order(pg_temp.cust(), '[]', 'COD')::text$q$, 'error:P0001:EMPTY_CART');
select pg_temp.try('51 different items -> TOO_MANY_ITEMS',
  $q$select public.place_order(pg_temp.cust(), (select jsonb_agg(jsonb_build_object('sku', 'X' || i, 'qty', 1)) from generate_series(1, 51) i), 'COD')::text$q$, 'error:P0001:TOO_MANY_ITEMS');
select pg_temp.try('qty 0 -> INVALID_INPUT',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":0}]', 'COD')::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('qty 100 -> INVALID_INPUT',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":100}]', 'COD')::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('qty "abc" -> INVALID_INPUT',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":"abc"}]', 'COD')::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('out of stock (pan, stock 0) -> OUT_OF_STOCK',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-PAN-01","qty":1}]', 'COD')::text$q$, 'error:P0001:OUT_OF_STOCK');
select pg_temp.try('more than in stock (mug) -> OUT_OF_STOCK',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":99}]', 'COD')::text$q$, 'error:P0001:OUT_OF_STOCK');
select pg_temp.try('hidden product -> ITEM_UNAVAILABLE',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-BOARD-01","qty":1}]', 'COD')::text$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('variant product without option -> ITEM_UNAVAILABLE',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-TSHIRT-01","qty":1}]', 'COD')::text$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('option of another product -> ITEM_UNAVAILABLE',
  $q$select public.place_order(pg_temp.cust(), jsonb_build_array(jsonb_build_object('sku', 'TEST-TSHIRT-01', 'variant_id', (select v from pg_temp._v where k = 'hood_m'), 'qty', 1)), 'COD')::text$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('unknown SKU -> ITEM_UNAVAILABLE',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"NOPE-1","qty":1}]', 'COD')::text$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('Whish while number not set -> PAYMENT_NOT_AVAILABLE',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'WHISH')::text$q$, 'error:P0001:PAYMENT_NOT_AVAILABLE');
select pg_temp.try('bad location link -> INVALID_INPUT',
  $q$select public.place_order(pg_temp.cust() || '{"location_url":"javascript:alert(1)"}', '[{"sku":"TEST-MUG-01","qty":1}]', 'COD')::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('name too long -> INVALID_INPUT',
  $q$select public.place_order(pg_temp.cust() || jsonb_build_object('name', repeat('x', 81)), '[{"sku":"TEST-MUG-01","qty":1}]', 'COD')::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('unknown payment -> INVALID_INPUT',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1}]', 'CARD')::text$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('one bad line refuses the whole order (mug ok + pan out)',
  $q$select public.place_order(pg_temp.cust(), '[{"sku":"TEST-MUG-01","qty":1},{"sku":"TEST-PAN-01","qty":1}]', 'COD')::text$q$, 'error:P0001:OUT_OF_STOCK');
reset role;

-- ================= Whish + prefix (settings changed inside this rolled-back test only) =================
update public.settings set value = '76 000 000' where key = 'whish_number';
update public.settings set value = 'MS-' where key = 'order_prefix';
update public.settings set value = '24' where key = 'unpaid_cancel_hours';
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.try('Whish order: AWAITING + instructions + prefix',
  $q$with r as (select public.place_order(pg_temp.cust('81 222 333'), '[{"sku":"TEST-CANDLE-01","qty":1}]', 'WHISH') o)
     select (o->>'payment_status') || ' ' || (o->>'whish_number') || ' ' || (o->>'unpaid_cancel_hours') || 'h ' || ((o->>'order_no') ~ '^MS-[0-9]{5,}$')::text from r$q$,
  'AWAITING 76 000 000 24h true');
reset role;

-- ================= what was saved (checked as postgres) =================
select pg_temp.try('3 orders saved (2 COD + 1 Whish), all refusals left nothing',
  $q$select (count(*) - (select v::int from pg_temp._v where k = 'orders_before'))::text from public.orders$q$, '3');
select pg_temp.try('first order: address, carrier from zone, status NEW',
  $q$select governorate || '|' || district || '|' || status || '|' || payment_method || '|' || coalesce(carrier, '-') || '|' || phone
     from public.orders where name = '[TEST] SQL buyer' order by id limit 1$q$,
  '[TEST] Zone|[TEST] District|NEW|COD|-|+96170000111');
select pg_temp.try('items copied: names, Arabic label, unit prices from DB',
  $q$select string_agg(sku || ':' || qty || 'x' || unit_price || coalesce(':' || label || '/' || label_ar, ''), ', ' order by sku)
     from public.order_items where order_id = (select min(id) from public.orders where name = '[TEST] SQL buyer')$q$,
  'TEST-MUG-01:2x8.00, TEST-TSHIRT-01:1x15.00:Size L / Black/مقاس L / أسود');
select pg_temp.try('stock taken: mug -5, T-shirt L -1',
  $q$select ((select v::int from pg_temp._v where k = 'mug_stock') - (select stock from public.products where sku = 'TEST-MUG-01')) || ',' ||
            ((select v::int from pg_temp._v where k = 'l_stock') - (select stock from public.variants where id = (select v::bigint from pg_temp._v where k = 'tsh_l')))$q$,
  '5,1');
select pg_temp.try('stock_log: SALE rows linked to the orders',
  $q$select count(*) || ' ' || bool_and(order_id is not null) from public.stock_log
     where reason = 'SALE' and order_id in (select id from public.orders where name = '[TEST] SQL buyer')$q$, '4 true');
select pg_temp.try('customer: one record, 2 orders, total 33.50 + 26.50',
  $q$select orders_count || ' ' || total_spent from public.customers where phone = '+96170000111'$q$, '2 60.00');
select pg_temp.try('stock never negative anywhere',
  $q$select (select count(*) from public.products where stock < 0) + (select count(*) from public.variants where stock < 0) || ''$q$, '0');

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
