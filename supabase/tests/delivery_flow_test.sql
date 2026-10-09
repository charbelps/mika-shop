-- =====================================================================
-- Mika Shop: delivery flow (migration 28). ROLLED BACK, leaves nothing.
-- Run:  supabase db query --linked -f supabase/tests/delivery_flow_test.sql
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
-- the order as it is now, whoever asks
create function pg_temp.o(p_no text) returns public.orders language sql security definer as $$
  select * from public.orders where order_no = p_no $$;
create function pg_temp.id(p_no text) returns bigint language sql security definer as $$
  select id from public.orders where order_no = p_no $$;
grant execute on function pg_temp.o(text), pg_temp.id(text) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000e1', 'dltest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000e2', 'dltest-owner@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000e3', 'dltest-driver1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000e4', 'dltest-driver2@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000e5', 'dltest-oldriver@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role, active) values
  ('00000000-0000-4000-8000-0000000000e1', 'DLTEST admin', 'ADMIN', true),
  ('00000000-0000-4000-8000-0000000000e2', 'DLTEST owner', 'OWNER', true),
  ('00000000-0000-4000-8000-0000000000e3', 'DLTEST driver 1', 'DRIVER', true),
  ('00000000-0000-4000-8000-0000000000e4', 'DLTEST driver 2', 'DRIVER', true),
  ('00000000-0000-4000-8000-0000000000e5', 'DLTEST old driver', 'DRIVER', false);
insert into public.orders (order_no, phone, name, governorate, district, town, address, subtotal, delivery_fee, total,
                           payment_method, payment_status, status, fee_tbc, fee_set_at) values
  ('DLTEST-1', '+96170000101', 'Cash buyer', 'Beirut', 'Beirut', 'Hamra', 'Bldg 1', 18, 2, 20, 'COD', 'UNPAID', 'PACKED', false, null),
  ('DLTEST-2', '+96170000102', 'Paid buyer', 'Beirut', 'Beirut', 'Hamra', 'Bldg 2', 13, 2, 15, 'WHISH', 'PAID', 'PACKED', false, null),
  ('DLTEST-3', '+96170000103', 'New buyer', 'Beirut', 'Beirut', 'Hamra', 'Bldg 3', 10, 2, 12, 'COD', 'UNPAID', 'CONFIRMED', false, null),
  ('DLTEST-4', '+96170000104', 'Company buyer', 'Akkar', 'Akkar', 'Halba', 'Bldg 4', 30, 5, 35, 'COD', 'UNPAID', 'PACKED', false, null),
  ('DLTEST-5', '+96170000105', 'Fee pending', 'Akkar', 'Akkar', 'Halba', 'Bldg 5', 30, 0, 30, 'OMT', 'PAID', 'PACKED', true, null),
  ('DLTEST-6', '+96170000106', 'Fee set', 'Akkar', 'Akkar', 'Halba', 'Bldg 6', 30, 4, 34, 'OMT', 'PAID', 'PACKED', true, now());

-- ---------- the collect rule (same as DB.amountToCollect) ----------
select pg_temp.try('db', 'cash order: collect the total (20)', $q$select 1 where public.amount_to_collect(pg_temp.o('DLTEST-1')) = 20$q$, 'rows:1');
select pg_temp.try('db', 'paid order: collect 0', $q$select 1 where public.amount_to_collect(pg_temp.o('DLTEST-2')) = 0$q$, 'rows:1');
select pg_temp.try('db', 'paid, fee still to confirm: unknown (null)', $q$select 1 where public.amount_to_collect(pg_temp.o('DLTEST-5')) is null$q$, 'rows:1');
select pg_temp.try('db', 'paid, fee set afterwards: collect the fee (4)', $q$select 1 where public.amount_to_collect(pg_temp.o('DLTEST-6')) = 4$q$, 'rows:1');

-- ---------- ADMIN ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000e1'), true);
select pg_temp.try('admin', 'staff list: 5 people with roles',
  $q$select 1 from public.staff_directory() where name like 'DLTEST%'$q$, 'rows:5');
select pg_temp.try('admin', 'give order 1 to driver 1',
  $q$select public.staff_assign_delivery(pg_temp.id('DLTEST-1'), 'DRIVER', '00000000-0000-4000-8000-0000000000e3')$q$, 'rows:1');
select pg_temp.try('admin', '... saved',
  $q$select 1 where (pg_temp.o('DLTEST-1')).carrier = 'DRIVER' and (pg_temp.o('DLTEST-1')).driver_id = '00000000-0000-4000-8000-0000000000e3'$q$, 'rows:1');
