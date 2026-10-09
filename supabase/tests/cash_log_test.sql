-- =====================================================================
-- Mika Shop: cash reconciliation (migration 29). ROLLED BACK, leaves nothing.
-- Run:  supabase db query --linked -f supabase/tests/cash_log_test.sql
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
create function pg_temp.id(p_no text) returns bigint language sql security definer as $$
  select id from public.orders where order_no = p_no $$;
create function pg_temp.ids(variadic p_no text[]) returns bigint[] language sql security definer as $$
  select array_agg(id order by id) from public.orders where order_no = any (p_no) $$;
create function pg_temp.settled(p_no text) returns boolean language sql security definer as $$
  select cash_log_id is not null from public.orders where order_no = p_no $$;
grant execute on function pg_temp.id(text), pg_temp.ids(text[]), pg_temp.settled(text) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000f1', 'cltest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000f2', 'cltest-owner@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000f3', 'cltest-driver1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000f4', 'cltest-driver2@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000f1', 'CLTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000f2', 'CLTEST owner', 'OWNER'),
  ('00000000-0000-4000-8000-0000000000f3', 'CLTEST driver 1', 'DRIVER'),
  ('00000000-0000-4000-8000-0000000000f4', 'CLTEST driver 2', 'DRIVER');
insert into public.orders (order_no, phone, name, governorate, district, town, address, subtotal, delivery_fee, total,
                           payment_method, payment_status, status, carrier, driver_id, delivered_at, cash_collected) values
  ('CLTEST-D1', '+96170000201', 'A', 'Beirut', 'Beirut', 'Hamra', 'x', 18, 2, 20, 'COD', 'UNPAID', 'DELIVERED', 'DRIVER', '00000000-0000-4000-8000-0000000000f3', now(), 20),
  ('CLTEST-D2', '+96170000202', 'B', 'Beirut', 'Beirut', 'Hamra', 'x', 13, 2, 15, 'COD', 'UNPAID', 'DELIVERED', 'DRIVER', '00000000-0000-4000-8000-0000000000f3', now(), 15),
  ('CLTEST-D3', '+96170000203', 'C', 'Beirut', 'Beirut', 'Hamra', 'x', 8, 2, 10, 'COD', 'UNPAID', 'DELIVERED', 'DRIVER', '00000000-0000-4000-8000-0000000000f4', now(), 10),
  ('CLTEST-C1', '+96170000204', 'D', 'Akkar', 'Akkar', 'Halba', 'x', 30, 5, 35, 'COD', 'UNPAID', 'DELIVERED', 'COMPANY', null, now(), 35),
  ('CLTEST-C2', '+96170000205', 'E', 'Akkar', 'Akkar', 'Halba', 'x', 30, 5, 35, 'OMT', 'PAID', 'DELIVERED', 'COMPANY', null, now(), 0),
  ('CLTEST-N1', '+96170000206', 'F', 'Beirut', 'Beirut', 'Hamra', 'x', 18, 2, 20, 'COD', 'UNPAID', 'OUT_FOR_DELIVERY', 'DRIVER', '00000000-0000-4000-8000-0000000000f3', null, null);

