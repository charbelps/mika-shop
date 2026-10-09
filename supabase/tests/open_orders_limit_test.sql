-- =====================================================================
-- Mika Shop: at most N unfinished website orders per phone (12c R2, migration 32). ROLLED BACK.
-- Run:  supabase db query --linked -f supabase/tests/open_orders_limit_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, who text, test text, expected text, got text);
grant all on _r to anon, authenticated;
grant all on sequence _r_n_seq to anon, authenticated;

create function pg_temp.try(p_who text, p_test text, p_sql text, p_expected text)
returns void language plpgsql as $$
declare v_n bigint; v_got text;
begin
  begin
    if p_sql ~* '^\s*select' then
      execute format('select count(*) from (%s) q', p_sql) into v_n;
    else
      execute p_sql;
      get diagnostics v_n = row_count;
    end if;
    v_got := 'rows:' || v_n;
  exception when others then
    v_got := 'error:' || sqlstate || case when sqlstate = 'P0001' then ':' || sqlerrm else '' end;
  end;
  insert into pg_temp._r (who, test, expected, got) values (p_who, p_test, p_expected, v_got);
end $$;
create function pg_temp.claims(p_uid uuid) returns text language sql as $$
  select case when p_uid is null then '{"role":"anon"}'
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end $$;

create temp table _v (k text primary key, v text);
grant all on _v to anon, authenticated;
insert into _v select 'limit0', value from public.settings where key = 'max_open_orders_per_phone';
insert into _v select 'zone', id::text from public.delivery_zones where district = '[TEST] District';
insert into public.products (sku, name_en, price, stock) values ('OLTEST-1', 'Limit candle', 5, 50);
update public.settings set value = '3' where key = 'max_open_orders_per_phone';
update public.settings set value = '[TEST] 70 000 000' where key = 'whish_number';
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000f1', 'oltest-admin@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values ('00000000-0000-4000-8000-0000000000f1', 'OLTEST admin', 'ADMIN');

create function pg_temp.v(p_k text) returns text language sql as $$ select v from pg_temp._v where k = p_k $$;
grant execute on function pg_temp.v(text) to anon, authenticated;
create function pg_temp.cust(p_phone text) returns jsonb language sql as $$
  select jsonb_build_object('name', '[OLTEST] Buyer', 'phone', p_phone, 'zone_id', pg_temp.v('zone'),
    'town', 'Testville', 'address', 'Bldg: limit', 'landmark', '', 'location_url', '') $$;
grant execute on function pg_temp.cust(text) to anon, authenticated;
create function pg_temp.place(p_phone text) returns jsonb language sql as $$
  select public.place_order(pg_temp.cust(p_phone), '[{"sku":"OLTEST-1","qty":1}]'::jsonb, 'COD', '') $$;
grant execute on function pg_temp.place(text) to anon, authenticated;
-- the detail of the error a call raises (the limit, used in the customer's message)
create function pg_temp.detail_of(p_phone text) returns text language plpgsql as $$
declare d text;
begin
  perform pg_temp.place(p_phone);
  return 'no error';
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return sqlerrm || ' / ' || coalesce(d, '');
end $$;
grant execute on function pg_temp.detail_of(text) to anon, authenticated;
-- unfinished orders of a phone (counted as the database, not as the visitor)
create function pg_temp.open_of(p_phone text) returns bigint language sql security definer as $$
  select count(*) from public.orders where phone = p_phone and status not in ('DELIVERED', 'CANCELLED', 'RETURNED') $$;
grant execute on function pg_temp.open_of(text) to anon, authenticated;
create function pg_temp.set_status(p_phone text, p_from text, p_to text) returns void language sql security definer as $$
  update public.orders set status = p_to where id = (select min(id) from public.orders where phone = p_phone and status = p_from) $$;

select pg_temp.try('db', 'setting max_open_orders_per_phone exists, private, migration value 3',
  $q$select 1 from public.settings where key = 'max_open_orders_per_phone' and not is_public and pg_temp.v('limit0') = '3'$q$, 'rows:1');

-- ---------- visitor: the limit ----------
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'the setting is not readable by visitors',
  $q$select 1 from public.settings where key = 'max_open_orders_per_phone'$q$, 'rows:0');
select pg_temp.try('anon', 'order 1 of 3 accepted', $q$select pg_temp.place('70 888 001')$q$, 'rows:1');
select pg_temp.try('anon', 'order 2 of 3 accepted', $q$select pg_temp.place('70888001')$q$, 'rows:1');
select pg_temp.try('anon', 'order 3 of 3 accepted', $q$select pg_temp.place('+961 70 888 001')$q$, 'rows:1');
select pg_temp.try('anon', 'order 4 -> TOO_MANY_OPEN_ORDERS', $q$select pg_temp.place('70 888 001')$q$, 'error:P0001:TOO_MANY_OPEN_ORDERS');
select pg_temp.try('anon', '... same number written another way -> refused too', $q$select pg_temp.place('0096170888001')$q$, 'error:P0001:TOO_MANY_OPEN_ORDERS');
select pg_temp.try('anon', '... the error says the limit (3) for the message',
  $q$select 1 where pg_temp.detail_of('70 888 001') = 'TOO_MANY_OPEN_ORDERS / 3'$q$, 'rows:1');
