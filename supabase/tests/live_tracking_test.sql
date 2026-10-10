-- =====================================================================
-- Mika Shop: live driver tracking (migration 33, D3). ROLLED BACK, leaves nothing.
-- Run:  supabase db query --linked -f supabase/tests/live_tracking_test.sql
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
create function pg_temp.live_rows(p_driver uuid) returns bigint language sql security definer as $$
  select count(*) from public.driver_live where driver_id = p_driver $$;
grant execute on function pg_temp.id(text), pg_temp.live_rows(uuid) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000d1', 'lttest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d2', 'lttest-owner@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d3', 'lttest-driver1@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d4', 'lttest-driver2@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d5', 'lttest-nobody@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role, active) values
  ('00000000-0000-4000-8000-0000000000d1', 'LTTEST admin', 'ADMIN', true),
  ('00000000-0000-4000-8000-0000000000d2', 'LTTEST owner', 'OWNER', true),
  ('00000000-0000-4000-8000-0000000000d3', 'LTTEST driver 1', 'DRIVER', true),
  ('00000000-0000-4000-8000-0000000000d4', 'LTTEST driver 2', 'DRIVER', true);
insert into public.orders (order_no, phone, name, governorate, district, town, address, location_url, subtotal, delivery_fee, total,
                           payment_method, payment_status, status, carrier, driver_id) values
  ('LTTEST-1', '+96170000201', 'Map buyer', 'Beirut', 'Beirut', 'Hamra', 'Bldg 1', 'https://www.google.com/maps?q=33.8938,35.5018',
     18, 2, 20, 'COD', 'UNPAID', 'OUT_FOR_DELIVERY', 'DRIVER', '00000000-0000-4000-8000-0000000000d3'),
  ('LTTEST-2', '+96170000202', 'Short link buyer', 'Beirut', 'Beirut', 'Hamra', 'Bldg 2', 'https://maps.app.goo.gl/AbCdEf123',
     18, 2, 20, 'COD', 'UNPAID', 'OUT_FOR_DELIVERY', 'DRIVER', '00000000-0000-4000-8000-0000000000d3'),
  ('LTTEST-3', '+96170000203', 'At the shop', 'Beirut', 'Beirut', 'Hamra', 'Bldg 3', null,
     18, 2, 20, 'COD', 'UNPAID', 'PACKED', 'DRIVER', '00000000-0000-4000-8000-0000000000d3'),
  ('LTTEST-4', '+96170000204', 'Other driver', 'Beirut', 'Beirut', 'Hamra', 'Bldg 4', null,
     18, 2, 20, 'COD', 'UNPAID', 'OUT_FOR_DELIVERY', 'DRIVER', '00000000-0000-4000-8000-0000000000d4'),
  ('LTTEST-5', '+96170000205', 'Company', 'Akkar', 'Akkar', 'Halba', 'Bldg 5', null,
     30, 5, 35, 'COD', 'UNPAID', 'WITH_COMPANY', 'COMPANY', null);

-- ---------- coordinates in location links (internal helper) ----------
select pg_temp.try('db', 'link ?q=lat,lng', $q$select 1 where public.location_coords('https://www.google.com/maps?q=33.8938,35.5018') = array[33.8938, 35.5018]::float8[]$q$, 'rows:1');
select pg_temp.try('db', 'link @lat,lng,zoom', $q$select 1 where public.location_coords('https://www.google.com/maps/place/X/@33.8869,35.5131,17z') = array[33.8869, 35.5131]::float8[]$q$, 'rows:1');
select pg_temp.try('db', 'link exact pin !3d!4d wins over @', $q$select 1 where public.location_coords('https://www.google.com/maps/place/X/@33.80,35.40,17z/data=!3m1!4b1!4m5!3m4!1s0x0:0x0!8m2!3d33.8869!4d35.5131') = array[33.8869, 35.5131]::float8[]$q$, 'rows:1');
select pg_temp.try('db', 'link query=lat%2Clng', $q$select 1 where public.location_coords('https://www.google.com/maps/search/?api=1&query=33.9,35.6') = array[33.9, 35.6]::float8[]
  and public.location_coords('https://www.google.com/maps/search/?api=1&query=33.9%2C35.6') = array[33.9, 35.6]::float8[]$q$, 'rows:1');
