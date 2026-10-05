-- =====================================================================
-- Mika Shop: admin settings / delivery / first-order / track payment test (Phase 1c). ROLLED BACK.
-- Needs the test data (supabase/tests/test_data.sql).
-- Run:  supabase db query --linked -f supabase/tests/admin_settings_test.sql
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
  ('00000000-0000-4000-8000-0000000000d1', 'settingstest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d2', 'settingstest-owner@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000d1', 'SETTINGSTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000d2', 'SETTINGSTEST owner', 'OWNER');
insert into _v select 'zone', id::text from public.delivery_zones where district = '[TEST] District';

-- ---------- schema ----------
select pg_temp.try('privacy_en / privacy_ar exist, public', $q$select string_agg(key || '=' || is_public, ',' order by key) from public.settings where key like 'privacy_%'$q$, 'privacy_ar=true,privacy_en=true');
select pg_temp.try('phone_number setting removed', $q$select count(*)::text from public.settings where key = 'phone_number'$q$, '0');

-- ---------- who may save ----------
set local role anon; select pg_temp.as_user(null);
select pg_temp.try('visitor save -> refused', $q$select public.admin_save_settings('{"currency":"USD"}')::text$q$, 'error:42501');
reset role;
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000d2');
select pg_temp.try('OWNER save -> refused', $q$select public.admin_save_settings('{"currency":"USD"}')::text$q$, 'error:42501');
select pg_temp.try('OWNER direct update -> nothing changed', $q$with u as (update public.settings set value = 'X' where key = 'currency' returning 1) select count(*)::text from u$q$, '0');
select pg_temp.try('OWNER edit zone -> nothing changed', $q$with u as (update public.delivery_zones set fee = 1 where id = pg_temp.v('zone')::bigint returning 1) select count(*)::text from u$q$, '0');
reset role;

-- ---------- ADMIN ----------
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000d1');
select pg_temp.try('save 4 values -> 4 changed',
  $q$select public.admin_save_settings('{"shop_name_en":"  Test Shop ","currency":"USD","order_prefix":"MS-","unpaid_cancel_hours":"24"}')::text$q$, '4');
select pg_temp.try('values trimmed and saved',
  $q$select string_agg(key || '=' || value, ',' order by key) from public.settings where key in ('shop_name_en','currency','order_prefix','unpaid_cancel_hours')$q$,
  'currency=USD,order_prefix=MS-,shop_name_en=Test Shop,unpaid_cancel_hours=24');
select pg_temp.try('saving the same values again -> 0 changed',
  $q$select public.admin_save_settings('{"currency":"USD","order_prefix":"MS-"}')::text$q$, '0');
select pg_temp.try('WhatsApp number normalized to +961',
  $q$select public.admin_save_settings('{"whatsapp_number":"03 123 456"}')::text$q$, '1');
select pg_temp.try('... WhatsApp number normalized to +961', $q$select value from public.settings where key = 'whatsapp_number'$q$, '+9613123456');
select pg_temp.try('bad WhatsApp number -> BAD_PHONE', $q$select public.admin_save_settings('{"whatsapp_number":"123"}')::text$q$, 'error:P0001:BAD_PHONE');
select pg_temp.try('hours not a number -> BAD_NUMBER', $q$select public.admin_save_settings('{"unpaid_cancel_hours":"two"}')::text$q$, 'error:P0001:BAD_NUMBER');
select pg_temp.try('negative low stock -> BAD_NUMBER', $q$select public.admin_save_settings('{"low_stock_threshold":"-3"}')::text$q$, 'error:P0001:BAD_NUMBER');
select pg_temp.try('empty number allowed (= off)', $q$select public.admin_save_settings('{"unpaid_cancel_hours":""}')::text$q$, '1');
select pg_temp.try('prefix with a space -> BAD_PREFIX', $q$select public.admin_save_settings('{"order_prefix":"M S"}')::text$q$, 'error:P0001:BAD_PREFIX');
select pg_temp.try('currency too long -> TOO_LONG', $q$select public.admin_save_settings('{"currency":"US DOLLARS!!"}')::text$q$, 'error:P0001:TOO_LONG');
select pg_temp.try('unknown key -> UNKNOWN_SETTING', $q$select public.admin_save_settings('{"hack":"x"}')::text$q$, 'error:P0001:UNKNOWN_SETTING');
select pg_temp.try('technical key order_alert_url -> UNKNOWN_SETTING', $q$select public.admin_save_settings('{"order_alert_url":"https://evil.example"}')::text$q$, 'error:P0001:UNKNOWN_SETTING');
select pg_temp.try('one bad value -> nothing saved (one transaction)',
  $q$select public.admin_save_settings('{"currency":"EUR","unpaid_cancel_hours":"x"}')::text$q$, 'error:P0001:BAD_NUMBER');
select pg_temp.try('... currency still USD', $q$select value from public.settings where key = 'currency'$q$, 'USD');
select pg_temp.try('Arabic privacy text saved',
  $q$select public.admin_save_settings('{"privacy_ar":"نستعمل رقمك للتوصيل فقط."}')::text$q$, '1');
select pg_temp.try('... Arabic privacy text kept exactly', $q$select value from public.settings where key = 'privacy_ar'$q$, 'نستعمل رقمك للتوصيل فقط.');