select pg_temp.try('admin', 'a non-driver can''t be the driver',
  $q$select public.staff_assign_delivery(pg_temp.id('DLTEST-2'), 'DRIVER', '00000000-0000-4000-8000-0000000000e2')$q$, 'error:P0001:NOT_A_DRIVER');
select pg_temp.try('admin', 'a deactivated driver can''t be chosen',
  $q$select public.staff_assign_delivery(pg_temp.id('DLTEST-2'), 'DRIVER', '00000000-0000-4000-8000-0000000000e5')$q$, 'error:P0001:NOT_A_DRIVER');
select pg_temp.try('admin', 'unknown carrier refused',
  $q$select public.staff_assign_delivery(pg_temp.id('DLTEST-2'), 'TAXI', null)$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('admin', 'order 4 to the delivery company (no driver kept)',
  $q$select 1 where (public.staff_assign_delivery(pg_temp.id('DLTEST-4'), 'COMPANY', '00000000-0000-4000-8000-0000000000e3')->>'driver_id') is null$q$, 'rows:1');
select pg_temp.try('admin', 'order 1 out with the driver',
  $q$select 1 where public.staff_delivery(pg_temp.id('DLTEST-1'), 'OUT')->>'status' = 'OUT_FOR_DELIVERY'$q$, 'rows:1');
select pg_temp.try('admin', '... time saved',
  $q$select 1 where (pg_temp.o('DLTEST-1')).out_at is not null$q$, 'rows:1');
select pg_temp.try('admin', 'can''t change who delivers while it is on the way',
  $q$select public.staff_assign_delivery(pg_temp.id('DLTEST-1'), 'COMPANY', null)$q$, 'error:P0001:ON_THE_WAY');
select pg_temp.try('admin', 'not packed yet -> can''t go out',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-3'), 'OUT')$q$, 'error:P0001:BAD_STATUS_CHANGE');
select pg_temp.try('admin', 'company order can''t go "out with the driver"',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-4'), 'OUT')$q$, 'error:P0001:NO_DRIVER');
select pg_temp.try('admin', 'driver order can''t be "handed to the company"',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-2'), 'COMPANY')$q$, 'error:P0001:NOT_COMPANY');
select pg_temp.try('admin', 'order 4 handed to the company with tracking number',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-4'), 'COMPANY', null, null, ' TRK-0042 ')$q$, 'rows:1');
select pg_temp.try('admin', '... WITH_COMPANY, tracking saved',
  $q$select 1 where (pg_temp.o('DLTEST-4')).status = 'WITH_COMPANY' and (pg_temp.o('DLTEST-4')).tracking_no = 'TRK-0042'$q$, 'rows:1');
select pg_temp.try('admin', 'delivered needs the cash collected (a number)',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-4'), 'DELIVERED')$q$, 'error:P0001:BAD_CASH');
select pg_temp.try('admin', 'negative cash refused',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-4'), 'DELIVERED', -1)$q$, 'error:P0001:BAD_CASH');
select pg_temp.try('admin', 'company order delivered, 35 collected',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-4'), 'DELIVERED', 35)$q$, 'rows:1');
select pg_temp.try('admin', '... DELIVERED, cash 35, time saved',
  $q$select 1 where (pg_temp.o('DLTEST-4')).status = 'DELIVERED' and (pg_temp.o('DLTEST-4')).cash_collected = 35 and (pg_temp.o('DLTEST-4')).delivered_at is not null$q$, 'rows:1');
select pg_temp.try('admin', 'unknown action refused',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-2'), 'TELEPORT')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('admin', 'the internal function can''t be called',
  $q$select public.delivery_move_core(pg_temp.id('DLTEST-2'), 'BACK', null, null, null)$q$, 'error:42501');
reset role;

-- ---------- DRIVER 1 (his own orders) ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000e3'), true);
select pg_temp.try('driver1', 'sees his order, not the others', $q$select 1 from public.orders where order_no like 'DLTEST-%'$q$, 'rows:1');
select pg_temp.try('driver1', 'failed without a reason -> refused',
  $q$select public.driver_delivery(pg_temp.id('DLTEST-1'), 'FAILED', null, '  ')$q$, 'error:P0001:REASON_REQUIRED');
select pg_temp.try('driver1', 'failed attempt with a reason',
  $q$select public.driver_delivery(pg_temp.id('DLTEST-1'), 'FAILED', null, 'No answer at the door')$q$, 'rows:1');
select pg_temp.try('driver1', '... FAILED_ATTEMPT, reason + count saved',
  $q$select 1 from public.orders where order_no = 'DLTEST-1' and status = 'FAILED_ATTEMPT' and failed_reason = 'No answer at the door' and failed_count = 1 and failed_at is not null$q$, 'rows:1');
select pg_temp.try('driver1', 'starts again',
  $q$select public.driver_delivery(pg_temp.id('DLTEST-1'), 'START')$q$, 'rows:1');
select pg_temp.try('driver1', 'delivered, 20 collected',
  $q$select public.driver_delivery(pg_temp.id('DLTEST-1'), 'DELIVERED', 20)$q$, 'rows:1');
select pg_temp.try('driver1', '... DELIVERED with 20',
  $q$select 1 from public.orders where order_no = 'DLTEST-1' and status = 'DELIVERED' and cash_collected = 20$q$, 'rows:1');
select pg_temp.try('driver1', 'direct status change refused (only through the driver screen)',
  $q$update public.orders set status = 'CANCELLED' where order_no = 'DLTEST-1'$q$, 'error:42501');
select pg_temp.try('driver1', 'direct cash change refused',
  $q$update public.orders set cash_collected = 0 where order_no = 'DLTEST-1'$q$, 'error:42501');
select pg_temp.try('driver1', 'can still write a note on his order',
  $q$update public.orders set notes = 'Left with the neighbour' where order_no = 'DLTEST-1'$q$, 'rows:1');
select pg_temp.try('driver1', 'someone else''s order -> not found',
  $q$select public.driver_delivery(pg_temp.id('DLTEST-2'), 'START')$q$, 'error:P0001:ORDER_NOT_FOUND');
select pg_temp.try('driver1', 'driver can''t send back to the shop / hand to the company',
  $q$select public.driver_delivery(pg_temp.id('DLTEST-1'), 'BACK')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('driver1', 'admin delivery tools refused',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-1'), 'BACK')$q$, 'error:42501');
select pg_temp.try('driver1', 'can''t assign deliveries',
  $q$select public.staff_assign_delivery(pg_temp.id('DLTEST-2'), 'DRIVER', '00000000-0000-4000-8000-0000000000e3')$q$, 'error:42501');
select pg_temp.try('driver1', 'no staff list for drivers', $q$select 1 from public.staff_directory()$q$, 'rows:0');
reset role;

-- ---------- DRIVER 2 ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000e4'), true);
select pg_temp.try('driver2', 'sees none of these orders', $q$select 1 from public.orders where order_no like 'DLTEST-%'$q$, 'rows:0');
select pg_temp.try('driver2', 'can''t touch driver 1''s order',
  $q$select public.driver_delivery(pg_temp.id('DLTEST-1'), 'FAILED', null, 'x')$q$, 'error:P0001:ORDER_NOT_FOUND');
reset role;

-- ---------- OWNER ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000e2'), true);
select pg_temp.try('owner', 'sees the staff names', $q$select 1 from public.staff_directory() where name like 'DLTEST%'$q$, 'rows:5');
select pg_temp.try('owner', 'can''t change deliveries',
  $q$select public.staff_delivery(pg_temp.id('DLTEST-2'), 'BACK')$q$, 'error:42501');
select pg_temp.try('owner', 'can''t use the driver tools',
  $q$select public.driver_delivery(pg_temp.id('DLTEST-1'), 'START')$q$, 'error:42501');
reset role;

-- ---------- visitor ----------
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'no staff list', $q$select 1 from public.staff_directory()$q$, 'error:42501');
select pg_temp.try('anon', 'no delivery tools', $q$select public.staff_delivery(1, 'BACK')$q$, 'error:42501');
select pg_temp.try('anon', 'no driver tools', $q$select public.driver_delivery(1, 'START')$q$, 'error:42501');
reset role;

-- ---------- ADMIN: back to the shop, returns ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000e1'), true);
select pg_temp.try('admin', 'order 2: driver 2, out, then back to the shop',
  $q$select 1 where public.staff_assign_delivery(pg_temp.id('DLTEST-2'), 'DRIVER', '00000000-0000-4000-8000-0000000000e4') is not null
       and public.staff_delivery(pg_temp.id('DLTEST-2'), 'OUT')->>'status' = 'OUT_FOR_DELIVERY'
       and public.staff_delivery(pg_temp.id('DLTEST-2'), 'BACK')->>'status' = 'PACKED'$q$, 'rows:1');
select pg_temp.try('admin', 'delivered order -> returned (cancel_order, stock back)',
  $q$select public.cancel_order(pg_temp.id('DLTEST-4'), 'Customer sent it back', true)$q$, 'rows:1');
select pg_temp.try('admin', '... RETURNED',
  $q$select 1 where (pg_temp.o('DLTEST-4')).status = 'RETURNED'$q$, 'rows:1');
select pg_temp.try('admin', 'returned order can''t be assigned',
  $q$select public.staff_assign_delivery(pg_temp.id('DLTEST-4'), 'DRIVER', null)$q$, 'error:P0001:BAD_STATUS_CHANGE');
reset role;

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
