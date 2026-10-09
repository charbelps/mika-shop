-- =====================================================================
-- Mika Shop: migration 27, gift orders (Phase 2, F6; 12b #30).
-- The buyer orders for someone else: the buyer stays the customer (phone = customer ID, the one
-- who pays, tracks the order and gets the WhatsApp updates); the order's address fields hold the
-- RECIPIENT's address, and the delivery fee is the recipient's district fee.
--  * orders.is_gift, recipient_name, recipient_phone (normalized +961), gift_note (card text).
--  * place_order_core: same as migration 24 except the gift lines (generated from it, diff = gift
--    only). p_customer.gift = { name, phone, note } makes the order a gift:
--      - recipient name 1-80, phone must be Lebanese (INVALID_RECIPIENT_PHONE), note <= 300;
--      - Whish / OMT only (GIFT_NEEDS_PREPAID): the recipient never pays anything;
--      - the recipient's area needs a fee (GIFT_NEEDS_FEE), even with "fee to be confirmed" on;
--      - the buyer's saved address is NOT replaced by the recipient's.
--    The answer adds is_gift and recipient_name.
-- Additive: new columns with defaults, one function replaced. No data changed.
-- =====================================================================

alter table public.orders
  add column if not exists is_gift boolean not null default false,
  add column if not exists recipient_name text check (recipient_name is null or length(recipient_name) between 1 and 80),
  add column if not exists recipient_phone text check (recipient_phone is null or recipient_phone ~ '^\+961[0-9]{7,8}$'),
  add column if not exists gift_note text check (gift_note is null or length(gift_note) <= 300);
alter table public.orders add constraint orders_gift_recipient
  check (not is_gift or (recipient_name is not null and recipient_phone is not null));
comment on column public.orders.is_gift is 'Gift (F6): delivered to recipient_name / recipient_phone at this order''s address; the buyer (name / phone) pays.';
comment on column public.orders.gift_note is 'Short message for the gift card (printed on the gift slip).';


-- The core of every order (website + staff), unchanged except the gift lines (see above).
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
  v_gift     jsonb := case when jsonb_typeof(p_customer->'gift') = 'object' then p_customer->'gift' end;
  v_rname    text;
  v_rphone   text;
  v_gnote    text;
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

  -- F6: a gift is delivered to someone else. The buyer stays the customer (phone = customer ID);
  -- the address fields are the recipient's. Gifts are paid before delivery (Whish / OMT, 12b #30).
  if v_gift is not null then
    v_rname := trim(coalesce(v_gift->>'name', ''));
    v_rphone := public.normalize_phone(v_gift->>'phone');
    v_gnote := nullif(trim(coalesce(v_gift->>'note', '')), '');
    if length(v_rname) not between 1 and 80 or length(coalesce(v_gnote, '')) > 300 then
      raise exception 'INVALID_INPUT' using errcode = 'P0001';
    end if;
    if v_rphone is null then
      raise exception 'INVALID_RECIPIENT_PHONE' using errcode = 'P0001';
    end if;
    if p_payment not in ('WHISH', 'OMT') then
      raise exception 'GIFT_NEEDS_PREPAID' using errcode = 'P0001';
    end if;
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
    if v_gift is not null then
      raise exception 'GIFT_NEEDS_FEE' using errcode = 'P0001';  -- the recipient would have to pay the fee in cash
    elsif coalesce(v_settings->>'fee_tbc_enabled', '') = 'on' then
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
    source, notes, fee_tbc, is_gift, recipient_name, recipient_phone, gift_note)
  values (v_order_no, v_phone, v_name, v_zone.governorate, v_zone.district, v_town, v_address, v_landmark,
    v_loc, v_subtotal, v_fee, v_total, p_payment,
    case when p_payment = 'COD' then 'UNPAID' else 'AWAITING' end, p_status, v_zone.default_carrier,
    p_source, v_notes, v_tbc, v_gift is not null, v_rname, v_rphone, v_gnote)
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
  if v_gift is null then
    insert into public.customers (phone, name, governorate, district, town, address, landmark, location_url,
                                  first_order_at, orders_count, total_spent)
    values (v_phone, v_name, v_zone.governorate, v_zone.district, v_town, v_address, v_landmark, v_loc, now(), 1, v_total)
    on conflict (phone) do update set
      name = excluded.name, governorate = excluded.governorate, district = excluded.district,
      town = excluded.town, address = excluded.address, landmark = excluded.landmark,
      location_url = excluded.location_url,
      orders_count = public.customers.orders_count + 1,
      total_spent = public.customers.total_spent + excluded.total_spent;
  else
    -- a gift: the buyer's own saved address is kept (this order's address is the recipient's)
    insert into public.customers (phone, name, first_order_at, orders_count, total_spent)
    values (v_phone, v_name, now(), 1, v_total)
    on conflict (phone) do update set
      name = excluded.name,
      orders_count = public.customers.orders_count + 1,
      total_spent = public.customers.total_spent + excluded.total_spent;
  end if;

  -- ---- 7. answer ----
  return jsonb_build_object(
    'order_id', v_order_id,
    'order_no', v_order_no,
    'created_at', now(),
    'subtotal', v_subtotal,
    'delivery_fee', v_fee,
    'fee_to_confirm', v_tbc,
    'is_gift', v_gift is not null,
    'recipient_name', v_rname,
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
