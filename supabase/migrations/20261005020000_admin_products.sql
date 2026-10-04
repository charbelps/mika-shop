-- =====================================================================
-- Mika Shop: migration 4, admin product tools (Phase 1, step 3).
--  * log_stock_change trigger: EVERY change of products.stock / variants.stock
--    writes a stock_log row automatically (reason from the transaction
--    setting app.stock_reason, default MANUAL; order from app.stock_order_id).
--  * admin_save_product(): saves a product and its variants in ONE
--    transaction. ADMIN only. Variants are never deleted, only deactivated.
-- =====================================================================

create or replace function public.log_stock_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_change integer;
begin
  if tg_op = 'INSERT' then
    v_change := new.stock;
  else
    v_change := new.stock - old.stock;
  end if;
  if v_change is null or v_change = 0 then
    return new;
  end if;

  insert into public.stock_log (sku, variant_id, change, stock_after, reason, order_id, by_user)
  values (
    new.sku,
    case when tg_table_name = 'variants' then new.id end,
    v_change,
    new.stock,
    coalesce(nullif(current_setting('app.stock_reason', true), ''), 'MANUAL'),
    nullif(current_setting('app.stock_order_id', true), '')::bigint,
    auth.uid()
  );
  return new;
end;
$$;
revoke all on function public.log_stock_change() from public;

create trigger products_stock_log after insert or update of stock on public.products
  for each row execute function public.log_stock_change();
create trigger variants_stock_log after insert or update of stock on public.variants
  for each row execute function public.log_stock_change();


-- p_product: { sku, name_en, name_ar, desc_en, desc_ar, category_id, price, compare_price,
--              stock, has_variants, photos[], featured, active, ar_needs_review }
-- p_variants: [ { id|null, label_en, label_ar, price|null, stock, active, sort } ]
-- p_is_new: true = create (fails if the SKU exists), false = update an existing product.
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
        compare_price, stock, has_variants, photos, featured, active, ar_needs_review)
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
        coalesce((p_product->>'ar_needs_review')::boolean, false)
      );
    exception when unique_violation then
      raise exception 'SKU_EXISTS' using errcode = 'P0001', detail = v_sku;
    end;
  else
    update public.products set
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
      ar_needs_review = coalesce((p_product->>'ar_needs_review')::boolean, false)
    where sku = v_sku;
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
