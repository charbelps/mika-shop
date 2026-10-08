-- =====================================================================
-- Mika Shop: migration 24, "delivery fee to be confirmed" emergency switch (Phase 1c, C1).
-- Decided: 12b #2 (allow the order, fee settled after, all payment methods stay available) and
-- advice #1 (only an emergency switch, default OFF: every area should have its fee).
--  * setting fee_tbc_enabled ('' = off, 'on'), public because the checkout needs it.
--    admin_save_settings accepts only '' or 'on' for it.
--  * orders.fee_tbc   : placed while its area had no fee (stays true as history)
--    orders.fee_set_at: when Mika set the fee afterwards (empty = still to confirm)
--  * place_order_core: same as migration 13 (20261005100000) except the fee: an area without a
--    fee is refused as before, unless the switch is on; then fee 0, fee_tbc true, and the answer
--    says fee_to_confirm. Whish / OMT then pay the items; the fee is collected on delivery.
--  * staff_set_delivery_fee(order, fee): ADMIN only, only fee_tbc orders not yet delivered /
--    cancelled / returned; total = subtotal + fee; the customer's total_spent follows.
-- Additive: new columns with defaults, one new setting, functions replaced. No data changed.
-- =====================================================================

alter table public.orders
  add column if not exists fee_tbc boolean not null default false,
  add column if not exists fee_set_at timestamptz;
comment on column public.orders.fee_tbc is 'Placed while its delivery area had no fee ("fee to be confirmed" switch on).';
comment on column public.orders.fee_set_at is 'When the delivery fee of a fee_tbc order was set by staff (empty = still to confirm).';

insert into public.settings (key, value, is_public) values ('fee_tbc_enabled', '', true)
on conflict (key) do nothing;