-- ---------- ADMIN ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000f1'), true);
select pg_temp.try('admin', 'driver 1 hands over 35 for his 2 deliveries: no difference',
  $q$select 1 where (public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f3', pg_temp.ids('CLTEST-D1', 'CLTEST-D2'), 35)->>'difference')::numeric = 0$q$, 'rows:1');
select pg_temp.try('admin', '... both orders marked settled',
  $q$select 1 where pg_temp.settled('CLTEST-D1') and pg_temp.settled('CLTEST-D2') and not pg_temp.settled('CLTEST-D3')$q$, 'rows:1');
select pg_temp.try('admin', '... one cash_log row: expected 35, received 35, by the admin',
  $q$select 1 from public.cash_log where source = 'DRIVER' and driver_id = '00000000-0000-4000-8000-0000000000f3' and expected = 35 and received = 35
     and difference = 0 and cardinality(order_ids) = 2 and by_user = '00000000-0000-4000-8000-0000000000f1'$q$, 'rows:1');
select pg_temp.try('admin', 'an order can''t be settled twice',
  $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f3', pg_temp.ids('CLTEST-D1'), 20)$q$, 'error:P0001:CASH_ORDER_INVALID');
select pg_temp.try('admin', 'another driver''s order refused',
  $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f3', pg_temp.ids('CLTEST-D3'), 10)$q$, 'error:P0001:CASH_ORDER_INVALID');
select pg_temp.try('admin', 'an order not delivered yet refused',
  $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f3', pg_temp.ids('CLTEST-N1'), 20)$q$, 'error:P0001:CASH_ORDER_INVALID');
select pg_temp.try('admin', 'a company order is not the driver''s',
  $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f4', pg_temp.ids('CLTEST-C1'), 35)$q$, 'error:P0001:CASH_ORDER_INVALID');
select pg_temp.try('admin', 'nothing saved by the refused tries (still 1 row)',
  $q$select 1 from public.cash_log where order_ids && pg_temp.ids('CLTEST-D1', 'CLTEST-D2', 'CLTEST-D3', 'CLTEST-C1', 'CLTEST-C2', 'CLTEST-N1')$q$, 'rows:1');
select pg_temp.try('admin', 'the company pays 30 for 35 collected (+ a paid order): difference -5, note kept',
  $q$select 1 where (public.staff_settle_cash('COMPANY', null, pg_temp.ids('CLTEST-C1', 'CLTEST-C2'), 30, ' Their fee 5 ')->>'difference')::numeric = -5$q$, 'rows:1');
select pg_temp.try('admin', '... company row saved',
  $q$select 1 from public.cash_log where source = 'COMPANY' and driver_id is null and expected = 35 and received = 30 and difference = -5 and note = 'Their fee 5'$q$, 'rows:1');
select pg_temp.try('admin', 'company with a driver -> refused', $q$select public.staff_settle_cash('COMPANY', '00000000-0000-4000-8000-0000000000f4', pg_temp.ids('CLTEST-D3'), 10)$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('admin', 'driver without a driver -> refused', $q$select public.staff_settle_cash('DRIVER', null, pg_temp.ids('CLTEST-D3'), 10)$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('admin', 'no orders -> refused', $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f4', array[]::bigint[], 10)$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('admin', 'negative cash -> refused', $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f4', pg_temp.ids('CLTEST-D3'), -1)$q$, 'error:P0001:BAD_CASH');
select pg_temp.try('admin', '3 decimals -> refused', $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f4', pg_temp.ids('CLTEST-D3'), 10.005)$q$, 'error:P0001:BAD_CASH');
select pg_temp.try('admin', 'can''t write cash_log directly',
  $q$insert into public.cash_log (source, order_ids, expected, received, difference) values ('COMPANY', array[1]::bigint[], 0, 0, 0)$q$, 'error:42501');
select pg_temp.try('admin', 'the company name setting exists (empty, private)',
  $q$select 1 from public.settings where key = 'delivery_company_name' and value = '' and not is_public$q$, 'rows:1');
reset role;

-- ---------- OWNER ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000f2'), true);
select pg_temp.try('owner', 'reads the cash history', $q$select 1 from public.cash_log where order_ids && pg_temp.ids('CLTEST-D1', 'CLTEST-C1')$q$, 'rows:2');
select pg_temp.try('owner', 'can''t record cash', $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f4', pg_temp.ids('CLTEST-D3'), 10)$q$, 'error:42501');
reset role;

-- ---------- DRIVER ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000f4'), true);
select pg_temp.try('driver', 'sees no cash history', $q$select 1 from public.cash_log$q$, 'rows:0');
select pg_temp.try('driver', 'can''t record cash', $q$select public.staff_settle_cash('DRIVER', '00000000-0000-4000-8000-0000000000f4', pg_temp.ids('CLTEST-D3'), 10)$q$, 'error:42501');
reset role;

-- ---------- visitor ----------
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'no cash history', $q$select 1 from public.cash_log$q$, 'error:42501');
select pg_temp.try('anon', 'can''t record cash', $q$select public.staff_settle_cash('COMPANY', null, array[1]::bigint[], 1)$q$, 'error:42501');
reset role;

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