select pg_temp.try('db', 'OpenStreetMap #map=zoom/lat/lng', $q$select 1 where public.location_coords('https://www.openstreetmap.org/#map=17/34.4367/35.8497') = array[34.4367, 35.8497]::float8[]$q$, 'rows:1');
select pg_temp.try('db', 'short link / empty / words: no coordinates', $q$select 1 where public.location_coords('https://maps.app.goo.gl/AbCdEf123') is null
  and public.location_coords('') is null and public.location_coords(null) is null and public.location_coords('https://example.com/?q=hamra') is null$q$, 'rows:1');
select pg_temp.try('db', 'impossible latitude ignored', $q$select 1 where public.location_coords('https://www.google.com/maps?q=95.1,35.5') is null$q$, 'rows:1');
select pg_temp.try('db', 'distance Beirut -> Tripoli about 70 km', $q$select 1 where public.km_between(33.8938, 35.5018, 34.4367, 35.8497) between 65 and 75$q$, 'rows:1');
select pg_temp.try('db', 'cleanup cron job scheduled every 15 minutes', $q$select 1 from cron.job where jobname = 'driver-live-cleanup' and schedule = '*/15 * * * *'$q$, 'rows:1');

-- ---------- visitor ----------
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'cannot read driver_live', $q$select * from public.driver_live$q$, 'error:42501');
select pg_temp.try('anon', 'cannot write driver_live', $q$insert into public.driver_live (driver_id, order_id) values ('00000000-0000-4000-8000-0000000000d3', 1)$q$, 'error:42501');
select pg_temp.try('anon', 'cannot start sharing', $q$select public.driver_live_start(pg_temp.id('LTTEST-1'))$q$, 'error:42501');
select pg_temp.try('anon', 'cannot send a position', $q$select public.driver_live_update(33.9, 35.5, 10)$q$, 'error:42501');
select pg_temp.try('anon', 'cannot use the internal helpers', $q$select 1 from (values ('https://www.google.com/maps?q=33.9,35.5')) v(u) where public.location_coords(u) is not null$q$, 'error:42501');
select pg_temp.try('anon', 'cannot run the cleanup', $q$select public.driver_live_cleanup()$q$, 'error:42501');
select pg_temp.try('anon', 'track_live: wrong phone = nothing', $q$select 1 where public.track_live('LTTEST-1', '+96170000999') is null$q$, 'rows:1');
select pg_temp.try('anon', 'track_live: wrong number = nothing', $q$select 1 where public.track_live('LTTEST-999', '+96170000201') is null$q$, 'rows:1');
select pg_temp.try('anon', 'on the way but not started: status only, no position', $q$select 1 where public.track_live('lttest-1', '70 000 201') = '{"status":"OUT_FOR_DELIVERY","sharing":false}'::jsonb$q$, 'rows:1');
select pg_temp.try('anon', 'company delivery: never a map', $q$select 1 where public.track_live('LTTEST-5', '+96170000205') = '{"status":"WITH_COMPANY","sharing":false}'::jsonb$q$, 'rows:1');
reset role;

