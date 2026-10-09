-- =====================================================================
-- Mika Shop: "Tell me when it's back" (F4, migration 26). ROLLED BACK, leaves nothing.
-- Run:  supabase db query --linked -f supabase/tests/stock_alerts_test.sql
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
-- what is in the table now, whoever is asking (the test user may not be allowed to read it)
create function pg_temp.n_open(p_sku text) returns int language sql security definer as $$
  select count(*)::int from public.stock_alerts where sku = p_sku and notified_at is null $$;
create function pg_temp.vid(p_label text) returns bigint language sql as $$
  select id from public.variants where sku = 'SATEST-2' and label_en = p_label $$;
grant execute on function pg_temp.n_open(text), pg_temp.vid(text) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000d1', 'satest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d2', 'satest-owner@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d3', 'satest-nobody@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000d1', 'SATEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000d2', 'SATEST owner', 'OWNER');
insert into public.products (sku, name_en, price, stock, has_variants, active) values
  ('SATEST-1', 'Sold-out bowl', 10, 0, false, true),
  ('SATEST-2', 'Shirt', 20, 0, true, true),
  ('SATEST-3', 'Hidden lamp', 5, 0, false, false),
  ('SATEST-4', 'Other', 5, 0, true, true);
insert into public.variants (sku, label_en, stock, active) values
  ('SATEST-2', 'Size S', 0, true), ('SATEST-2', 'Size XL', 0, false), ('SATEST-4', 'One', 0, true);
-- a phone that already waits for 20 items
insert into public.products (sku, name_en, price, stock) select 'SATEST-L' || g, 'Loop ' || g, 1, 0 from generate_series(1, 20) g;
insert into public.stock_alerts (sku, phone) select 'SATEST-L' || g, '+96170999999' from generate_series(1, 20) g;

-- ---------- visitor ----------
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'ask for a sold-out product',
  $q$select public.request_stock_alert('SATEST-1', null, '70 123 456', 'Rita', 'ar', '')$q$, 'rows:1');
select pg_temp.try('anon', 'same phone typed differently: still one request',
  $q$select public.request_stock_alert('SATEST-1', null, '+961 70-123456', '', 'en', '')$q$, 'rows:1');
select pg_temp.try('anon', '... one open request, name kept, language updated',
  $q$select 1 where pg_temp.n_open('SATEST-1') = 1$q$, 'rows:1');
select pg_temp.try('anon', 'ask for an option',
  $q$select public.request_stock_alert('SATEST-2', pg_temp.vid('Size S'), '03 111 222', null, 'en', '')$q$, 'rows:1');
