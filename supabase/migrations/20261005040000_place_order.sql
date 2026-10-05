-- =====================================================================
-- Mika Shop: migration 7, placing orders (Phase 1, step 7).
--  * normalize_phone(text): any Lebanese format -> '+961' + 7/8 digits, or null.
--  * order_items.label_ar (additive): the option name in Arabic, copied at order time.
--  * order_no_seq: running order numbers from 10001 (order_no = order_prefix || number).
--  * place_order(): the ONLY way the shop creates orders. One transaction:
--    validate -> normalize phone -> lock product/variant rows (FOR UPDATE, fixed order)
--    -> check stock -> prices from the database, fee from delivery_zones -> insert order
--    + items -> decrement stock (logged as SALE by the stock trigger) -> upsert customer
--    -> return order number, totals and payment instructions.
--    Errors are short codes (INVALID_INPUT, INVALID_PHONE, ZONE_NOT_FOUND,
--    ZONE_FEE_NOT_SET, EMPTY_CART, TOO_MANY_ITEMS, ITEM_UNAVAILABLE, OUT_OF_STOCK,
--    PAYMENT_NOT_AVAILABLE) with the SKU in the error detail where relevant.
-- =====================================================================

create or replace function public.normalize_phone(p_raw text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  s text;
begin
  if p_raw is null then return null; end if;
  -- Arabic-Indic and Persian digits -> 0-9, then drop spaces, dashes, dots, brackets, slashes
  s := translate(p_raw, '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
  s := regexp_replace(s, '[\s\-().\/]', '', 'g');
  if s like '+%' then
    if s not like '+961%' then return null; end if;
    s := substr(s, 5);
  elsif s like '00961%' then
    s := substr(s, 6);
  elsif s like '961%' and length(s) >= 10 then
    s := substr(s, 4);
  end if;
  if s like '0%' then s := substr(s, 2); end if;
  if s ~ '^[0-9]{7,8}$' then return '+961' || s; end if;
  return null;
end;
$$;
revoke all on function public.normalize_phone(text) from public;
grant execute on function public.normalize_phone(text) to anon, authenticated;

alter table public.order_items add column if not exists label_ar text;

create sequence if not exists public.order_no_seq start with 10001;


create or replace function public.place_order(
  p_customer jsonb,
  p_items jsonb,
  p_payment text,
  p_honeypot text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name     text := trim(coalesce(p_customer->>'name', ''));
  v_town     text := trim(coalesce(p_customer->>'town', ''));
  v_address  text := trim(coalesce(p_customer->>'address', ''));
  v_landmark text := nullif(trim(coalesce(p_customer->>'landmark', '')), '');
  v_loc      text := nullif(trim(coalesce(p_customer->>'location_url', '')), '');
  v_phone    text;
  v_zone     public.delivery_zones;
  v_settings jsonb;
  v_line     record;
  v_product  public.products;
  v_variant  public.variants;
  v_price    numeric(10,2);
  v_subtotal numeric(10,2) := 0;
  v_order_id bigint;
  v_order_no text;
  v_total    numeric(10,2);
  v_items    jsonb := '[]'::jsonb;
  v_lines    int;
begin
  -- ---- 1. validate ----
  if coalesce(trim(p_honeypot), '') <> '' then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';  -- spam trap filled: say nothing more
  end if;
  if length(v_name) not between 1 and 80 or length(v_town) not between 1 and 80
     or length(v_address) not between 1 and 300 or length(coalesce(v_landmark, '')) > 150
     or length(coalesce(v_loc, '')) > 500 or (v_loc is not null and v_loc !~* '^https?://\S+$')
     or p_payment is null or p_payment not in ('COD', 'WHISH', 'OMT')
     or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;

  v_phone := public.normalize_phone(p_customer->>'phone');
  if v_phone is null then
    raise exception 'INVALID_PHONE' using errcode = 'P0001';
  end if;

  select jsonb_object_agg(key, value) into v_settings from public.settings;
  if p_payment = 'WHISH' and coalesce(trim(v_settings->>'whish_number'), '') = ''
     or p_payment = 'OMT' and coalesce(trim(v_settings->>'omt_details'), '') = '' then
    raise exception 'PAYMENT_NOT_AVAILABLE' using errcode = 'P0001';
  end if;

  select * into v_zone from public.delivery_zones
    where id = (case when (p_customer->>'zone_id') ~ '^[0-9]{1,9}$' then (p_customer->>'zone_id')::bigint end)
      and active;
  if not found then
    raise exception 'ZONE_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_zone.fee is null then
    raise exception 'ZONE_FEE_NOT_SET' using errcode = 'P0001';
  end if;

  -- ---- 2. items: merge duplicates, check quantities ----
  create temp table if not exists _po_lines (sku text, variant_id bigint, qty int) on commit drop;
  truncate _po_lines;
  begin
    insert into _po_lines (sku, variant_id, qty)
    select trim(e->>'sku'), nullif(e->>'variant_id', '')::bigint, sum((e->>'qty')::int)
    from jsonb_array_elements(p_items) e
    group by 1, 2;
  exception when others then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end;
  select count(*) into v_lines from _po_lines;
  if v_lines = 0 then
    raise exception 'EMPTY_CART' using errcode = 'P0001';
  end if;
  if v_lines > 50 then
    raise exception 'TOO_MANY_ITEMS' using errcode = 'P0001';
  end if;
  if exists (select 1 from _po_lines where qty is null or qty < 1 or qty > 99 or sku is null or sku = '') then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;

  -- ---- 3. lock rows in a fixed order, check stock, price from the database ----
  for v_line in select * from _po_lines order by sku, variant_id nulls first loop
    select * into v_product from public.products where sku = v_line.sku for update;
    if not found or not v_product.active then
      raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001', detail = v_line.sku;
    end if;
    if v_line.variant_id is null then
      if v_product.has_variants then
        raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001', detail = v_line.sku;
      end if;
      if v_product.stock < v_line.qty then
        raise exception 'OUT_OF_STOCK' using errcode = 'P0001', detail = v_line.sku;
      end if;
      v_price := v_product.price;
      v_variant := null;
    else
      select * into v_variant from public.variants
        where id = v_line.variant_id and sku = v_line.sku for update;
      if not found or not v_variant.active or not v_product.has_variants then
        raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001', detail = v_line.sku;
      end if;
      if v_variant.stock < v_line.qty then
        raise exception 'OUT_OF_STOCK' using errcode = 'P0001', detail = v_line.sku;
      end if;
      v_price := coalesce(v_variant.price, v_product.price);
    end if;
    v_subtotal := v_subtotal + v_price * v_line.qty;
    v_items := v_items || jsonb_build_object(
      'sku', v_product.sku, 'variant_id', v_line.variant_id, 'qty', v_line.qty,
      'name_en', v_product.name_en, 'name_ar', v_product.name_ar,
      'label', v_variant.label_en, 'label_ar', v_variant.label_ar,
      'unit_price', v_price, 'line_total', v_price * v_line.qty);
  end loop;

  v_total := v_subtotal + v_zone.fee;

  -- ---- 4. create the order ----
  v_order_no := coalesce(trim(v_settings->>'order_prefix'), '') || nextval('public.order_no_seq');
  insert into public.orders (order_no, phone, name, governorate, district, town, address, landmark,
    location_url, subtotal, delivery_fee, total, payment_method, payment_status, status, carrier)
  values (v_order_no, v_phone, v_name, v_zone.governorate, v_zone.district, v_town, v_address, v_landmark,
    v_loc, v_subtotal, v_zone.fee, v_total, p_payment,
    case when p_payment = 'COD' then 'UNPAID' else 'AWAITING' end, 'NEW', v_zone.default_carrier)
  returning id into v_order_id;

  insert into public.order_items (order_id, sku, variant_id, name_en, name_ar, label, label_ar, qty, unit_price, line_total)
  select v_order_id, i->>'sku', nullif(i->>'variant_id', '')::bigint, i->>'name_en', coalesce(i->>'name_ar', ''),
         i->>'label', i->>'label_ar', (i->>'qty')::int, (i->>'unit_price')::numeric, (i->>'line_total')::numeric
  from jsonb_array_elements(v_items) i;

  -- ---- 5. take the stock (the trigger writes stock_log as SALE with this order) ----
  perform set_config('app.stock_reason', 'SALE', true);
  perform set_config('app.stock_order_id', v_order_id::text, true);
  update public.products p set stock = p.stock - l.qty
    from _po_lines l where l.variant_id is null and p.sku = l.sku;
  update public.variants v set stock = v.stock - l.qty
    from _po_lines l where l.variant_id is not null and v.id = l.variant_id;
  perform set_config('app.stock_order_id', '', true);

  -- ---- 6. remember the customer (phone = customer ID) ----
  insert into public.customers (phone, name, governorate, district, town, address, landmark, location_url,
                                first_order_at, orders_count, total_spent)
  values (v_phone, v_name, v_zone.governorate, v_zone.district, v_town, v_address, v_landmark, v_loc, now(), 1, v_total)
  on conflict (phone) do update set
    name = excluded.name, governorate = excluded.governorate, district = excluded.district,
    town = excluded.town, address = excluded.address, landmark = excluded.landmark,
    location_url = excluded.location_url,
    orders_count = public.customers.orders_count + 1,
    total_spent = public.customers.total_spent + excluded.total_spent;

  -- ---- 7. answer the shop ----
  return jsonb_build_object(
    'order_no', v_order_no,
    'created_at', now(),
    'subtotal', v_subtotal,
    'delivery_fee', v_zone.fee,
    'total', v_total,
    'eta_days', v_zone.eta_days,
    'payment_method', p_payment,
    'payment_status', case when p_payment = 'COD' then 'UNPAID' else 'AWAITING' end,
    'whish_number', case when p_payment = 'WHISH' then v_settings->>'whish_number' end,
    'omt_details', case when p_payment = 'OMT' then v_settings->>'omt_details' end,
    'unpaid_cancel_hours', case when p_payment <> 'COD' then nullif(v_settings->>'unpaid_cancel_hours', '') end,
    'items', (select jsonb_agg(i - 'variant_id' - 'sku') from jsonb_array_elements(v_items) i)
  );
end;
$$;
revoke all on function public.place_order(jsonb, jsonb, text, text) from public;
grant execute on function public.place_order(jsonb, jsonb, text, text) to anon, authenticated;
