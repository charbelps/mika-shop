-- =====================================================================
-- Mika Shop: prep actions test (cancel_order, staff_confirm_payment, staff_set_status). ROLLED BACK.
-- Needs the test data (supabase/tests/test_data.sql).
-- Run:  supabase db query --linked -f supabase/tests/prep_test.sql
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

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000f1', 'preptest-admin@example.test',  'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000f2', 'preptest-owner@example.test',  'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000f3', 'preptest-driver@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000f1', 'PREPTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000f2', 'PREPTEST owner', 'OWNER'),
  ('00000000-0000-4000-8000-0000000000f3', 'PREPTEST driver', 'DRIVER');

update public.settings set value = '76 000 000' where key = 'whish_number';   -- rolled back
insert into _v select 'zone', id::text from public.delivery_zones where district = '[TEST] District';
insert into _v select 'tsh_s', id::text from public.variants where sku = 'TEST-TSHIRT-01' and label_en = 'Size S / White';
insert into _v select 'candle0', stock::text from public.products where sku = 'TEST-CANDLE-01';
insert into _v select 'tsh_s0', stock::text from public.variants where id = (select v::bigint from _v where k = 'tsh_s');

-- two orders placed as a visitor: COD (candle x3 + T-shirt S x2) and Whish (candle x1)
-- plpgsql so place_order runs exactly once (inside a WHERE it could run once per row)
create function pg_temp.place(p_pay text, p_items jsonb) returns bigint language plpgsql as $$
declare v_no text; v_id bigint;
begin
  v_no := public.place_order(
    jsonb_build_object('name', '[TEST] Prep test', 'phone', '70 444 555', 'zone_id', pg_temp.v('zone'),
                       'town', 'Testville', 'address', 'Bldg: prep'), p_items, p_pay) ->> 'order_no';
  select id into v_id from public.orders where order_no = v_no;
  return v_id;
end $$;
insert into _v select 'cod', pg_temp.place('COD', jsonb_build_array(
  jsonb_build_object('sku', 'TEST-CANDLE-01', 'qty', 3),
  jsonb_build_object('sku', 'TEST-TSHIRT-01', 'variant_id', pg_temp.v('tsh_s')::bigint, 'qty', 2)))::text;
insert into _v select 'whish', pg_temp.place('WHISH', '[{"sku":"TEST-CANDLE-01","qty":1}]')::text;

select pg_temp.try('stock taken by the 2 orders: candle -4, T-shirt S -2',
  $q$select (pg_temp.v('candle0')::int - (select stock from public.products where sku = 'TEST-CANDLE-01')) || ',' ||
            (pg_temp.v('tsh_s0')::int - (select stock from public.variants where id = pg_temp.v('tsh_s')::bigint))$q$, '4,2');

-- ---------- refused for everyone but ADMIN ----------
set local role anon; select pg_temp.as_user(null);
select pg_temp.try('visitor cancel -> refused', $q$select public.cancel_order(pg_temp.v('cod')::bigint, 'x')$q$, 'error:42501');
select pg_temp.try('visitor confirm payment -> refused', $q$select public.staff_confirm_payment(pg_temp.v('whish')::bigint, 'x')$q$, 'error:42501');
select pg_temp.try('visitor set status -> refused', $q$select public.staff_set_status(pg_temp.v('cod')::bigint, 'PACKED')$q$, 'error:42501');
select pg_temp.try('visitor core cancel -> refused', $q$select public.cancel_order_core(pg_temp.v('cod')::bigint, 'x')$q$, 'error:42501');
reset role;
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000f2');
select pg_temp.try('OWNER cancel -> refused', $q$select public.cancel_order(pg_temp.v('cod')::bigint, 'x')$q$, 'error:42501');
select pg_temp.try('OWNER pack -> refused', $q$select public.staff_set_status(pg_temp.v('cod')::bigint, 'PACKED')$q$, 'error:42501');
select pg_temp.try('OWNER can read both orders', $q$select count(*)::text from public.orders where name = '[TEST] Prep test'$q$, '2');
reset role;
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000f3');
select pg_temp.try('DRIVER confirm payment -> refused', $q$select public.staff_confirm_payment(pg_temp.v('whish')::bigint, 'x')$q$, 'error:42501');
reset role;

-- ---------- ADMIN ----------
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000f1');
select pg_temp.try('confirm COD payment -> not allowed (COD is paid on delivery)',
  $q$select public.staff_confirm_payment(pg_temp.v('cod')::bigint, 'ref')$q$, 'error:P0001:CANNOT_CONFIRM_PAYMENT');
