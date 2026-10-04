-- =====================================================================
-- Mika Shop: bulk import test (10 items, then 100 items, re-import,
-- variants, a bad row, permissions, photos). ROLLED BACK.
-- Run:  supabase db query --linked -f supabase/tests/import_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to authenticated, anon;
grant all on sequence _r_n_seq to authenticated, anon;

create function pg_temp.try(p_test text, p_sql text, p_expected text)
returns void language plpgsql as $$
declare v_got text;
begin
  begin
    execute p_sql into v_got;
  exception when others then
    v_got := 'error:' || sqlstate || case when sqlstate = 'P0001' then ':' || split_part(sqlerrm, ':', 1) else '' end;
  end;
  insert into pg_temp._r (test, expected, got) values (p_test, p_expected, coalesce(v_got, 'null'));
end $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000d1', 'importtest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000d2', 'importtest-owner@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000d1', 'IMPORTTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000d2', 'IMPORTTEST owner', 'OWNER');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000d1","role":"authenticated"}', true);

-- 10 items, 2 new nested categories
select pg_temp.try('import 10 new items',
  $q$select public.admin_import_products((select jsonb_agg(jsonb_build_object(
      'sku', 'IMPT-' || i, 'name_en', 'Import item ' || i, 'name_ar', 'منتج ' || i,
      'category', 'IMPORTTEST Home > IMPORTTEST Lamps', 'price', (i * 1.5)::text, 'stock', i::text))
     from generate_series(1, 10) i))::text$q$,
  '{"created": 10, "updated": 0, "variants_created": 0, "variants_updated": 0, "categories_created": 2}');
select pg_temp.try('10 items in DB, all Arabic-review',
  $q$select count(*)::text from public.products where sku like 'IMPT-%' and ar_needs_review$q$, '10');
select pg_temp.try('nested category: Lamps inside Home',
  $q$select count(*)::text from public.categories c join public.categories p on p.id = c.parent_id where c.name_en = 'IMPORTTEST Lamps' and p.name_en = 'IMPORTTEST Home'$q$, '1');
select pg_temp.try('stock logged as IMPORT (10 rows, total 55)',
  $q$select count(*) || '/' || sum(change) from public.stock_log where sku like 'IMPT-%' and reason = 'IMPORT' and by_user = '00000000-0000-4000-8000-0000000000d1'$q$, '10/55');

-- 100 items
select pg_temp.try('import 100 new items',
  $q$select (public.admin_import_products((select jsonb_agg(jsonb_build_object(
      'sku', 'IMPH-' || lpad(i::text, 3, '0'), 'name_en', 'Bulk item ' || i, 'price', '2', 'stock', '1',
      'category', 'importtest home'))
     from generate_series(1, 100) i)) ->> 'created')$q$, '100');
select pg_temp.try('category matched case-insensitively (no duplicate)',
  $q$select count(*)::text from public.categories where lower(name_en) = 'importtest home'$q$, '1');

-- re-import: only price given -> other fields kept
select pg_temp.try('re-import 10 with price only',
  $q$select (public.admin_import_products((select jsonb_agg(jsonb_build_object('sku', 'IMPT-' || i, 'price', '99'))
     from generate_series(1, 10) i)) ->> 'updated')$q$, '10');
select pg_temp.try('names/stock/category kept, price updated',
  $q$select count(*)::text from public.products p join public.categories c on c.id = p.category_id
     where p.sku like 'IMPT-%' and p.price = 99 and p.name_en like 'Import item %' and p.name_ar like 'منتج %' and c.name_en = 'IMPORTTEST Lamps' and p.stock > 0$q$, '10');

-- variants
select pg_temp.try('import product with 2 variants',
  $q$select (public.admin_import_products('[{"sku":"IMPV-1","name_en":"Shirt","price":"10","stock":"50","variants":[{"label_en":"Size S","label_ar":"صغير","stock":"3"},{"label_en":"Size M","stock":"4","price":"12"}]}]'::jsonb) ->> 'variants_created')$q$, '2');
select pg_temp.try('variant product: has_variants, product stock 0',
  $q$select (has_variants and stock = 0)::text from public.products where sku = 'IMPV-1'$q$, 'true');
select pg_temp.try('re-import: "size s" updates, "Size L" is new',
  $q$select (r ->> 'variants_updated') || '/' || (r ->> 'variants_created') from public.admin_import_products('[{"sku":"IMPV-1","variants":[{"label_en":"size s","stock":"9"},{"label_en":"Size L","stock":"1"}]}]'::jsonb) r$q$, '1/1');
select pg_temp.try('variants now: S=9 (Arabic kept), M=4, L=1',
  $q$select string_agg(label_en || '=' || stock || coalesce(':' || nullif(label_ar, ''), ''), ',' order by sort) from public.variants where sku = 'IMPV-1'$q$, 'Size S=9:صغير,Size M=4,Size L=1');

-- a bad row stops the whole batch
select pg_temp.try('batch with bad row 3 (negative price) -> error',
  $q$select public.admin_import_products('[{"sku":"IMPB-1","name_en":"a","price":"1"},{"sku":"IMPB-2","name_en":"b","price":"1"},{"sku":"IMPB-3","name_en":"c","price":"-5"}]'::jsonb)::text$q$,
  'error:P0001:IMPORT_ROW_FAILED row 3 (SKU IMPB-3)');
select pg_temp.try('nothing from the bad batch was saved',
  $q$select count(*)::text from public.products where sku like 'IMPB-%'$q$, '0');
select pg_temp.try('missing name for a new SKU -> error',
  $q$select public.admin_import_products('[{"sku":"IMPB-9","price":"1"}]'::jsonb)::text$q$,
  'error:P0001:IMPORT_ROW_FAILED row 1 (SKU IMPB-9)');

-- photos
select pg_temp.try('add 2 photos',
  $q$select array_length(public.admin_add_photos('IMPT-1', array['IMPT-1/import-1.jpg', 'IMPT-1/import-2.jpg']), 1)::text$q$, '2');
select pg_temp.try('add again + 1 new + 1 of another SKU -> only the new one added',
  $q$select array_to_string(public.admin_add_photos('IMPT-1', array['IMPT-1/import-2.jpg', 'IMPT-1/import-3.jpg', 'IMPT-2/import-1.jpg']), ',')$q$,
  'IMPT-1/import-1.jpg,IMPT-1/import-2.jpg,IMPT-1/import-3.jpg');
select pg_temp.try('photos for unknown SKU -> PRODUCT_NOT_FOUND',
  $q$select public.admin_add_photos('NOPE-1', array['NOPE-1/a.jpg'])::text$q$, 'error:P0001:PRODUCT_NOT_FOUND');
reset role;

-- permissions
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000d2","role":"authenticated"}', true);
select pg_temp.try('OWNER import -> refused',
  $q$select public.admin_import_products('[{"sku":"IMPX-1","name_en":"x","price":"1"}]'::jsonb)::text$q$, 'error:42501');
select pg_temp.try('OWNER add photos -> refused',
  $q$select public.admin_add_photos('IMPT-1', array['IMPT-1/x.jpg'])::text$q$, 'error:42501');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.try('anon import -> refused',
  $q$select public.admin_import_products('[]'::jsonb)::text$q$, 'error:42501');
select pg_temp.try('anon category helper -> refused',
  $q$select public.import_category_path('x')::text$q$, 'error:42501');
reset role;

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
