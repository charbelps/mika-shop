-- =====================================================================
-- Mika Shop: owner dashboard (migration 30). ROLLED BACK, leaves nothing.
-- TEST already holds orders, so the checks compare the dashboard BEFORE and AFTER adding
-- clearly marked test rows (the differences must be exactly the test rows).
-- The dashboard function is STABLE: a check must USE its result (e.g. in WHERE), otherwise
-- Postgres may skip calling it inside count(*).
-- Run:  supabase db query --linked -f supabase/tests/dashboard_test.sql
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
create temp table _d (k text primary key, v jsonb);
-- numbers: after - before
create function pg_temp.diff(p_path text[]) returns numeric language sql as $$
  select coalesce((select (v #>> p_path)::numeric from pg_temp._d where k = 'after'), 0)
       - coalesce((select (v #>> p_path)::numeric from pg_temp._d where k = 'before'), 0) $$;
create function pg_temp.after() returns jsonb language sql as $$ select v from pg_temp._d where k = 'after' $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000a1', 'dbtest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000a2', 'dbtest-owner@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000a3', 'dbtest-driver@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000a1', 'DBTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000a2', 'DBTEST owner', 'OWNER'),
  ('00000000-0000-4000-8000-0000000000a3', 'DBTEST driver', 'DRIVER');
update public.settings set value = '3' where key = 'low_stock_threshold';

-- the dashboard before (as the admin)
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000a1'), true);
insert into _d select 'before', public.staff_dashboard(30);
insert into _d select 'before7', public.staff_dashboard(7);

-- test rows
insert into public.products (sku, name_en, name_ar, price, stock, created_at) values
  ('DBTEST-HOT', 'Hot item', 'رائج', 10, 50, now() - interval '100 days'),
  ('DBTEST-SLOW', 'Slow item', 'بطيء', 10, 7, now() - interval '100 days'),
  ('DBTEST-NEW', 'New item', 'جديد', 10, 5, now()),
  ('DBTEST-LOW', 'Low item', 'قليل', 10, 2, now() - interval '100 days');
insert into public.orders (order_no, created_at, phone, name, governorate, district, town, address, subtotal, delivery_fee, total,
                           payment_method, payment_status, status, carrier, driver_id, delivered_at, cash_collected) values
  ('DBTEST-1', now(), '+96170000301', 'A', '[DBTEST] Gov', 'D', 'T', 'x', 20, 2, 22, 'COD', 'UNPAID', 'DELIVERED', 'DRIVER', '00000000-0000-4000-8000-0000000000a3', now(), 22),
  ('DBTEST-2', now(), '+96170000302', 'B', '[DBTEST] Gov', 'D', 'T', 'x', 50, 3, 53, 'COD', 'UNPAID', 'OUT_FOR_DELIVERY', 'DRIVER', '00000000-0000-4000-8000-0000000000a3', null, null),
  ('DBTEST-3', now(), '+96170000303', 'C', '[DBTEST] Gov', 'D', 'T', 'x', 99, 1, 100, 'COD', 'UNPAID', 'CANCELLED', null, null, null, null),
  ('DBTEST-4', now(), '+96170000304', 'D', '[DBTEST] Far', 'D', 'T', 'x', 30, 5, 35, 'COD', 'UNPAID', 'DELIVERED', 'COMPANY', null, now(), 35),
  ('DBTEST-5', now() - interval '10 days', '+96170000305', 'E', '[DBTEST] Gov', 'D', 'T', 'x', 40, 0, 40, 'WHISH', 'PAID', 'DELIVERED', 'DRIVER', '00000000-0000-4000-8000-0000000000a3', now() - interval '9 days', 0);
insert into public.order_items (order_id, sku, name_en, name_ar, qty, unit_price, line_total)
select o.id, 'DBTEST-HOT', 'Hot item', 'رائج', 500, 10, 5000 from public.orders o where o.order_no = 'DBTEST-1';
insert into public.order_items (order_id, sku, name_en, name_ar, qty, unit_price, line_total)
select o.id, 'DBTEST-HOT', 'Hot item', 'رائج', 300, 10, 3000 from public.orders o where o.order_no = 'DBTEST-3';   -- cancelled: not counted

insert into _d select 'after', public.staff_dashboard(30);
insert into _d select 'after7', public.staff_dashboard(7);

select pg_temp.try('sales', 'today: +3 orders (the cancelled one not counted)', $q$select 1 where pg_temp.diff('{sales,today,orders}') = 3$q$, 'rows:1');
select pg_temp.try('sales', 'today: items +100 (20 + 50 + 30), delivery +10, total +110', $q$select 1 where pg_temp.diff('{sales,today,items}') = 100 and pg_temp.diff('{sales,today,delivery}') = 10 and pg_temp.diff('{sales,today,total}') = 110$q$, 'rows:1');
select pg_temp.try('sales', 'this week and this month include today', $q$select 1 where pg_temp.diff('{sales,week,orders}') = 3 and pg_temp.diff('{sales,month,items}') >= 100$q$, 'rows:1');
select pg_temp.try('sales', 'last 30 days include the order from 10 days ago (+4, items +140)', $q$select 1 where pg_temp.diff('{sales,range,orders}') = 4 and pg_temp.diff('{sales,range,items}') = 140$q$, 'rows:1');
select pg_temp.try('sales', 'last 7 days don''t (+3)',
  $q$select 1 where (select (v #>> '{sales,range,orders}')::numeric from pg_temp._d where k = 'after7') - (select (v #>> '{sales,range,orders}')::numeric from pg_temp._d where k = 'before7') = 3$q$, 'rows:1');
select pg_temp.try('status', 'open now: +1 on the way', $q$select 1 where pg_temp.diff('{by_status,OUT_FOR_DELIVERY}') = 1$q$, 'rows:1');
select pg_temp.try('status', 'last 30 days: +3 delivered, +1 cancelled', $q$select 1 where pg_temp.diff('{by_status,DELIVERED}') = 3 and pg_temp.diff('{by_status,CANCELLED}') = 1$q$, 'rows:1');
select pg_temp.try('best', 'best seller #1: Hot item, 500 sold (the cancelled 300 not counted), 1 order',
  $q$select 1 where pg_temp.after() #>> '{best_sellers,0,sku}' = 'DBTEST-HOT' and (pg_temp.after() #>> '{best_sellers,0,qty}')::int = 500
       and (pg_temp.after() #>> '{best_sellers,0,orders}')::int = 1 and pg_temp.after() #>> '{best_sellers,0,name_ar}' = 'رائج'$q$, 'rows:1');
select pg_temp.try('slow', 'slow items: the old unsold product is listed',
  $q$select 1 from jsonb_array_elements(pg_temp.after()->'slow_items') e where e->>'sku' = 'DBTEST-SLOW' and (e->>'stock')::int = 7 and e->>'last_sold' is null$q$, 'rows:1');
select pg_temp.try('slow', '... not the brand new one, not the one that sells',
  $q$select 1 from jsonb_array_elements(pg_temp.after()->'slow_items') e where e->>'sku' in ('DBTEST-NEW', 'DBTEST-HOT')$q$, 'rows:0');
select pg_temp.try('low', 'low stock (setting 3): the product with 2 left, not the ones with 5 / 7',
  $q$select 1 from jsonb_array_elements(pg_temp.after()->'low_stock') e where e->>'sku' like 'DBTEST-%'
       having count(*) = 1 and bool_and(e->>'sku' = 'DBTEST-LOW')$q$, 'rows:1');
select pg_temp.try('low', 'the threshold is reported', $q$select 1 where (pg_temp.after()->>'low_stock_threshold')::int = 3$q$, 'rows:1');
select pg_temp.try('cash', 'driver owes +22 for the delivered cash order (the paid one adds 0)',
  $q$select 1 from jsonb_array_elements(pg_temp.after() #> '{cash,drivers}') e where e->>'name' = 'DBTEST driver' and (e->>'owed')::numeric = 22 and (e->>'orders')::int = 2$q$, 'rows:1');
select pg_temp.try('cash', 'company owes +35', $q$select 1 where pg_temp.diff('{cash,company,owed}') = 35$q$, 'rows:1');
select pg_temp.try('cash', 'still to collect on the way +53', $q$select 1 where pg_temp.diff('{cash,on_the_way,to_collect}') = 53 and pg_temp.diff('{cash,on_the_way,orders}') = 1$q$, 'rows:1');
select pg_temp.try('gov', 'per governorate: [DBTEST] Gov 3 orders, items 110 (cancelled not counted)',
  $q$select 1 from jsonb_array_elements(pg_temp.after()->'governorates') e where e->>'governorate' = '[DBTEST] Gov' and (e->>'orders')::int = 3 and (e->>'items')::numeric = 110$q$, 'rows:1');

-- no low-stock setting: only sold-out items
update public.settings set value = '' where key = 'low_stock_threshold';
select pg_temp.try('low', 'no setting: products with 2 left are not "low"',
  $q$select 1 from jsonb_array_elements(public.staff_dashboard(30)->'low_stock') e where e->>'sku' = 'DBTEST-LOW'$q$, 'rows:0');

-- ---------- who may see it ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000a2'), true);
select pg_temp.try('owner', 'the owner sees the dashboard', $q$select 1 where public.staff_dashboard(7) ? 'sales'$q$, 'rows:1');
select pg_temp.try('owner', 'unknown period refused', $q$select 1 where public.staff_dashboard(12) is not null$q$, 'error:P0001:INVALID_INPUT');
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000a3'), true);
select pg_temp.try('driver', 'a driver can''t', $q$select 1 where public.staff_dashboard(30) is not null$q$, 'error:42501');
reset role;
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'a visitor can''t', $q$select 1 where public.staff_dashboard(30) is not null$q$, 'error:42501');
reset role;

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
