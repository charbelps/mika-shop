-- =====================================================================
-- Mika Shop: search keywords + measurements (F1 + F5). ROLLED BACK.
-- Run:  supabase db query --linked -f supabase/tests/keywords_measurements_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to anon, authenticated;
grant all on sequence _r_n_seq to anon, authenticated;

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

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000007a1', 'kwtest-admin@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values ('00000000-0000-4000-8000-0000000007a1', 'KWTEST admin', 'ADMIN');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000007a1","role":"authenticated"}', true);

select pg_temp.try('admin creates product with keywords + measurements',
  $q$select public.admin_save_product('{"sku":"KW-1","name_en":"Table","price":"50","search_keywords":" tawle, tawleh ","measurements_en":"120 x 80 cm","measurements_ar":"١٢٠ × ٨٠ سم"}'::jsonb, '[]', true)$q$, 'KW-1');
select pg_temp.try('saved and trimmed',
  $q$select search_keywords || ' | ' || measurements_en || ' | ' || measurements_ar from public.products where sku = 'KW-1'$q$,
  'tawle, tawleh | 120 x 80 cm | ١٢٠ × ٨٠ سم');
-- (each change and its check are separate statements: one statement sees one snapshot)
select pg_temp.try('save from an older screen without the new keys',
  $q$select public.admin_save_product('{"sku":"KW-1","name_en":"Table v2","price":"55"}'::jsonb, '[]', false)$q$, 'KW-1');
select pg_temp.try('... keeps keywords + measurements',
  $q$select name_en || ' | ' || search_keywords || ' | ' || measurements_en from public.products where sku = 'KW-1'$q$,
  'Table v2 | tawle, tawleh | 120 x 80 cm');
select pg_temp.try('save with the keys emptied',
  $q$select public.admin_save_product('{"sku":"KW-1","name_en":"Table","price":"55","search_keywords":"","measurements_en":"","measurements_ar":""}'::jsonb, '[]', false)$q$, 'KW-1');
select pg_temp.try('... clears them',
  $q$select '[' || search_keywords || measurements_en || measurements_ar || ']' from public.products where sku = 'KW-1'$q$, '[]');

select pg_temp.try('import new product with keywords + measurements',
  $q$select (public.admin_import_products('[{"sku":"KW-2","name_en":"Chair","price":"20","search_keywords":"kursi, kirsi","measurements_en":"45 cm seat"}]'::jsonb) ->> 'created')$q$, '1');
select pg_temp.try('re-import with only a new price',
  $q$select public.admin_import_products('[{"sku":"KW-2","price":"22"}]'::jsonb) ->> 'updated'$q$, '1');
select pg_temp.try('... keeps keywords + measurements, price updated',
  $q$select search_keywords || ' | ' || measurements_en || ' | ' || price from public.products where sku = 'KW-2'$q$,
  'kursi, kirsi | 45 cm seat | 22.00');
select pg_temp.try('re-import with new keywords',
  $q$select public.admin_import_products('[{"sku":"KW-2","search_keywords":"kursi, kirsi, kursee"}]'::jsonb) ->> 'updated'$q$, '1');
select pg_temp.try('... replaces them',
  $q$select search_keywords from public.products where sku = 'KW-2'$q$, 'kursi, kirsi, kursee');
reset role;

-- what the shop does: a visitor searches name EN / name AR / keywords
update public.products set name_ar = 'كرسي' where sku = 'KW-2';
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select pg_temp.try('visitor search "kurs" finds the chair by keyword',
  $q$select string_agg(sku, ',') from public.products where active and (name_en ilike '%kurs%' or name_ar ilike '%kurs%' or search_keywords ilike '%kurs%')$q$, 'KW-2');
select pg_temp.try('visitor search "كرسي" finds it by Arabic name',
  $q$select string_agg(sku, ',') from public.products where active and (name_en ilike '%كرسي%' or name_ar ilike '%كرسي%' or search_keywords ilike '%كرسي%')$q$, 'KW-2');
select pg_temp.try('visitor can read measurements',
  $q$select measurements_en from public.products where sku = 'KW-2'$q$, '45 cm seat');
reset role;

select n, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
