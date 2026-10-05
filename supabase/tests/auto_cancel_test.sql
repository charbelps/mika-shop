-- =====================================================================
-- Mika Shop: auto-cancel of unpaid Whish/OMT orders (cancel_unpaid_orders). ROLLED BACK.
-- Needs the test data (supabase/tests/test_data.sql).
-- Run:  supabase db query --linked -f supabase/tests/auto_cancel_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to anon; grant all on sequence _r_n_seq to anon;
create temp table _v (k text primary key, v text);

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
create function pg_temp.place(p_pay text, p_name text) returns bigint language plpgsql as $$
declare v_no text; v_id bigint;
begin
  v_no := public.place_order(jsonb_build_object('name', p_name, 'phone', '70 333 222',
    'zone_id', (select id from public.delivery_zones where district = '[TEST] District'),
    'town', 'Testville', 'address', 'Bldg: auto'), '[{"sku":"TEST-BOX-01","qty":2}]', p_pay) ->> 'order_no';
  select id into v_id from public.orders where order_no = v_no;
  return v_id;
end $$;

update public.settings set value = '76 000 000' where key = 'whish_number';
update public.settings set value = 'OMT test details' where key = 'omt_details';
update public.settings set value = '' where key = 'unpaid_cancel_hours';
insert into _v select 'box0', stock::text from public.products where sku = 'TEST-BOX-01';

insert into _v select 'old_whish', pg_temp.place('WHISH', '[TEST] old whish')::text;
insert into _v select 'old_omt',   pg_temp.place('OMT',   '[TEST] old omt')::text;
insert into _v select 'old_paid',  pg_temp.place('WHISH', '[TEST] old paid')::text;
insert into _v select 'old_cod',   pg_temp.place('COD',   '[TEST] old cod')::text;
insert into _v select 'new_whish', pg_temp.place('WHISH', '[TEST] new whish')::text;
update public.orders set payment_status = 'PAID', payment_ref = 'x' where id = pg_temp.v('old_paid')::bigint;
update public.orders set created_at = now() - interval '30 hours'
  where id in (pg_temp.v('old_whish')::bigint, pg_temp.v('old_omt')::bigint, pg_temp.v('old_paid')::bigint, pg_temp.v('old_cod')::bigint);

select pg_temp.try('5 test orders took 10 boxes', $q$select (pg_temp.v('box0')::int - stock)::text from public.products where sku = 'TEST-BOX-01'$q$, '10');
select pg_temp.try('hours empty -> nothing cancelled', 'select public.cancel_unpaid_orders()::text', '0');
update public.settings set value = 'abc' where key = 'unpaid_cancel_hours';
select pg_temp.try('hours "abc" -> nothing cancelled', 'select public.cancel_unpaid_orders()::text', '0');
update public.settings set value = '0' where key = 'unpaid_cancel_hours';
select pg_temp.try('hours 0 -> nothing cancelled', 'select public.cancel_unpaid_orders()::text', '0');
update public.settings set value = '48' where key = 'unpaid_cancel_hours';
select pg_temp.try('hours 48, orders 30h old -> nothing cancelled', 'select public.cancel_unpaid_orders()::text', '0');

update public.settings set value = '24' where key = 'unpaid_cancel_hours';
select pg_temp.try('hours 24 -> the 2 old unpaid Whish/OMT orders cancelled', 'select public.cancel_unpaid_orders()::text', '2');
select pg_temp.try('which orders are cancelled',
  $q$select string_agg(name || '=' || status, ', ' order by id) from public.orders where name like '[TEST] old %' or name = '[TEST] new whish'$q$,
  '[TEST] old whish=CANCELLED, [TEST] old omt=CANCELLED, [TEST] old paid=NEW, [TEST] old cod=NEW, [TEST] new whish=NEW');
select pg_temp.try('reason says automatic', $q$select cancel_reason from public.orders where id = pg_temp.v('old_whish')::bigint$q$, 'Not paid within 24 hours (automatic)');
select pg_temp.try('stock back for the 2 cancelled (4 boxes)', $q$select (pg_temp.v('box0')::int - stock)::text from public.products where sku = 'TEST-BOX-01'$q$, '6');
select pg_temp.try('CANCEL log rows, no user (system)', $q$select count(*) || ' ' || bool_and(by_user is null) from public.stock_log
   where reason = 'CANCEL' and order_id in (pg_temp.v('old_whish')::bigint, pg_temp.v('old_omt')::bigint)$q$, '2 true');
select pg_temp.try('running again cancels nothing more', 'select public.cancel_unpaid_orders()::text', '0');

select pg_temp.try('cron job scheduled every 15 minutes',
  $q$select schedule || ' ' || active from cron.job where jobname = 'cancel-unpaid-orders'$q$, '*/15 * * * * true');

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.try('visitor cannot run the auto-cancel', 'select public.cancel_unpaid_orders()::text', 'error:42501');
reset role;

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