-- The core of every order (website + staff), unchanged except the delivery fee (see above).
create or replace function public.place_order_core(
  p_customer jsonb,
  p_items jsonb,
  p_payment text,
  p_source text,
  p_status text,
  p_notes text default null
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
  v_notes    text := nullif(trim(coalesce(p_notes, '')), '');
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
  v_fee      numeric(10,2);
  v_tbc      boolean := false;
begin
  -- ---- 1. validate ----
  if p_source is null or p_source not in ('WEBSITE', 'PHONE', 'INSTAGRAM', 'WHATSAPP')
     or p_status is null or p_status not in ('NEW', 'CONFIRMED') then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  if length(v_name) not between 1 and 80 or length(v_town) not between 1 and 80
     or length(v_address) not between 1 and 300 or length(coalesce(v_landmark, '')) > 150
     or length(coalesce(v_loc, '')) > 500 or (v_loc is not null and v_loc !~* '^https?://\S+$')
     or length(coalesce(v_notes, '')) > 1000
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
  -- C1: an area without a fee is refused, unless Mika switched on "fee to be confirmed"
  -- (emergency switch, default off): then the order goes through with fee 0 and is marked,
  -- and Mika sets the fee afterwards (staff_set_delivery_fee). 12b #2, advice #1.
  v_fee := v_zone.fee;
  if v_fee is null then
    if coalesce(v_settings->>'fee_tbc_enabled', '') = 'on' then
      v_fee := 0;
      v_tbc := true;
    else
      raise exception 'ZONE_FEE_NOT_SET' using errcode = 'P0001';
    end if;
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

  v_total := v_subtotal + v_fee;

  -- ---- 4. create the order ----
  v_order_no := coalesce(trim(v_settings->>'order_prefix'), '') || nextval('public.order_no_seq');
  insert into public.orders (order_no, phone, name, governorate, district, town, address, landmark,
    location_url, subtotal, delivery_fee, total, payment_method, payment_status, status, carrier,
    source, notes, fee_tbc)
  values (v_order_no, v_phone, v_name, v_zone.governorate, v_zone.district, v_town, v_address, v_landmark,
    v_loc, v_subtotal, v_fee, v_total, p_payment,
    case when p_payment = 'COD' then 'UNPAID' else 'AWAITING' end, p_status, v_zone.default_carrier,
    p_source, v_notes, v_tbc)
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

  -- ---- 7. answer ----
  return jsonb_build_object(
    'order_id', v_order_id,
    'order_no', v_order_no,
    'created_at', now(),
    'subtotal', v_subtotal,
    'delivery_fee', v_fee,
    'fee_to_confirm', v_tbc,
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
revoke all on function public.place_order_core(jsonb, jsonb, text, text, text, text) from public, anon, authenticated;


-- Settings: the switch only takes '' (off) or 'on'. Otherwise unchanged from migration 17.
create or replace function public.admin_save_settings(p_values jsonb)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_val text;
  v_n int := 0;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can change settings' using errcode = '42501';
  end if;
  if jsonb_typeof(p_values) is distinct from 'object' then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;

  for v_key, v_val in select key, trim(coalesce(value, '')) from jsonb_each_text(p_values) loop
    if v_key in ('order_alert_url', 'push_public_key') or not exists (select 1 from public.settings where key = v_key) then
      raise exception 'UNKNOWN_SETTING' using errcode = 'P0001', detail = v_key;
    end if;

    if v_key in ('unpaid_cancel_hours', 'low_stock_threshold') and v_val <> ''
       and (v_val !~ '^[0-9]{1,4}$' or v_val::int > 9999) then
      raise exception 'BAD_NUMBER' using errcode = 'P0001', detail = v_key;
    end if;
    if v_key = 'fee_tbc_enabled' and v_val not in ('', 'on') then
      raise exception 'BAD_SWITCH' using errcode = 'P0001', detail = v_key;
    end if;
    if v_key = 'order_prefix' and v_val !~ '^[A-Za-z0-9-]{0,6}$' then
      raise exception 'BAD_PREFIX' using errcode = 'P0001', detail = v_key;
    end if;
    if v_key = 'whatsapp_number' and v_val <> '' then
      v_val := public.normalize_phone(v_val);
      if v_val is null then
        raise exception 'BAD_PHONE' using errcode = 'P0001', detail = v_key;
      end if;
    end if;
    if v_key = 'currency' and length(v_val) > 10
       or v_key in ('shop_name_en', 'shop_name_ar', 'whish_number') and length(v_val) > 80
       or length(v_val) > 5000 then
      raise exception 'TOO_LONG' using errcode = 'P0001', detail = v_key;
    end if;

    update public.settings set value = v_val where key = v_key and value is distinct from v_val;
    if found then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end;
$$;
revoke all on function public.admin_save_settings(jsonb) from public, anon;
grant execute on function public.admin_save_settings(jsonb) to authenticated;


-- Mika sets the fee of a "to be confirmed" order (can correct it until delivery).
create or replace function public.staff_set_delivery_fee(p_order_id bigint, p_fee numeric)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.orders;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can change orders' using errcode = '42501';
  end if;
  if p_fee is null or p_fee < 0 or p_fee > 1000 or p_fee <> round(p_fee, 2) then
    raise exception 'BAD_FEE' using errcode = 'P0001';
  end if;
  select * into v from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0001';
  end if;
  if not v.fee_tbc then
    raise exception 'FEE_NOT_TO_CONFIRM' using errcode = 'P0001';
  end if;
  if v.status in ('DELIVERED', 'CANCELLED', 'RETURNED') then
    raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001', detail = v.status;
  end if;
  update public.orders
     set delivery_fee = p_fee, total = subtotal + p_fee, fee_set_at = now()
   where id = p_order_id;
  update public.customers set total_spent = total_spent + (p_fee - v.delivery_fee) where phone = v.phone;
  return jsonb_build_object('delivery_fee', p_fee, 'total', v.subtotal + p_fee);
end;
$$;
revoke all on function public.staff_set_delivery_fee(bigint, numeric) from public, anon;
grant execute on function public.staff_set_delivery_fee(bigint, numeric) to authenticated;
