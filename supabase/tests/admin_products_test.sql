-- =====================================================================
-- Mika Shop: admin_save_product + stock_log trigger test. ROLLED BACK.
-- Run:  supabase db query --linked -f supabase/tests/admin_products_test.sql
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

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000b1', 'admintest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000b2', 'admintest-owner@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000b1', 'ADMINTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000b2', 'ADMINTEST owner', 'OWNER');

-- ---------- ADMIN ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000b1'), true);

select pg_temp.try('admin', 'add category',
  $q$insert into public.categories (name_en, name_ar, sort) values ('ADMINTEST cat', 'فئة', 1)$q$, 'rows:1');
select pg_temp.try('admin', 'create simple product (stock 5)',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-1","name_en":"Mug","name_ar":"كوب","price":"12.50","stock":"5","photos":["ADMINTEST-1/a.jpg"]}'::jsonb, '[]'::jsonb, true)$q$, 'rows:1');
select pg_temp.try('admin', 'stock_log +5 MANUAL by admin',
  $q$select 1 from public.stock_log where sku = 'ADMINTEST-1' and change = 5 and stock_after = 5 and reason = 'MANUAL' and by_user = '00000000-0000-4000-8000-0000000000b1' and variant_id is null$q$, 'rows:1');
select pg_temp.try('admin', 'update stock 5 -> 3',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-1","name_en":"Mug","price":"12.50","stock":"3"}'::jsonb, '[]'::jsonb, false)$q$, 'rows:1');
select pg_temp.try('admin', 'stock_log -2, after 3',
  $q$select 1 from public.stock_log where sku = 'ADMINTEST-1' and change = -2 and stock_after = 3$q$, 'rows:1');
select pg_temp.try('admin', 'save without stock change -> no new log',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-1","name_en":"Mug v2","price":"13","stock":"3"}'::jsonb, '[]'::jsonb, false)$q$, 'rows:1');
select pg_temp.try('admin', 'still exactly 2 log rows',
  $q$select 1 from public.stock_log where sku = 'ADMINTEST-1'$q$, 'rows:2');
select pg_temp.try('admin', 'photos saved, name updated',
  $q$select 1 from public.products where sku = 'ADMINTEST-1' and name_en = 'Mug v2' and price = 13 and photos = '{}'$q$, 'rows:1');
select pg_temp.try('admin', 'create product with 2 variants',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-2","name_en":"Shirt","price":"20","has_variants":true}'::jsonb,
     '[{"label_en":"Size S","label_ar":"صغير","stock":"4"},{"label_en":"Size M","price":"22","stock":"6"}]'::jsonb, true)$q$, 'rows:1');
select pg_temp.try('admin', '2 variant log rows',
  $q$select 1 from public.stock_log l join public.variants v on v.id = l.variant_id where v.sku = 'ADMINTEST-2'$q$, 'rows:2');
select pg_temp.try('admin', 'variant price null = product price',
  $q$select 1 from public.variants where sku = 'ADMINTEST-2' and label_en = 'Size S' and price is null$q$, 'rows:1');
select pg_temp.try('admin', 'edit variant stock 4 -> 1, deactivate M',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-2","name_en":"Shirt","price":"20","has_variants":true}'::jsonb,
     (select jsonb_agg(jsonb_build_object('id', id, 'label_en', label_en, 'stock', case when label_en = 'Size S' then 1 else stock end, 'active', label_en = 'Size S')) from public.variants where sku = 'ADMINTEST-2'), false)$q$, 'rows:1');
select pg_temp.try('admin', 'variant log -3',
  $q$select 1 from public.stock_log l join public.variants v on v.id = l.variant_id where v.sku = 'ADMINTEST-2' and l.change = -3 and l.stock_after = 1$q$, 'rows:1');
select pg_temp.try('admin', 'deactivating all variants -> NEEDS_VARIANT',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-2","name_en":"Shirt","price":"20","has_variants":true}'::jsonb,
     (select jsonb_agg(jsonb_build_object('id', id, 'label_en', label_en, 'stock', stock, 'active', false)) from public.variants where sku = 'ADMINTEST-2'), false)$q$, 'error:P0001:NEEDS_VARIANT');
select pg_temp.try('admin', 'has_variants with none -> NEEDS_VARIANT',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-3","name_en":"X","price":"1","has_variants":true}'::jsonb, '[]'::jsonb, true)$q$, 'error:P0001:NEEDS_VARIANT');
select pg_temp.try('admin', 'duplicate SKU -> SKU_EXISTS',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-1","name_en":"Dup","price":"1"}'::jsonb, '[]'::jsonb, true)$q$, 'error:P0001:SKU_EXISTS');
select pg_temp.try('admin', 'bad SKU (space) -> check violation',
  $q$select public.admin_save_product('{"sku":"BAD SKU","name_en":"X","price":"1"}'::jsonb, '[]'::jsonb, true)$q$, 'error:23514');
select pg_temp.try('admin', 'negative price -> check violation',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-4","name_en":"X","price":"-1"}'::jsonb, '[]'::jsonb, true)$q$, 'error:23514');
select pg_temp.try('admin', 'negative stock -> check violation',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-4","name_en":"X","price":"1","stock":"-2"}'::jsonb, '[]'::jsonb, true)$q$, 'error:23514');
select pg_temp.try('admin', 'update missing product -> PRODUCT_NOT_FOUND',
  $q$select public.admin_save_product('{"sku":"NOPE-404","name_en":"X","price":"1"}'::jsonb, '[]'::jsonb, false)$q$, 'error:P0001:PRODUCT_NOT_FOUND');
select pg_temp.try('admin', 'other product''s variant id -> VARIANT_NOT_FOUND',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-1","name_en":"Mug","price":"1"}'::jsonb,
     (select jsonb_build_array(jsonb_build_object('id', min(id), 'label_en', 'hack')) from public.variants where sku = 'ADMINTEST-2'), false)$q$, 'error:P0001:VARIANT_NOT_FOUND');
select pg_temp.try('admin', 'failed save left no half product',
  $q$select 1 from public.products where sku in ('ADMINTEST-3', 'ADMINTEST-4')$q$, 'rows:0');
reset role;

-- ---------- OWNER ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000b2'), true);
select pg_temp.try('owner', 'save product -> refused',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-1","name_en":"Hacked","price":"0"}'::jsonb, '[]'::jsonb, false)$q$, 'error:42501');
select pg_temp.try('owner', 'reads stock_log', $q$select 1 from public.stock_log where sku like 'ADMINTEST-%'$q$, 'rows:5');
reset role;

-- ---------- anon ----------
set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'save product -> refused',
  $q$select public.admin_save_product('{"sku":"ADMINTEST-1","name_en":"Hacked","price":"0"}'::jsonb, '[]'::jsonb, false)$q$, 'error:42501');
select pg_temp.try('anon', 'sees active variant only',
  $q$select 1 from public.variants where sku = 'ADMINTEST-2'$q$, 'rows:1');
reset role;

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
