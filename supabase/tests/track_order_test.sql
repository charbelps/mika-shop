-- =====================================================================
-- Mika Shop: track_order test, as a logged-out visitor. ROLLED BACK.
-- Run:  supabase db query --linked -f supabase/tests/track_order_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to anon; grant all on sequence _r_n_seq to anon;
create temp table _v (k text primary key, v text);
grant select on _v to anon;

create function pg_temp.try(p_test text, p_sql text, p_expected text)
returns void language plpgsql as $$
declare v_got text;
begin
  begin
    execute p_sql into v_got;
  exception when others then
    v_got := 'error:' || sqlstate;
  end;
  insert into pg_temp._r (test, expected, got) values (p_test, p_expected, coalesce(v_got, 'null'));
end $$;

-- an order with a prefix, made as postgres (rolled back)
update public.settings set value = 'MS-' where key = 'order_prefix';
insert into _v select 'no', public.place_order(jsonb_build_object('name', '[TEST] Tracker', 'phone', '76 123 456',
  'zone_id', (select id from public.delivery_zones where district = '[TEST] District'), 'town', 'T', 'address', 'Bldg: t'),
  '[{"sku":"TEST-BOX-01","qty":1}]', 'COD') ->> 'order_no';
update public.orders set status = 'PACKED' where order_no = (select v from _v where k = 'no');

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.try('right number + phone -> status',
  $q$select public.track_order((select v from pg_temp._v where k = 'no'), '76 123 456') ->> 'status'$q$, 'PACKED');
select pg_temp.try('returns ONLY order_no, status, created_at, updated_at',
  $q$select string_agg(k, ',' order by k) from jsonb_object_keys(public.track_order((select v from pg_temp._v where k = 'no'), '+96176123456')) k$q$,
  'created_at,order_no,status,updated_at');
select pg_temp.try('phone in another format (00961, dashes)',
  $q$select public.track_order((select v from pg_temp._v where k = 'no'), '00961-76-123456') ->> 'status'$q$, 'PACKED');
select pg_temp.try('order number lower-case + spaces',
  $q$select public.track_order('  ' || lower((select v from pg_temp._v where k = 'no')) || ' ', '76123456') ->> 'status'$q$, 'PACKED');
select pg_temp.try('wrong phone -> nothing', $q$select public.track_order((select v from pg_temp._v where k = 'no'), '70 000 000')::text$q$, 'null');
select pg_temp.try('wrong number -> nothing (same answer)', $q$select public.track_order('MS-99999999', '76 123 456')::text$q$, 'null');
select pg_temp.try('invalid phone -> nothing', $q$select public.track_order((select v from pg_temp._v where k = 'no'), 'abc')::text$q$, 'null');
select pg_temp.try('empty input -> nothing', $q$select public.track_order('', '')::text$q$, 'null');
select pg_temp.try('visitor still cannot read orders directly', 'select count(*)::text from public.orders', 'error:42501');
reset role;

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
