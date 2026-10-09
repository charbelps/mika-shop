-- =====================================================================
-- Mika Shop: migration 32, limit on unfinished website orders per phone (12c R2, Charbel 9 Oct).
--  * Setting max_open_orders_per_phone (private, '3'): a phone number that already has this many
--    orders not yet delivered, cancelled or returned can't place another one ON THE WEBSITE.
--    Empty or 0 = no limit. Editable in Settings (admin_save_settings checks it is a number).
--  * place_order: same as migration 21 (honeypot, language, place_order_core), plus the check.
--    The phone is normalized exactly like place_order_core does (buyer's phone, also for gifts).
--    A lock per phone number makes two orders sent at the same moment wait for each other, so
--    nobody gets past the limit by double-clicking.
--  * Orders Mika takes on the New order screen (staff_place_order) are never blocked; they do
--    count for the customer's limit.
--  * Answer when the limit is reached: TOO_MANY_OPEN_ORDERS, detail = the limit (for the message).
-- =====================================================================

insert into public.settings (key, value, is_public) values ('max_open_orders_per_phone', '3', false)
on conflict (key) do nothing;

create index if not exists orders_phone_open_idx on public.orders (phone)
  where status not in ('DELIVERED', 'CANCELLED', 'RETURNED');

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
  v_phone text;
  v_limit_txt text;
  v_limit integer;
  v_open integer;
begin
  if coalesce(trim(p_honeypot), '') <> '' then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';  -- spam trap filled: say nothing more
  end if;

  -- at most N unfinished orders per phone (a bad phone is refused by place_order_core itself)
  v_phone := public.normalize_phone(p_customer->>'phone');
  if v_phone is not null then
    select trim(value) into v_limit_txt from public.settings where key = 'max_open_orders_per_phone';
    v_limit := case when v_limit_txt ~ '^[0-9]{1,4}$' then v_limit_txt::integer else 0 end;
    if v_limit > 0 then
      perform pg_advisory_xact_lock(hashtextextended('place_order:phone:' || v_phone, 0));
      select count(*) into v_open from public.orders
      where phone = v_phone and status not in ('DELIVERED', 'CANCELLED', 'RETURNED');
      if v_open >= v_limit then
        raise exception 'TOO_MANY_OPEN_ORDERS' using errcode = 'P0001', detail = v_limit::text;
      end if;
    end if;
  end if;

  perform set_config('app.order_lang',
    case when p_customer->>'lang' in ('en', 'ar') then p_customer->>'lang' else '' end, true);
  return public.place_order_core(p_customer, p_items, p_payment, 'WEBSITE', 'NEW') - 'order_id';
end;
$$;
revoke all on function public.place_order(jsonb, jsonb, text, text) from public;
grant execute on function public.place_order(jsonb, jsonb, text, text) to anon, authenticated;


-- Settings: same as migration 24, plus max_open_orders_per_phone in the number check.
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

    if v_key in ('unpaid_cancel_hours', 'low_stock_threshold', 'max_open_orders_per_phone') and v_val <> ''
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
