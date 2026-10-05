-- =====================================================================
-- Mika Shop: migration 12, search keywords + measurements (Phase 1b, F1 + F5).
--  * products.search_keywords: optional extra words for search (Arabizi / other spellings,
--    e.g. "tawle, kursi, sajjade"). Not shown to customers, only searched.
--  * products.measurements_en / measurements_ar: optional size / measurements text,
--    shown on the product page.
--  * admin_save_product and admin_import_products replaced to handle the 3 new fields
--    (same behaviour as before otherwise; in imports a missing key keeps the current value).
-- =====================================================================

alter table public.products
  add column if not exists search_keywords text not null default '',
  add column if not exists measurements_en text not null default '',
  add column if not exists measurements_ar text not null default '';

comment on column public.products.search_keywords is 'Extra search words (Arabizi, other spellings). Searched, never displayed.';
comment on column public.products.measurements_en is 'Optional measurements / size text (English), shown on the product page.';


create or replace function public.admin_save_product(p_product jsonb, p_variants jsonb, p_is_new boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sku text := trim(p_product->>'sku');
  v jsonb;
  v_active_variants integer;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can save products' using errcode = '42501';
  end if;
  perform set_config('app.stock_reason', 'MANUAL', true);

  if p_is_new then
    begin
      insert into public.products (sku, name_en, name_ar, desc_en, desc_ar, category_id, price,
        compare_price, stock, has_variants, photos, featured, active, ar_needs_review,
        search_keywords, measurements_en, measurements_ar)
      values (
        v_sku,
        trim(p_product->>'name_en'),
        coalesce(trim(p_product->>'name_ar'), ''),
        coalesce(p_product->>'desc_en', ''),
        coalesce(p_product->>'desc_ar', ''),
        nullif(p_product->>'category_id', '')::bigint,
        (p_product->>'price')::numeric,
        nullif(p_product->>'compare_price', '')::numeric,
        coalesce(nullif(p_product->>'stock', '')::integer, 0),
        coalesce((p_product->>'has_variants')::boolean, false),
        coalesce(array(select jsonb_array_elements_text(p_product->'photos')), '{}'),
        coalesce((p_product->>'featured')::boolean, false),
        coalesce((p_product->>'active')::boolean, true),
        coalesce((p_product->>'ar_needs_review')::boolean, false),
        coalesce(trim(p_product->>'search_keywords'), ''),
        coalesce(trim(p_product->>'measurements_en'), ''),
        coalesce(trim(p_product->>'measurements_ar'), '')
      );
    exception when unique_violation then
      raise exception 'SKU_EXISTS' using errcode = 'P0001', detail = v_sku;
    end;
  else
    update public.products p set
      name_en         = trim(p_product->>'name_en'),
      name_ar         = coalesce(trim(p_product->>'name_ar'), ''),
      desc_en         = coalesce(p_product->>'desc_en', ''),
      desc_ar         = coalesce(p_product->>'desc_ar', ''),
      category_id     = nullif(p_product->>'category_id', '')::bigint,
      price           = (p_product->>'price')::numeric,
      compare_price   = nullif(p_product->>'compare_price', '')::numeric,
      stock           = coalesce(nullif(p_product->>'stock', '')::integer, 0),
      has_variants    = coalesce((p_product->>'has_variants')::boolean, false),
      photos          = coalesce(array(select jsonb_array_elements_text(p_product->'photos')), '{}'),
      featured        = coalesce((p_product->>'featured')::boolean, false),
      active          = coalesce((p_product->>'active')::boolean, true),
      ar_needs_review = coalesce((p_product->>'ar_needs_review')::boolean, false),
      -- older screens that don't send these keys keep the current values
      search_keywords = case when p_product ? 'search_keywords' then coalesce(trim(p_product->>'search_keywords'), '') else p.search_keywords end,
      measurements_en = case when p_product ? 'measurements_en' then coalesce(trim(p_product->>'measurements_en'), '') else p.measurements_en end,
      measurements_ar = case when p_product ? 'measurements_ar' then coalesce(trim(p_product->>'measurements_ar'), '') else p.measurements_ar end
    where p.sku = v_sku;
    if not found then
      raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0001', detail = v_sku;
    end if;
  end if;

  for v in select * from jsonb_array_elements(coalesce(p_variants, '[]'::jsonb)) loop
    if nullif(v->>'id', '') is null then
      insert into public.variants (sku, label_en, label_ar, price, stock, active, sort)
      values (v_sku, trim(v->>'label_en'), coalesce(trim(v->>'label_ar'), ''),
              nullif(v->>'price', '')::numeric, coalesce(nullif(v->>'stock', '')::integer, 0),
              coalesce((v->>'active')::boolean, true), coalesce(nullif(v->>'sort', '')::integer, 0));
    else
      update public.variants set
        label_en = trim(v->>'label_en'),
        label_ar = coalesce(trim(v->>'label_ar'), ''),
        price    = nullif(v->>'price', '')::numeric,
        stock    = coalesce(nullif(v->>'stock', '')::integer, 0),
        active   = coalesce((v->>'active')::boolean, true),
        sort     = coalesce(nullif(v->>'sort', '')::integer, 0)
      where id = (v->>'id')::bigint and sku = v_sku;
      if not found then
        raise exception 'VARIANT_NOT_FOUND' using errcode = 'P0001', detail = v->>'id';
      end if;
    end if;
  end loop;

  if coalesce((p_product->>'has_variants')::boolean, false) then
    select count(*) into v_active_variants from public.variants where sku = v_sku and active;
    if v_active_variants = 0 then
      raise exception 'NEEDS_VARIANT' using errcode = 'P0001';
    end if;
  end if;

  return v_sku;
end;
$$;
revoke all on function public.admin_save_product(jsonb, jsonb, boolean) from public;
grant execute on function public.admin_save_product(jsonb, jsonb, boolean) to authenticated;


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
          compare_price, stock, has_variants, featured, active, ar_needs_review,
          search_keywords, measurements_en, measurements_ar)
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
          true,
          coalesce(trim(r->>'search_keywords'), ''),
          coalesce(trim(r->>'measurements_en'), ''),
          coalesce(trim(r->>'measurements_ar'), '')
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
          search_keywords = case when r ? 'search_keywords' then trim(r->>'search_keywords') else p.search_keywords end,
          measurements_en = case when r ? 'measurements_en' then trim(r->>'measurements_en') else p.measurements_en end,
          measurements_ar = case when r ? 'measurements_ar' then trim(r->>'measurements_ar') else p.measurements_ar end,
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