-- delivery areas (direct table edits, as the screen does)
select pg_temp.try('ADMIN sets a fee, ETA, carrier',
  $q$with u as (update public.delivery_zones set fee = 4.5, eta_days = '1-2', default_carrier = 'DRIVER' where id = pg_temp.v('zone')::bigint returning fee::text || ' ' || eta_days || ' ' || default_carrier) select * from u$q$, '4.50 1-2 DRIVER');
select pg_temp.try('negative fee refused', $q$update public.delivery_zones set fee = -1 where id = pg_temp.v('zone')::bigint$q$, 'error:23514');
select pg_temp.try('bad carrier refused', $q$update public.delivery_zones set default_carrier = 'BIKE' where id = pg_temp.v('zone')::bigint$q$, 'error:23514');
select pg_temp.try('ADMIN adds an area',
  $q$with i as (insert into public.delivery_zones (governorate, governorate_ar, district, district_ar, fee, sort) values ('[TEST] Zone', '[تجربة]', '[TEST] New area', '[تجربة] منطقة', 3, 9999) returning district) select * from i$q$, '[TEST] New area');
select pg_temp.try('name with spaces around refused', $q$insert into public.delivery_zones (governorate, district) values ('[TEST] Zone', ' Spaces ')$q$, 'error:23514');
select pg_temp.try('same area twice refused', $q$insert into public.delivery_zones (governorate, district) values ('[TEST] Zone', '[TEST] New area')$q$, 'error:23505');
reset role;
-- visitors see the new fee at checkout
set local role anon; select pg_temp.as_user(null);
select pg_temp.try('visitor reads the new fee', $q$select fee::text from public.delivery_zones where id = pg_temp.v('zone')::bigint$q$, '4.50');
select pg_temp.try('visitor cannot read privacy? (public, yes)', $q$select count(*)::text from public.settings where key = 'privacy_en'$q$, '1');
select pg_temp.try('visitor cannot change a fee', $q$with u as (update public.delivery_zones set fee = 0 returning 1) select count(*)::text from u$q$, 'error:42501');

-- ---------- first order + payment received ----------
select pg_temp.try('first order of a new phone -> is_first_order',
  $q$select (public.place_order(jsonb_build_object('name', '[TEST] First', 'phone', '71 999 001', 'zone_id', pg_temp.v('zone'), 'town', 'T', 'address', 'Bldg: 1'),
     '[{"sku":"TEST-BOX-01","qty":1}]', 'COD') ? 'order_no')::text$q$, 'true');
reset role;
select pg_temp.try('... flagged as first order, number has the new prefix',
  $q$select is_first_order::text || ' ' || (order_no like 'MS-%')::text from public.orders where phone = '+96171999001'$q$, 'true true');
set local role anon; select pg_temp.as_user(null);
select pg_temp.try('second order same phone',
  $q$select (public.place_order(jsonb_build_object('name', '[TEST] First', 'phone', '071999001', 'zone_id', pg_temp.v('zone'), 'town', 'T', 'address', 'Bldg: 1'),
     '[{"sku":"TEST-BOX-01","qty":1}]', 'COD') ? 'order_no')::text$q$, 'true');
reset role;
select pg_temp.try('... second order NOT flagged',
  $q$select string_agg(is_first_order::text, ',' order by id) from public.orders where phone = '+96171999001'$q$, 'true,false');
select pg_temp.try('existing orders backfilled: one first order per phone',
  $q$select (count(*) filter (where is_first_order) = count(distinct phone))::text from public.orders$q$, 'true');

-- Whish order, confirm payment, track shows payment_received
update public.settings set value = '76 000 000' where key = 'whish_number';
insert into _v select 'cod1', order_no from public.orders where phone = '+96171999001' order by id limit 1;
insert into _v select 'w', (public.place_order(jsonb_build_object('name', '[TEST] Whish track', 'phone', '71 999 002', 'zone_id', pg_temp.v('zone'), 'town', 'T', 'address', 'Bldg: 1'),
  '[{"sku":"TEST-BOX-01","qty":1}]', 'WHISH'))->>'order_no';
set local role anon; select pg_temp.as_user(null);
select pg_temp.try('track: Whish not paid yet -> payment_received false',
  $q$select public.track_order(pg_temp.v('w'), '71 999 002')->>'payment_received'$q$, 'false');
reset role;
set local role authenticated; select pg_temp.as_user('00000000-0000-4000-8000-0000000000d1');
select public.staff_confirm_payment((select id from public.orders where order_no = pg_temp.v('w')), 'REF-1');
reset role;
set local role anon; select pg_temp.as_user(null);
select pg_temp.try('track: after Mika confirms -> payment_received true',
  $q$select public.track_order(pg_temp.v('w'), '71 999 002')->>'payment_received'$q$, 'true');
select pg_temp.try('track: COD order never says payment received',
  $q$select public.track_order(pg_temp.v('cod1'), '71 999 001')->>'payment_received'$q$, 'false');
select pg_temp.try('track: still only 5 fields',
  $q$select (select count(*) from jsonb_object_keys(public.track_order(pg_temp.v('w'), '71 999 002')))::text$q$, '5');
reset role;

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
