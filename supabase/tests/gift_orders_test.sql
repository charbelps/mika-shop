-- =====================================================================
-- Mika Shop: gift orders (F6, migration 27). ROLLED BACK, leaves nothing.
-- Run:  supabase db query --linked -f supabase/tests/gift_orders_test.sql
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

-- test zones: one with a fee, one without; a product with stock; Whish offered
create temp table _v (k text primary key, v text);
grant all on _v to anon, authenticated;
insert into public.delivery_zones (governorate, district, fee, eta_days, active, sort)
  values ('[GFTEST] Gov', '[GFTEST] Paid area', 3.00, '1', true, 9001), ('[GFTEST] Gov', '[GFTEST] No-fee area', null, null, true, 9002);
insert into _v select 'zone_fee', id::text from public.delivery_zones where district = '[GFTEST] Paid area';
insert into _v select 'zone_nofee', id::text from public.delivery_zones where district = '[GFTEST] No-fee area';
insert into public.products (sku, name_en, price, stock) values ('GFTEST-1', 'Gift candle', 10, 20);
update public.settings set value = '[TEST] 70 000 000' where key = 'whish_number';
update public.settings set value = 'on' where key = 'fee_tbc_enabled';
-- a buyer who ordered before, with a saved address
insert into public.customers (phone, name, governorate, district, town, address, orders_count, total_spent)
  values ('+96170777001', '[GFTEST] Old buyer', 'Beirut', 'Beirut', 'Hamra', 'Bldg: mine', 2, 50);

create function pg_temp.v(p_k text) returns text language sql as $$ select v from pg_temp._v where k = p_k $$;
grant execute on function pg_temp.v(text) to anon, authenticated;
create function pg_temp.cust(p_zone text, p_phone text, p_gift jsonb) returns jsonb language sql as $$
  select jsonb_build_object('name', '[GFTEST] Buyer', 'phone', p_phone, 'zone_id', p_zone,
    'town', 'Recipient town', 'address', 'Bldg: recipient', 'landmark', 'blue door', 'location_url', '')
    || case when p_gift is null then '{}'::jsonb else jsonb_build_object('gift', p_gift) end $$;
grant execute on function pg_temp.cust(text, text, jsonb) to anon, authenticated;
create function pg_temp.items() returns jsonb language sql as $$ select '[{"sku":"GFTEST-1","qty":1}]'::jsonb $$;
grant execute on function pg_temp.items() to anon, authenticated;
-- remembers the answer of a place_order call for later checks
create function pg_temp.order_as(p_key text, p_customer jsonb, p_payment text) returns void language plpgsql as $$
declare v jsonb;
begin
  v := public.place_order(p_customer, pg_temp.items(), p_payment, '');
  insert into pg_temp._v values (p_key, v::text) on conflict (k) do update set v = excluded.v;
end $$;
grant execute on function pg_temp.order_as(text, jsonb, text) to anon;
create function pg_temp.o(p_key text) returns public.orders language sql security definer as $$
  select o.* from public.orders o where o.order_no = (pg_temp.v(p_key)::jsonb->>'order_no') $$;
grant execute on function pg_temp.o(text) to anon, authenticated;
create function pg_temp.c(p_phone text) returns public.customers language sql security definer as $$
  select * from public.customers where phone = p_phone $$;
grant execute on function pg_temp.c(text) to anon, authenticated;

set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'gift paid by Whish: accepted',
  $q$select pg_temp.order_as('g1', pg_temp.cust(pg_temp.v('zone_fee'), '70 777 002',
     '{"name":"  Lara  ","phone":"03 456 789","note":"Happy birthday!"}'::jsonb), 'WHISH')$q$, 'rows:1');
select pg_temp.try('anon', '... answer says gift + recipient',
  $q$select 1 where (pg_temp.v('g1')::jsonb->>'is_gift')::boolean and pg_temp.v('g1')::jsonb->>'recipient_name' = 'Lara'$q$, 'rows:1');
select pg_temp.try('anon', '... order: buyer name / phone, recipient name / phone / note, recipient address, its fee',
  $q$select 1 from (select (pg_temp.o('g1')).*) o where o.is_gift and o.name = '[GFTEST] Buyer' and o.phone = '+96170777002'
     and o.recipient_name = 'Lara' and o.recipient_phone = '+9613456789' and o.gift_note = 'Happy birthday!'
     and o.town = 'Recipient town' and o.address = 'Bldg: recipient' and o.landmark = 'blue door'
     and o.delivery_fee = 3 and o.total = 13 and o.payment_status = 'AWAITING'$q$, 'rows:1');