select pg_temp.try('anon', '... refused orders leave nothing (still 3 unfinished, stock 50 - 3 = 47)',
  $q$select 1 where pg_temp.open_of('+96170888001') = 3 and (select stock from public.products where sku = 'OLTEST-1') = 47$q$, 'rows:1');
select pg_temp.try('anon', 'another phone is not affected', $q$select pg_temp.place('70 888 002')$q$, 'rows:1');
select pg_temp.try('anon', 'spam trap still answers first (INVALID_INPUT, says nothing about the limit)',
  $q$select public.place_order(pg_temp.cust('70 888 001'), '[{"sku":"OLTEST-1","qty":1}]'::jsonb, 'COD', 'bot')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('anon', 'a bad phone still gets INVALID_PHONE', $q$select pg_temp.place('12')$q$, 'error:P0001:INVALID_PHONE');
select pg_temp.try('anon', 'a gift counts for the BUYER''s phone -> refused',
  $q$select public.place_order(pg_temp.cust('70 888 001') || '{"gift":{"name":"Lara","phone":"03 456 789"}}'::jsonb,
     '[{"sku":"OLTEST-1","qty":1}]'::jsonb, 'WHISH', '')$q$, 'error:P0001:TOO_MANY_OPEN_ORDERS');
reset role;

select pg_temp.try('db', 'one lock per phone that ordered (2 phones so far): two orders at the same moment wait for each other',
  $q$select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid() and granted$q$, 'rows:2');

-- ---------- which orders count ----------
select pg_temp.set_status('+96170888001', 'NEW', 'DELIVERED');
set local role anon; select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'one DELIVERED -> a new order is accepted again', $q$select pg_temp.place('70 888 001')$q$, 'rows:1');
select pg_temp.try('anon', '... and then the limit is reached again', $q$select pg_temp.place('70 888 001')$q$, 'error:P0001:TOO_MANY_OPEN_ORDERS');
reset role;
select pg_temp.set_status('+96170888001', 'NEW', 'CANCELLED');
set local role anon; select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'one CANCELLED -> accepted', $q$select pg_temp.place('70 888 001')$q$, 'rows:1');
reset role;
select pg_temp.set_status('+96170888001', 'NEW', 'RETURNED');
set local role anon; select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'one RETURNED -> accepted', $q$select pg_temp.place('70 888 001')$q$, 'rows:1');
reset role;
select pg_temp.set_status('+96170888001', 'NEW', 'OUT_FOR_DELIVERY');
select pg_temp.set_status('+96170888001', 'NEW', 'FAILED_ATTEMPT');
select pg_temp.set_status('+96170888001', 'NEW', 'WITH_COMPANY');
set local role anon; select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'on the way / failed attempt / with the company still count -> refused',
  $q$select pg_temp.place('70 888 001')$q$, 'error:P0001:TOO_MANY_OPEN_ORDERS');
reset role;

-- ---------- staff orders: never blocked, but they count ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000f1'), true);
select pg_temp.try('ADMIN', 'New order screen for a phone at the limit -> accepted (Mika decides)',
  $q$select public.staff_place_order(pg_temp.cust('70 888 001'), '[{"sku":"OLTEST-1","qty":1}]'::jsonb, 'COD', 'PHONE')$q$, 'rows:1');
select pg_temp.try('ADMIN', 'staff order for a fresh phone (70 888 003) -> accepted',
  $q$select public.staff_place_order(pg_temp.cust('70 888 003'), '[{"sku":"OLTEST-1","qty":1}]'::jsonb, 'COD', 'PHONE')$q$, 'rows:1');
select pg_temp.try('ADMIN', 'setting saved as a number (" 5 " -> 5, 1 change)',
  $q$select 1 where public.admin_save_settings('{"max_open_orders_per_phone":" 5 "}') = 1$q$, 'rows:1');
select pg_temp.try('ADMIN', 'setting that is not a number -> BAD_NUMBER',
  $q$select 1 where public.admin_save_settings('{"max_open_orders_per_phone":"three"}') = 1$q$, 'error:P0001:BAD_NUMBER');
reset role;

set local role anon; select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'staff orders count: 70 888 003 has 1, website allows 4 more with limit 5',
  $q$select pg_temp.place('70 888 003') union all select pg_temp.place('70 888 003') union all
     select pg_temp.place('70 888 003') union all select pg_temp.place('70 888 003')$q$, 'rows:4');
select pg_temp.try('anon', '... the 6th unfinished one is refused', $q$select pg_temp.place('70 888 003')$q$, 'error:P0001:TOO_MANY_OPEN_ORDERS');
reset role;

-- ---------- no limit ----------
update public.settings set value = '' where key = 'max_open_orders_per_phone';
set local role anon; select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'empty setting = no limit', $q$select pg_temp.place('70 888 003')$q$, 'rows:1');
reset role;
update public.settings set value = '0' where key = 'max_open_orders_per_phone';
set local role anon; select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', '0 = no limit', $q$select pg_temp.place('70 888 003')$q$, 'rows:1');
reset role;

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
