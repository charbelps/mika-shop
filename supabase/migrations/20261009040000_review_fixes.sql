-- =====================================================================
-- Mika Shop: migration 25, fixes from the full review of 9 Oct 2026.
--  1. admin_save_product: the product editor sends the stock it loaded ("stock_seen", for the
--     product and each option). If an order changed the stock while Mika was editing:
--       * she didn't touch the stock field -> the current stock is kept (before: the old number
--         from the form was written back, so sold items came back = overselling);
--       * she changed it too -> STOCK_CHANGED (detail = SKU or option id), nothing is saved and
--         the editor asks her to check the number again.
--     Callers that don't send stock_seen (tests, older screens) work as before.
--  2. Visitors (anon) and logins (authenticated) keep only the table rights the site uses:
--     TRUNCATE / REFERENCES / TRIGGER / MAINTAIN are removed (Supabase's defaults gave them;
--     TRUNCATE ignores row security). Nothing on the site used them.
--  3. Row security rules ask "who is this?" once per query instead of once per row
--     ((select public.my_role()), (select auth.uid())): same rules, faster on big tables
--     (Supabase advisor "auth_rls_initplan"). Policies are changed in place, none removed.
-- =====================================================================

-- ---------- 1. product editor: never write back a stale stock ----------
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
  v_cur integer;
  v_stock integer;
  v_seen integer;
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
    -- lock the product first (same order as place_order: product, then its options)
    select stock into v_cur from public.products where sku = v_sku for update;
    if not found then
      raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0001', detail = v_sku;
    end if;
    v_stock := coalesce(nullif(p_product->>'stock', '')::integer, 0);
    v_seen := nullif(p_product->>'stock_seen', '')::integer;
    if v_seen is not null and v_cur <> v_seen then
      if v_stock = v_seen then
        v_stock := v_cur;   -- stock field untouched: keep what orders made of it
      else
        raise exception 'STOCK_CHANGED' using errcode = 'P0001', detail = v_sku;
      end if;
    end if;

    update public.products p set
      name_en         = trim(p_product->>'name_en'),
      name_ar         = coalesce(trim(p_product->>'name_ar'), ''),
      desc_en         = coalesce(p_product->>'desc_en', ''),
      desc_ar         = coalesce(p_product->>'desc_ar', ''),
      category_id     = nullif(p_product->>'category_id', '')::bigint,
      price           = (p_product->>'price')::numeric,
      compare_price   = nullif(p_product->>'compare_price', '')::numeric,
      stock           = v_stock,
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
  end if;

  for v in select * from jsonb_array_elements(coalesce(p_variants, '[]'::jsonb)) loop
    if nullif(v->>'id', '') is null then
      insert into public.variants (sku, label_en, label_ar, price, stock, active, sort)
      values (v_sku, trim(v->>'label_en'), coalesce(trim(v->>'label_ar'), ''),
              nullif(v->>'price', '')::numeric, coalesce(nullif(v->>'stock', '')::integer, 0),
              coalesce((v->>'active')::boolean, true), coalesce(nullif(v->>'sort', '')::integer, 0));
    else
      select stock into v_cur from public.variants
        where id = (v->>'id')::bigint and sku = v_sku for update;
      if not found then
        raise exception 'VARIANT_NOT_FOUND' using errcode = 'P0001', detail = v->>'id';
      end if;
      v_stock := coalesce(nullif(v->>'stock', '')::integer, 0);
      v_seen := nullif(v->>'stock_seen', '')::integer;
      if v_seen is not null and v_cur <> v_seen then
        if v_stock = v_seen then
          v_stock := v_cur;
        else
          raise exception 'STOCK_CHANGED' using errcode = 'P0001', detail = v->>'id';
        end if;
      end if;
      update public.variants set
        label_en = trim(v->>'label_en'),
        label_ar = coalesce(trim(v->>'label_ar'), ''),
        price    = nullif(v->>'price', '')::numeric,
        stock    = v_stock,
        active   = coalesce((v->>'active')::boolean, true),
        sort     = coalesce(nullif(v->>'sort', '')::integer, 0)
      where id = (v->>'id')::bigint and sku = v_sku;
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
revoke all on function public.admin_save_product(jsonb, jsonb, boolean) from public, anon;
grant execute on function public.admin_save_product(jsonb, jsonb, boolean) to authenticated;

-- ---------- 2. table rights the site never uses ----------
revoke truncate, references, trigger, maintain on all tables in schema public from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke truncate, references, trigger, maintain on tables from anon, authenticated;

-- ---------- 3. row security: evaluate the role once per query ----------
alter policy settings_read  on public.settings using (is_public or (select public.my_role()) is not null);
alter policy settings_admin on public.settings
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy staff_read_self on public.staff using (user_id = (select auth.uid()));
alter policy staff_admin on public.staff
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy categories_read  on public.categories using (active or (select public.my_role()) is not null);
alter policy categories_admin on public.categories
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy products_read  on public.products using (active or (select public.my_role()) is not null);
alter policy products_admin on public.products
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy variants_read on public.variants using (
  (active and exists (select 1 from public.products p where p.sku = variants.sku and p.active))
  or (select public.my_role()) is not null);
alter policy variants_admin on public.variants
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy zones_read  on public.delivery_zones using (active or (select public.my_role()) is not null);
alter policy zones_admin on public.delivery_zones
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy customers_owner_read on public.customers using ((select public.my_role()) = 'OWNER');
alter policy customers_admin on public.customers
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy orders_owner_read  on public.orders using ((select public.my_role()) = 'OWNER');
alter policy orders_driver_read on public.orders
  using ((select public.my_role()) = 'DRIVER' and driver_id = (select auth.uid()));
alter policy orders_driver_update on public.orders
  using ((select public.my_role()) = 'DRIVER' and driver_id = (select auth.uid()))
  with check ((select public.my_role()) = 'DRIVER' and driver_id = (select auth.uid()));
alter policy orders_admin on public.orders
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy order_items_owner_read  on public.order_items using ((select public.my_role()) = 'OWNER');
alter policy order_items_driver_read on public.order_items using (
  (select public.my_role()) = 'DRIVER'
  and exists (select 1 from public.orders o
              where o.id = order_items.order_id and o.driver_id = (select auth.uid())));
alter policy order_items_admin on public.order_items
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy stock_log_owner_read on public.stock_log using ((select public.my_role()) = 'OWNER');
alter policy stock_log_admin on public.stock_log
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');

alter policy push_own_read on public.push_subscriptions
  using (user_id = (select auth.uid()) and (select public.my_role()) is not null);