select pg_temp.try('confirm Whish without reference -> REF_REQUIRED',
  $q$select public.staff_confirm_payment(pg_temp.v('whish')::bigint, '  ')$q$, 'error:P0001:REF_REQUIRED');
select pg_temp.try('confirm Whish with reference -> PAID',
  $q$select public.staff_confirm_payment(pg_temp.v('whish')::bigint, 'WH-778899')$q$, 'PAID');
select pg_temp.try('reference saved', $q$select payment_status || ' ' || payment_ref from public.orders where id = pg_temp.v('whish')::bigint$q$, 'PAID WH-778899');
select pg_temp.try('confirm twice -> refused', $q$select public.staff_confirm_payment(pg_temp.v('whish')::bigint, 'again')$q$, 'error:P0001:CANNOT_CONFIRM_PAYMENT');

select pg_temp.try('NEW -> CONFIRMED', $q$select public.staff_set_status(pg_temp.v('cod')::bigint, 'CONFIRMED')$q$, 'CONFIRMED');
select pg_temp.try('CONFIRMED -> PACKED', $q$select public.staff_set_status(pg_temp.v('cod')::bigint, 'PACKED')$q$, 'PACKED');
select pg_temp.try('PACKED -> DELIVERED not a prep move -> refused', $q$select public.staff_set_status(pg_temp.v('cod')::bigint, 'DELIVERED')$q$, 'error:P0001:BAD_STATUS_CHANGE');
select pg_temp.try('PACKED -> CONFIRMED (undo)', $q$select public.staff_set_status(pg_temp.v('cod')::bigint, 'CONFIRMED')$q$, 'CONFIRMED');
select pg_temp.try('status to nonsense -> refused', $q$select public.staff_set_status(pg_temp.v('cod')::bigint, 'LOST')$q$, 'error:P0001:BAD_STATUS_CHANGE');

select pg_temp.try('cancel without reason -> REASON_REQUIRED', $q$select public.cancel_order(pg_temp.v('cod')::bigint, '')$q$, 'error:P0001:REASON_REQUIRED');
select pg_temp.try('return a not-delivered order -> CANNOT_RETURN', $q$select public.cancel_order(pg_temp.v('cod')::bigint, 'x', true)$q$, 'error:P0001:CANNOT_RETURN');
select pg_temp.try('cancel COD order with reason', $q$select public.cancel_order(pg_temp.v('cod')::bigint, 'Customer changed mind')$q$, 'CANCELLED');
select pg_temp.try('stock back: candle -1 (only Whish left), T-shirt S back to start',
  $q$select (pg_temp.v('candle0')::int - (select stock from public.products where sku = 'TEST-CANDLE-01')) || ',' ||
            (pg_temp.v('tsh_s0')::int - (select stock from public.variants where id = pg_temp.v('tsh_s')::bigint))$q$, '1,0');
select pg_temp.try('CANCEL log rows linked to the order, by the admin',
  $q$select count(*) || ' ' || sum(change) || ' ' || bool_and(by_user = '00000000-0000-4000-8000-0000000000f1') from public.stock_log
     where order_id = pg_temp.v('cod')::bigint and reason = 'CANCEL'$q$, '2 5 true');
select pg_temp.try('order shows CANCELLED + reason', $q$select status || ' / ' || cancel_reason from public.orders where id = pg_temp.v('cod')::bigint$q$, 'CANCELLED / Customer changed mind');
select pg_temp.try('cancel twice -> CANNOT_CANCEL (stock not returned twice)', $q$select public.cancel_order(pg_temp.v('cod')::bigint, 'again')$q$, 'error:P0001:CANNOT_CANCEL');
select pg_temp.try('pack a cancelled order -> refused', $q$select public.staff_set_status(pg_temp.v('cod')::bigint, 'PACKED')$q$, 'error:P0001:BAD_STATUS_CHANGE');
reset role;

-- return: pretend the Whish order was delivered (Phase 2 will do this), then return it
update public.orders set status = 'DELIVERED' where id = pg_temp.v('whish')::bigint;
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000f1');
select pg_temp.try('return a delivered order -> RETURNED', $q$select public.cancel_order(pg_temp.v('whish')::bigint, 'Broken in delivery', true)$q$, 'RETURNED');
select pg_temp.try('candle stock fully back to start', $q$select (pg_temp.v('candle0')::int - (select stock from public.products where sku = 'TEST-CANDLE-01'))::text$q$, '0');
select pg_temp.try('RETURN log row', $q$select count(*)::text from public.stock_log where order_id = pg_temp.v('whish')::bigint and reason = 'RETURN'$q$, '1');
reset role;

select pg_temp.try('Realtime publication includes orders',
  $q$select count(*)::text from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'orders'$q$, '1');

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
