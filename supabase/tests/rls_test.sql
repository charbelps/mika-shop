-- =====================================================================
-- Mika Shop: Row Level Security test. SAFE TO RUN ANY TIME.
-- Everything happens inside one transaction that is ROLLED BACK at the
-- end: the fake users, staff rows and orders below never persist.
--
-- Run:  supabase db query --linked -f supabase/tests/rls_test.sql
-- Result: one row per check; every row must have pass = true.
-- =====================================================================
begin;

create temp table _r (n serial, who text, test text, expected text, got text);
grant all on _r to anon, authenticated;
grant all on sequence _r_n_seq to anon, authenticated;

-- try(who, test, sql, expected): runs sql as the CURRENT role and records
-- 'rows:N' (rows returned or changed) or 'error:SQLSTATE'.
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
    v_got := 'error:' || sqlstate;
  end;
  insert into pg_temp._r (who, test, expected, got) values (p_who, p_test, p_expected, v_got);
end $$;

-- act_as(uuid or null): switch to a browser role with that user's JWT.
create function pg_temp.claims(p_uid uuid) returns text language sql as $$
  select case when p_uid is null then '{"role":"anon"}'
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end
$$;

-- ---------- fixtures (as postgres, rolled back at the end) ------------
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000a1', 'rlstest-admin@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000a2', 'rlstest-owner@example.test',    'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000a3', 'rlstest-driver@example.test',   'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000a4', 'rlstest-nostaff@example.test',  'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000a5', 'rlstest-oldadmin@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role, active) values
  ('00000000-0000-4000-8000-0000000000a1', 'RLSTEST admin',   'ADMIN',  true),
  ('00000000-0000-4000-8000-0000000000a2', 'RLSTEST owner',   'OWNER',  true),
  ('00000000-0000-4000-8000-0000000000a3', 'RLSTEST driver',  'DRIVER', true),
  ('00000000-0000-4000-8000-0000000000a5', 'RLSTEST old admin', 'ADMIN', false);
insert into public.customers (phone, name) values ('+96170000001', 'RLSTEST customer');
insert into public.orders (order_no, phone, name, governorate, district, town, address,
                           subtotal, delivery_fee, total, payment_method, payment_status, driver_id)
values ('RLSTEST-1', '+96170000001', 'RLSTEST', 'Beirut', 'Beirut', 'x', 'x', 10, 2, 12, 'COD', 'UNPAID',
        '00000000-0000-4000-8000-0000000000a3'),
       ('RLSTEST-2', '+96170000001', 'RLSTEST', 'Beirut', 'Beirut', 'x', 'x', 10, 2, 12, 'COD', 'UNPAID', null);
insert into public.order_items (order_id, sku, name_en, qty, unit_price, line_total)
select id, 'RLSTEST', 'RLSTEST item', 1, 10, 10 from public.orders where order_no like 'RLSTEST-%';
insert into public.categories (name_en, active) values ('RLSTEST hidden category', false);

-- ---------- logged out (anon) ----------------------------------------
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'read orders',          'select 1 from public.orders',      'error:42501');
select pg_temp.try('anon', 'read order_items',     'select 1 from public.order_items', 'error:42501');
select pg_temp.try('anon', 'read customers',       'select 1 from public.customers',   'error:42501');
select pg_temp.try('anon', 'read staff',           'select 1 from public.staff',       'error:42501');
select pg_temp.try('anon', 'read stock_log',       'select 1 from public.stock_log',   'error:42501');
select pg_temp.try('anon', 'read private setting', $q$select 1 from public.settings where key = 'order_prefix'$q$, 'rows:0');
select pg_temp.try('anon', 'read public setting',  $q$select 1 from public.settings where key = 'currency'$q$,     'rows:1');
select pg_temp.try('anon', 'read zones',           'select 1 from public.delivery_zones', 'rows:26');
select pg_temp.try('anon', 'read hidden category', $q$select 1 from public.categories where name_en like 'RLSTEST%'$q$, 'rows:0');
select pg_temp.try('anon', 'insert product',       $q$insert into public.products (sku, name_en, price) values ('RLSTEST-X', 'x', 1)$q$, 'error:42501');
select pg_temp.try('anon', 'update setting',       $q$update public.settings set value = 'x' where key = 'currency'$q$, 'error:42501');
select pg_temp.try('anon', 'insert order',         $q$insert into public.orders (order_no, phone, name, governorate, district, town, address, subtotal, delivery_fee, total, payment_method, payment_status) values ('RLSTEST-9', '+96170000001', 'x', 'x', 'x', 'x', 'x', 0, 0, 0, 'COD', 'UNPAID')$q$, 'error:42501');
select pg_temp.try('anon', 'my_role() is null',    'select 1 where public.my_role() is null', 'rows:1');
select pg_temp.try('anon', 'upload photo',         $q$insert into storage.objects (bucket_id, name) values ('product-photos', 'rlstest.jpg')$q$, 'error:42501');
reset role;

-- ---------- logged in but NOT staff ----------------------------------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000a4'), true);
select pg_temp.try('no-staff', 'read orders',       'select 1 from public.orders',    'rows:0');
select pg_temp.try('no-staff', 'read customers',    'select 1 from public.customers', 'rows:0');
select pg_temp.try('no-staff', 'read staff',        'select 1 from public.staff',     'rows:0');
select pg_temp.try('no-staff', 'read private setting', $q$select 1 from public.settings where key = 'order_prefix'$q$, 'rows:0');
select pg_temp.try('no-staff', 'insert category',   $q$insert into public.categories (name_en) values ('RLSTEST x')$q$, 'error:42501');
select pg_temp.try('no-staff', 'upload photo',      $q$insert into storage.objects (bucket_id, name) values ('product-photos', 'rlstest.jpg')$q$, 'error:42501');
reset role;

