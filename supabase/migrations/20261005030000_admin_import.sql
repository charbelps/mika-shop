-- =====================================================================
-- Mika Shop: migration 6, bulk import (Phase 1, step 4).
--  * admin_import_products(rows): upsert products (+ variants) by SKU in
--    ONE transaction. ADMIN only. Stock changes are logged as IMPORT.
--    A key missing from a row = keep the current value (empty CSV cells
--    never erase data). Every imported product gets ar_needs_review = true.
--    Variants are matched by label_en and added/updated, never deleted.
--    Categories are given as "Parent > Child" (English names) and created
--    if missing.
--  * admin_add_photos(sku, paths): append photo paths to a product
--    (skips paths it already has). ADMIN only.
-- =====================================================================

-- Finds or creates a category from a path like "Clothes > T-shirts". Internal.
create or replace function public.import_category_path(p_path text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_part text;
  v_parent bigint := null;
  v_id bigint;
begin
  foreach v_part in array regexp_split_to_array(p_path, '\s*>\s*') loop
    v_part := trim(v_part);
    continue when v_part = '';
    select id into v_id from public.categories
      where lower(name_en) = lower(v_part) and parent_id is not distinct from v_parent
      order by id limit 1;
    if v_id is null then
      insert into public.categories (name_en, parent_id) values (v_part, v_parent) returning id into v_id;
    end if;
    v_parent := v_id;
    v_id := null;
  end loop;
  return v_parent;
end;
$$;
revoke all on function public.import_category_path(text) from public;


-- p_rows: [ { sku, name_en?, name_ar?, desc_en?, desc_ar?, category?, price?, compare_price?,
--             stock?, featured?, active?, variants?: [ { label_en, label_ar?, price?, stock? } ] } ]
create or replace function public.admin_import_products(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r jsonb;
  v jsonb;
  v_sku text;
  v_cat bigint;
  v_has_variants boolean;
  v_created int := 0;
  v_updated int := 0;
  v_var_created int := 0;
  v_var_updated int := 0;
  v_cats_before int;
  v_row int := 0;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can import products' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'ROWS_NOT_ARRAY' using errcode = 'P0001';
  end if;
  perform set_config('app.stock_reason', 'IMPORT', true);
  select count(*) into v_cats_before from public.categories;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_row := v_row + 1;
    v_sku := trim(r->>'sku');
    v_cat := case when nullif(trim(r->>'category'), '') is not null
                  then public.import_category_path(r->>'category') end;
    v_has_variants := jsonb_array_length(coalesce(r->'variants', '[]'::jsonb)) > 0;

    begin
      if not exists (select 1 from public.products where sku = v_sku) then
        insert into public.products (sku, name_en, name_ar, desc_en, desc_ar, category_id, price,
          compare_price, stock, has_variants, featured, active, ar_needs_review)
        values (
          v_sku,
          trim(r->>'name_en'),
          coalesce(trim(r->>'name_ar'), ''),
          coalesce(r->>'desc_en', ''),
          coalesce(r->>'desc_ar', ''),
          v_cat,
          (r->>'price')::numeric,
          nullif(r->>'compare_price', '')::numeric,
          case when v_has_variants then 0 else coalesce(nullif(r->>'stock', '')::integer, 0) end,
          v_has_variants,
          coalesce((r->>'featured')::boolean, false),
          coalesce((r->>'active')::boolean, true),
          true
        );
        v_created := v_created + 1;
      else
        update public.products p set
          name_en       = case when r ? 'name_en' then trim(r->>'name_en') else p.name_en end,
          name_ar       = case when r ? 'name_ar' then trim(r->>'name_ar') else p.name_ar end,
          desc_en       = case when r ? 'desc_en' then r->>'desc_en' else p.desc_en end,
          desc_ar       = case when r ? 'desc_ar' then r->>'desc_ar' else p.desc_ar end,
          category_id   = case when r ? 'category' then v_cat else p.category_id end,
          price         = case when r ? 'price' then (r->>'price')::numeric else p.price end,
          compare_price = case when r ? 'compare_price' then nullif(r->>'compare_price', '')::numeric else p.compare_price end,
          stock         = case when r ? 'stock' and not v_has_variants then (r->>'stock')::integer else p.stock end,
          has_variants  = p.has_variants or v_has_variants,
          featured      = case when r ? 'featured' then (r->>'featured')::boolean else p.featured end,
          active        = case when r ? 'active' then (r->>'active')::boolean else p.active end,
          ar_needs_review = true
        where p.sku = v_sku;
        v_updated := v_updated + 1;
      end if;

      for v in select * from jsonb_array_elements(coalesce(r->'variants', '[]'::jsonb)) loop
        update public.variants x set
          label_ar = case when v ? 'label_ar' then trim(v->>'label_ar') else x.label_ar end,
          price    = case when v ? 'price' then nullif(v->>'price', '')::numeric else x.price end,
          stock    = case when v ? 'stock' then (v->>'stock')::integer else x.stock end
        where x.sku = v_sku and lower(x.label_en) = lower(trim(v->>'label_en'));
        if found then
          v_var_updated := v_var_updated + 1;
        else
          insert into public.variants (sku, label_en, label_ar, price, stock, sort)
          values (v_sku, trim(v->>'label_en'), coalesce(trim(v->>'label_ar'), ''),
                  nullif(v->>'price', '')::numeric, coalesce(nullif(v->>'stock', '')::integer, 0),
                  (select coalesce(max(sort), 0) + 1 from public.variants where sku = v_sku));
          v_var_created := v_var_created + 1;
        end if;
      end loop;
    exception when others then
      -- Stop the whole import (everything rolls back) and say which row failed.
      raise exception 'IMPORT_ROW_FAILED row % (SKU %): %', v_row, v_sku, sqlerrm
        using errcode = 'P0001';
    end;
  end loop;

  return jsonb_build_object(
    'created', v_created,
    'updated', v_updated,
    'variants_created', v_var_created,
    'variants_updated', v_var_updated,
    'categories_created', (select count(*) from public.categories) - v_cats_before
  );
end;
$$;
revoke all on function public.admin_import_products(jsonb) from public;
grant execute on function public.admin_import_products(jsonb) to authenticated;


create or replace function public.admin_add_photos(p_sku text, p_paths text[])
returns text[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_photos text[];
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can add photos' using errcode = '42501';
  end if;
  update public.products p
    set photos = p.photos || coalesce(array(
      select x from unnest(p_paths) with ordinality as t(x, o)
      where x <> all (p.photos) and x like p_sku || '/%'
      order by o), '{}')
  where p.sku = p_sku
  returning p.photos into v_photos;
  if not found then
    raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0001', detail = p_sku;
  end if;
  return v_photos;
end;
$$;
revoke all on function public.admin_add_photos(text, text[]) from public;
grant execute on function public.admin_add_photos(text, text[]) to authenticated;