-- ---------- driver 1 ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d3'), true);
select pg_temp.try('driver1', 'cannot read driver_live directly', $q$select * from public.driver_live$q$, 'error:42501');
select pg_temp.try('driver1', 'position before starting: nothing shared', $q$select 1 where public.driver_live_update(33.9, 35.5, 10)->>'sharing' = 'false'$q$, 'rows:1');
select pg_temp.try('driver1', 'order still at the shop: refused', $q$select public.driver_live_start(pg_temp.id('LTTEST-3'))$q$, 'error:P0001:NOT_ON_THE_WAY');
select pg_temp.try('driver1', 'another driver''s order: not found', $q$select public.driver_live_start(pg_temp.id('LTTEST-4'))$q$, 'error:P0001:ORDER_NOT_FOUND');
select pg_temp.try('driver1', 'company order: not found', $q$select public.driver_live_start(pg_temp.id('LTTEST-5'))$q$, 'error:P0001:ORDER_NOT_FOUND');
select pg_temp.try('driver1', 'start order 1', $q$select public.driver_live_start(pg_temp.id('LTTEST-1'))$q$, 'rows:1');
select pg_temp.try('driver1', 'his screen knows: sharing order 1', $q$select 1 where (public.driver_live_mine()->>'order_id')::bigint = pg_temp.id('LTTEST-1')$q$, 'rows:1');
reset role;
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'started, no GPS yet: sharing, no position', $q$select 1 where public.track_live('LTTEST-1', '+96170000201') = '{"status":"OUT_FOR_DELIVERY","sharing":true,"position":false}'::jsonb$q$, 'rows:1');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d3'), true);
select pg_temp.try('driver1', 'impossible position refused', $q$select public.driver_live_update(95, 35.5, 10)$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('driver1', 'missing position refused', $q$select public.driver_live_update(null, 35.5, 10)$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('driver1', 'position sent', $q$select 1 where public.driver_live_update(33.880001234, 35.49, 12.4)->>'sharing' = 'true'$q$, 'rows:1');
reset role;

set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'customer 1 sees the position (rounded to ~1 m)', $q$select 1 from (select public.track_live('LTTEST-1', '+96170000201') j) x
  where (j->>'sharing')::boolean and (j->>'position')::boolean and (j->>'lat')::float8 = 33.88 and (j->>'lng')::float8 = 35.49 and (j->>'age_s')::int < 60$q$, 'rows:1');
select pg_temp.try('anon', 'customer 1: distance to the pin in the link (~1.9 km)', $q$select 1 where (public.track_live('LTTEST-1', '+96170000201')->>'distance_km')::numeric between 1.5 and 2.3$q$, 'rows:1');
select pg_temp.try('anon', 'no name, address, link, driver or customer coordinates in the answer', $q$select 1 where not (public.track_live('LTTEST-1', '+96170000201')
  ?| array['name', 'phone', 'address', 'location_url', 'driver_id', 'driver', 'dest', 'dest_lat', 'order_id'])$q$, 'rows:1');
select pg_temp.try('anon', 'customer 2 (same driver, not his current stop) sees nothing', $q$select 1 where public.track_live('LTTEST-2', '+96170000202')->>'sharing' = 'false'$q$, 'rows:1');
select pg_temp.try('anon', 'customer of the other driver sees nothing', $q$select 1 where public.track_live('LTTEST-4', '+96170000204')->>'sharing' = 'false'$q$, 'rows:1');
reset role;

-- one customer at a time: heading to customer 2 now
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d3'), true);
select pg_temp.try('driver1', 'switch to order 2', $q$select public.driver_live_start(pg_temp.id('LTTEST-2'))$q$, 'rows:1');
select pg_temp.try('driver1', 'still one row for him', $q$select 1 where pg_temp.live_rows('00000000-0000-4000-8000-0000000000d3') = 1$q$, 'rows:1');
reset role;
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'customer 1 no longer sees him', $q$select 1 where public.track_live('LTTEST-1', '+96170000201')->>'sharing' = 'false'$q$, 'rows:1');
select pg_temp.try('anon', 'customer 2 sees him (last position), no distance (short link)', $q$select 1 from (select public.track_live('LTTEST-2', '+96170000202') j) x
  where (j->>'position')::boolean and not (j ? 'distance_km')$q$, 'rows:1');
reset role;

-- ---------- other staff: no direct access, can't share ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d1'), true);
select pg_temp.try('admin', 'admin cannot read driver_live', $q$select * from public.driver_live$q$, 'error:42501');
select pg_temp.try('admin', 'admin cannot share', $q$select public.driver_live_start(pg_temp.id('LTTEST-1'))$q$, 'error:42501');
select pg_temp.try('admin', 'admin gets nothing from driver_live_mine', $q$select 1 where public.driver_live_mine() is null$q$, 'rows:1');
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d2'), true);
select pg_temp.try('owner', 'owner cannot read driver_live', $q$select * from public.driver_live$q$, 'error:42501');
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d5'), true);
select pg_temp.try('non-staff', 'logged-in non-staff cannot share', $q$select public.driver_live_update(33.9, 35.5, 10)$q$, 'error:42501');
reset role;

-- ---------- old news is hidden ----------
update public.driver_live set updated_at = now() - interval '11 minutes' where driver_id = '00000000-0000-4000-8000-0000000000d3';
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'no update for 11 min: no position, "stale"', $q$select 1 where public.track_live('LTTEST-2', '+96170000202') = '{"status":"OUT_FOR_DELIVERY","sharing":true,"position":false,"stale":true}'::jsonb$q$, 'rows:1');
reset role;