select pg_temp.try('anon', '... a new buyer is saved WITHOUT the recipient''s address',
  $q$select 1 from (select (pg_temp.c('+96170777002')).*) c where c.name = '[GFTEST] Buyer' and c.address is null and c.town is null and c.orders_count = 1 and c.total_spent = 13$q$, 'rows:1');
select pg_temp.try('anon', 'gift from a buyer who ordered before (OMT not set: Whish)',
  $q$select pg_temp.order_as('g2', pg_temp.cust(pg_temp.v('zone_fee'), '70 777 001', '{"name":"Nour","phone":"71 222 333"}'::jsonb), 'WHISH')$q$, 'rows:1');
select pg_temp.try('anon', '... the buyer''s saved address is kept, counts go up',
  $q$select 1 from (select (pg_temp.c('+96170777001')).*) c where c.address = 'Bldg: mine' and c.town = 'Hamra' and c.district = 'Beirut'
     and c.name = '[GFTEST] Buyer' and c.orders_count = 3 and c.total_spent = 63$q$, 'rows:1');
select pg_temp.try('anon', '... no card note = empty',
  $q$select 1 from (select (pg_temp.o('g2')).*) o where o.is_gift and o.gift_note is null$q$, 'rows:1');
select pg_temp.try('anon', 'gift by cash on delivery -> GIFT_NEEDS_PREPAID',
  $q$select pg_temp.order_as('x', pg_temp.cust(pg_temp.v('zone_fee'), '70 777 003', '{"name":"Lara","phone":"03 456 789"}'::jsonb), 'COD')$q$, 'error:P0001:GIFT_NEEDS_PREPAID');
select pg_temp.try('anon', 'recipient phone not Lebanese -> INVALID_RECIPIENT_PHONE',
  $q$select pg_temp.order_as('x', pg_temp.cust(pg_temp.v('zone_fee'), '70 777 003', '{"name":"Lara","phone":"+33 6 12 34 56 78"}'::jsonb), 'WHISH')$q$, 'error:P0001:INVALID_RECIPIENT_PHONE');
select pg_temp.try('anon', 'recipient name missing -> INVALID_INPUT',
  $q$select pg_temp.order_as('x', pg_temp.cust(pg_temp.v('zone_fee'), '70 777 003', '{"name":"  ","phone":"03 456 789"}'::jsonb), 'WHISH')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('anon', 'card note longer than 300 -> INVALID_INPUT',
  $q$select pg_temp.order_as('x', pg_temp.cust(pg_temp.v('zone_fee'), '70 777 003', jsonb_build_object('name', 'Lara', 'phone', '03 456 789', 'note', repeat('x', 301))), 'WHISH')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('anon', 'gift to an area without a fee (switch on) -> GIFT_NEEDS_FEE',
  $q$select pg_temp.order_as('x', pg_temp.cust(pg_temp.v('zone_nofee'), '70 777 003', '{"name":"Lara","phone":"03 456 789"}'::jsonb), 'WHISH')$q$, 'error:P0001:GIFT_NEEDS_FEE');
select pg_temp.try('anon', 'normal order to that area still works (fee to be confirmed)',
  $q$select pg_temp.order_as('n1', pg_temp.cust(pg_temp.v('zone_nofee'), '70 777 004', null), 'COD')$q$, 'rows:1');
select pg_temp.try('anon', '... not a gift, no recipient, address saved for the customer',
  $q$select 1 from (select (pg_temp.o('n1')).*) o where not o.is_gift and o.recipient_name is null and o.fee_tbc
     and (pg_temp.c('+96170777004')).address = 'Bldg: recipient'$q$, 'rows:1');
select pg_temp.try('anon', '"gift" that is not an object is ignored (normal order)',
  $q$select pg_temp.order_as('n2', pg_temp.cust(pg_temp.v('zone_fee'), '70 777 005', '"yes"'::jsonb), 'COD')$q$, 'rows:1');
select pg_temp.try('anon', '... normal order', $q$select 1 from (select (pg_temp.o('n2')).*) o where not o.is_gift$q$, 'rows:1');
select pg_temp.try('anon', 'stock taken once per accepted order (20 - 4 = 16)',
  $q$select 1 from public.products where sku = 'GFTEST-1' and stock = 16$q$, 'rows:1');
reset role;

select pg_temp.try('db', 'a gift without recipient can''t be stored',
  $q$update public.orders set recipient_phone = null where order_no = (pg_temp.v('g1')::jsonb->>'order_no')$q$, 'error:23514');
select pg_temp.try('db', 'track_order still answers the buyer''s phone only',
  $q$select 1 where public.track_order(pg_temp.v('g1')::jsonb->>'order_no', '70 777 002') is not null
       and public.track_order(pg_temp.v('g1')::jsonb->>'order_no', '03 456 789') is null$q$, 'rows:1');

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