select pg_temp.try('anon', 'product with options but no option chosen -> refused',
  $q$select public.request_stock_alert('SATEST-2', null, '03 111 222', null, 'en', '')$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('anon', 'option that is not available -> refused',
  $q$select public.request_stock_alert('SATEST-2', pg_temp.vid('Size XL'), '03 111 222', null, 'en', '')$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('anon', 'option of another product -> refused',
  $q$select public.request_stock_alert('SATEST-1', pg_temp.vid('Size S'), '03 111 222', null, 'en', '')$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('anon', 'hidden product -> refused',
  $q$select public.request_stock_alert('SATEST-3', null, '03 111 222', null, 'en', '')$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('anon', 'unknown product -> refused',
  $q$select public.request_stock_alert('NOPE-1', null, '03 111 222', null, 'en', '')$q$, 'error:P0001:ITEM_UNAVAILABLE');
select pg_temp.try('anon', 'not a Lebanese phone -> INVALID_PHONE',
  $q$select public.request_stock_alert('SATEST-1', null, '12345', null, 'en', '')$q$, 'error:P0001:INVALID_PHONE');
select pg_temp.try('anon', 'spam trap filled -> refused',
  $q$select public.request_stock_alert('SATEST-1', null, '70 555 555', null, 'en', 'http://spam')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('anon', 'name too long -> refused',
  $q$select public.request_stock_alert('SATEST-1', null, '70 555 555', repeat('x', 81), 'en', '')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('anon', 'bad language -> refused',
  $q$select public.request_stock_alert('SATEST-1', null, '70 555 555', null, 'fr', '')$q$, 'error:P0001:INVALID_INPUT');
select pg_temp.try('anon', '21st open request of one phone -> TOO_MANY_ALERTS',
  $q$select public.request_stock_alert('SATEST-1', null, '70 999 999', null, 'en', '')$q$, 'error:P0001:TOO_MANY_ALERTS');
select pg_temp.try('anon', 'cannot read requests', $q$select 1 from public.stock_alerts$q$, 'error:42501');
select pg_temp.try('anon', 'cannot add directly',
  $q$insert into public.stock_alerts (sku, phone) values ('SATEST-1', '+96170000001')$q$, 'error:42501');
select pg_temp.try('anon', 'cannot mark as done',
  $q$select public.staff_stock_alerts_done(array[1]::bigint[], true)$q$, 'error:42501');
select pg_temp.try('anon', 'the message setting is private',
  $q$select 1 from public.settings where key like 'whatsapp_back_%'$q$, 'rows:0');
reset role;

-- ---------- logged in, not staff ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d3'), true);
select pg_temp.try('nobody', 'sees no requests', $q$select 1 from public.stock_alerts$q$, 'rows:0');
select pg_temp.try('nobody', 'cannot mark as done',
  $q$select public.staff_stock_alerts_done(array[1]::bigint[], true)$q$, 'error:42501');
reset role;

-- ---------- OWNER ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d2'), true);
select pg_temp.try('owner', 'reads the requests (view only)', $q$select 1 from public.stock_alerts where sku like 'SATEST-%'$q$, 'rows:22');
select pg_temp.try('owner', 'cannot mark as done',
  $q$select public.staff_stock_alerts_done(array(select id from public.stock_alerts where sku = 'SATEST-1'), true)$q$, 'error:42501');
select pg_temp.try('owner', 'direct change refused (only reading is granted)',
  $q$update public.stock_alerts set notified_at = now() where sku = 'SATEST-1'$q$, 'error:42501');
reset role;

-- ---------- ADMIN ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d1'), true);
select pg_temp.try('admin', 'reads the requests with product and option names',
  $q$select 1 from public.stock_alerts a join public.products p on p.sku = a.sku left join public.variants v on v.id = a.variant_id
     where a.sku in ('SATEST-1', 'SATEST-2')$q$, 'rows:2');
select pg_temp.try('admin', 'request kept the first name, phone normalized, language now en',
  $q$select 1 from public.stock_alerts where sku = 'SATEST-1' and phone = '+96170123456' and name = 'Rita' and lang = 'en'$q$, 'rows:1');
select pg_temp.try('admin', 'mark SATEST-1 as notified',
  $q$select public.staff_stock_alerts_done(array(select id from public.stock_alerts where sku = 'SATEST-1'), true)$q$, 'rows:1');
select pg_temp.try('admin', '... date and admin saved',
  $q$select 1 from public.stock_alerts where sku = 'SATEST-1' and notified_at is not null and notified_by = '00000000-0000-4000-8000-0000000000d1'$q$, 'rows:1');
select pg_temp.try('admin', 'marking again changes nothing',
  $q$select 1 where public.staff_stock_alerts_done(array(select id from public.stock_alerts where sku = 'SATEST-1'), true) = 0$q$, 'rows:1');
select pg_temp.try('admin', 'empty list -> INVALID_INPUT',
  $q$select public.staff_stock_alerts_done(array[]::bigint[], true)$q$, 'error:P0001:INVALID_INPUT');
reset role;

-- the customer asks again after being told (a new open request is allowed)
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'ask again after being notified: allowed',
  $q$select public.request_stock_alert('SATEST-1', null, '70123456', null, 'ar', '')$q$, 'rows:1');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000d1'), true);
select pg_temp.try('admin', 'history kept: 1 notified + 1 open for that phone',
  $q$select 1 from public.stock_alerts where sku = 'SATEST-1' and phone = '+96170123456'$q$, 'rows:2');
select pg_temp.try('admin', 'undo "notified" while a new request is open: not reopened (no duplicate)',
  $q$select 1 where public.staff_stock_alerts_done(array(select id from public.stock_alerts where sku = 'SATEST-1' and notified_at is not null), false) = 0$q$, 'rows:1');
select pg_temp.try('admin', 'undo "notified" on the option request after marking it',
  $q$select 1 where public.staff_stock_alerts_done(array(select id from public.stock_alerts where sku = 'SATEST-2'), true) = 1
       and public.staff_stock_alerts_done(array(select id from public.stock_alerts where sku = 'SATEST-2'), false) = 1$q$, 'rows:1');
select pg_temp.try('admin', '... it is waiting again',
  $q$select 1 where pg_temp.n_open('SATEST-2') = 1$q$, 'rows:1');
select pg_temp.try('admin', 'can edit the WhatsApp message',
  $q$select 1 where public.admin_save_settings('{"whatsapp_back_en":"Hi {name}, {product} is back: {url}"}'::jsonb) = 1$q$, 'rows:1');
reset role;

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