-- ---------- the delivery ends -> position deleted ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d3'), true);
select pg_temp.try('driver1', 'delivered order 2', $q$select public.driver_delivery(pg_temp.id('LTTEST-2'), 'DELIVERED', 20, null)$q$, 'rows:1');
select pg_temp.try('driver1', '... his position is deleted', $q$select 1 where pg_temp.live_rows('00000000-0000-4000-8000-0000000000d3') = 0$q$, 'rows:1');
select pg_temp.try('driver1', '... a late position changes nothing', $q$select 1 where public.driver_live_update(33.9, 35.5, 10)->>'sharing' = 'false'$q$, 'rows:1');
select pg_temp.try('driver1', '... still nothing stored', $q$select 1 where pg_temp.live_rows('00000000-0000-4000-8000-0000000000d3') = 0$q$, 'rows:1');
reset role;
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'customer 2 after delivery: DELIVERED, no map', $q$select 1 where public.track_live('LTTEST-2', '+96170000202') = '{"status":"DELIVERED","sharing":false}'::jsonb$q$, 'rows:1');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d3'), true);
select pg_temp.try('driver1', 'start order 1 again', $q$select public.driver_live_start(pg_temp.id('LTTEST-1'))$q$, 'rows:1');
select pg_temp.try('driver1', 'not delivered (reason)', $q$select 1 where public.driver_delivery(pg_temp.id('LTTEST-1'), 'FAILED', null, 'No answer')->>'status' = 'FAILED_ATTEMPT'$q$, 'rows:1');
select pg_temp.try('driver1', '... position deleted', $q$select 1 where pg_temp.live_rows('00000000-0000-4000-8000-0000000000d3') = 0$q$, 'rows:1');
select pg_temp.try('driver1', 'failed order can''t be shared until it''s on the way again', $q$select public.driver_live_start(pg_temp.id('LTTEST-1'))$q$, 'error:P0001:NOT_ON_THE_WAY');
select pg_temp.try('driver1', 'try again (on the way)', $q$select 1 where public.driver_delivery(pg_temp.id('LTTEST-1'), 'START')->>'status' = 'OUT_FOR_DELIVERY'$q$, 'rows:1');
select pg_temp.try('driver1', '... and share', $q$select public.driver_live_start(pg_temp.id('LTTEST-1'))$q$, 'rows:1');
select pg_temp.try('driver1', 'stop sharing', $q$select public.driver_live_stop()$q$, 'rows:1');
select pg_temp.try('driver1', '... deleted', $q$select 1 where pg_temp.live_rows('00000000-0000-4000-8000-0000000000d3') = 0$q$, 'rows:1');
select pg_temp.try('driver1', 'share again, then the shop takes it back', $q$select public.driver_live_start(pg_temp.id('LTTEST-1'))$q$, 'rows:1');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d1'), true);
select pg_temp.try('admin', '"back to the shop"', $q$select 1 where public.staff_delivery(pg_temp.id('LTTEST-1'), 'BACK')->>'status' = 'PACKED'$q$, 'rows:1');
select pg_temp.try('admin', '... position deleted', $q$select 1 where pg_temp.live_rows('00000000-0000-4000-8000-0000000000d3') = 0$q$, 'rows:1');
reset role;

-- ---------- a deactivated driver stops sharing ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d4'), true);
select pg_temp.try('driver2', 'driver 2 shares order 4', $q$select public.driver_live_start(pg_temp.id('LTTEST-4'))$q$, 'rows:1');
reset role;
update public.staff set active = false where user_id = '00000000-0000-4000-8000-0000000000d4';
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d4'), true);
select pg_temp.try('driver2', 'deactivated: can''t send positions', $q$select public.driver_live_update(33.9, 35.5, 10)$q$, 'error:42501');
reset role;

-- ---------- cleanup of forgotten rows ----------
update public.driver_live set started_at = now() - interval '3 hours', updated_at = null where driver_id = '00000000-0000-4000-8000-0000000000d4';
select pg_temp.try('db', 'cleanup deletes a row with no news for 2 hours', $q$select 1 where public.driver_live_cleanup() >= 1$q$, 'rows:1');
select pg_temp.try('db', '... gone', $q$select 1 where pg_temp.live_rows('00000000-0000-4000-8000-0000000000d4') = 0$q$, 'rows:1');

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