-- ---------- deactivated ADMIN ----------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000a5'), true);
select pg_temp.try('old-admin', 'read orders',      'select 1 from public.orders', 'rows:0');
select pg_temp.try('old-admin', 'insert category',  $q$insert into public.categories (name_en) values ('RLSTEST x')$q$, 'error:42501');
reset role;

-- ---------- ADMIN -----------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000a1'), true);
select pg_temp.try('admin', 'my_role() = ADMIN',    $q$select 1 where public.my_role() = 'ADMIN'$q$, 'rows:1');
select pg_temp.try('admin', 'read all orders',      $q$select 1 from public.orders where order_no like 'RLSTEST-%'$q$, 'rows:2');
select pg_temp.try('admin', 'read customers',       $q$select 1 from public.customers where phone = '+96170000001'$q$, 'rows:1');
select pg_temp.try('admin', 'read all staff',       $q$select 1 from public.staff where name like 'RLSTEST%'$q$, 'rows:4');
select pg_temp.try('admin', 'read private setting', $q$select 1 from public.settings where key = 'order_prefix'$q$, 'rows:1');
select pg_temp.try('admin', 'read hidden category', $q$select 1 from public.categories where name_en like 'RLSTEST%'$q$, 'rows:1');
select pg_temp.try('admin', 'insert category',      $q$insert into public.categories (name_en) values ('RLSTEST new')$q$, 'rows:1');
select pg_temp.try('admin', 'insert product',       $q$insert into public.products (sku, name_en, price) values ('RLSTEST-P', 'RLSTEST product', 5)$q$, 'rows:1');
select pg_temp.try('admin', 'update order',         $q$update public.orders set notes = 'x' where order_no = 'RLSTEST-2'$q$, 'rows:1');
select pg_temp.try('admin', 'upload photo',         $q$insert into storage.objects (bucket_id, name) values ('product-photos', 'rlstest.jpg')$q$, 'rows:1');
reset role;

-- ---------- OWNER (read-only) ----------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000a2'), true);
select pg_temp.try('owner', 'read all orders',      $q$select 1 from public.orders where order_no like 'RLSTEST-%'$q$, 'rows:2');
select pg_temp.try('owner', 'read order items',     $q$select 1 from public.order_items where sku = 'RLSTEST'$q$, 'rows:2');
select pg_temp.try('owner', 'read customers',       $q$select 1 from public.customers where phone = '+96170000001'$q$, 'rows:1');
select pg_temp.try('owner', 'read stock_log',       'select 1 from public.stock_log', 'rows:0');
select pg_temp.try('owner', 'read private setting', $q$select 1 from public.settings where key = 'order_prefix'$q$, 'rows:1');
select pg_temp.try('owner', 'insert category',      $q$insert into public.categories (name_en) values ('RLSTEST x')$q$, 'error:42501');
select pg_temp.try('owner', 'update order',         $q$update public.orders set notes = 'x' where order_no like 'RLSTEST-%'$q$, 'rows:0');
select pg_temp.try('owner', 'update setting',       $q$update public.settings set value = 'x' where key = 'currency'$q$, 'rows:0');
select pg_temp.try('owner', 'read other staff',     $q$select 1 from public.staff where name like 'RLSTEST%'$q$, 'rows:1');
select pg_temp.try('owner', 'upload photo',         $q$insert into storage.objects (bucket_id, name) values ('product-photos', 'rlstest2.jpg')$q$, 'error:42501');
reset role;

-- ---------- DRIVER (own orders only) ---------------------------------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000a3'), true);
select pg_temp.try('driver', 'read orders (only own)',   $q$select 1 from public.orders where order_no like 'RLSTEST-%'$q$, 'rows:1');
select pg_temp.try('driver', 'read items (only own)',    $q$select 1 from public.order_items where sku = 'RLSTEST'$q$, 'rows:1');
select pg_temp.try('driver', 'read customers',           'select 1 from public.customers', 'rows:0');
select pg_temp.try('driver', 'update own status/cash',   $q$update public.orders set status = 'DELIVERED', cash_collected = 12, notes = 'ok' where order_no = 'RLSTEST-1'$q$, 'rows:1');
select pg_temp.try('driver', 'change own order total',   $q$update public.orders set total = 0 where order_no = 'RLSTEST-1'$q$, 'error:42501');
select pg_temp.try('driver', 'reassign own order',       $q$update public.orders set driver_id = null where order_no = 'RLSTEST-1'$q$, 'error:42501');
select pg_temp.try('driver', 'update other order',       $q$update public.orders set status = 'DELIVERED' where order_no = 'RLSTEST-2'$q$, 'rows:0');
select pg_temp.try('driver', 'insert product',           $q$insert into public.products (sku, name_en, price) values ('RLSTEST-D', 'x', 1)$q$, 'error:42501');
reset role;

-- ---------- result ----------------------------------------------------
select n, who, test, expected, got, (expected = got) as pass
from _r
order by (expected = got), n;

rollback;
