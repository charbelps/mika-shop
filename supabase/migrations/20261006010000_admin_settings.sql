-- =====================================================================
-- Mika Shop: migration 14, admin Settings + Delivery screens and small decided changes
-- (Phase 1c, decided by Charbel 6 Oct 2026).
--  * admin_save_settings(jsonb): ADMIN only, one transaction, validates every value.
--    Technical keys (order_alert_url) can't be changed from the screen.
--  * settings privacy_en / privacy_ar (public): the shop's privacy page (advice #7).
--  * setting phone_number removed: "Call us" uses the WhatsApp number (12b #32). It was
--    added empty on 5 Oct and never filled.
--  * orders.is_first_order (additive): true on a phone number's first order, so the Orders
--    screen can show a "NEW CUSTOMER" badge (advice #2). Set by a trigger before the
--    customer row is created; existing orders backfilled.
--  * track_order(): also returns payment_received (Whish/OMT confirmed by Mika, 12b #26).
--  * delivery_zones: ADMIN already edits them directly (RLS zones_admin); trimmed names
--    are enforced here so a typo with spaces can't create a second "Matn".
-- =====================================================================

insert into public.settings (key, value, is_public) values
  ('privacy_en', '', true),
  ('privacy_ar', '', true)
on conflict (key) do nothing;

delete from public.settings where key = 'phone_number' and value = '';


-- ---------- settings saved from the admin screen ----------
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
    if v_key = 'order_alert_url' or not exists (select 1 from public.settings where key = v_key) then
      raise exception 'UNKNOWN_SETTING' using errcode = 'P0001', detail = v_key;
    end if;

    if v_key in ('unpaid_cancel_hours', 'low_stock_threshold') and v_val <> ''
       and (v_val !~ '^[0-9]{1,4}$' or v_val::int > 9999) then
      raise exception 'BAD_NUMBER' using errcode = 'P0001', detail = v_key;
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


-- ---------- delivery areas: no leading / trailing spaces, no empty names ----------
update public.delivery_zones set governorate = trim(governorate), district = trim(district),
  governorate_ar = trim(governorate_ar), district_ar = trim(district_ar)
where governorate <> trim(governorate) or district <> trim(district)
   or governorate_ar <> trim(governorate_ar) or district_ar <> trim(district_ar);
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'delivery_zones_names_check') then
    alter table public.delivery_zones add constraint delivery_zones_names_check check (
      governorate = trim(governorate) and district = trim(district) and governorate <> '' and district <> ''
      and governorate_ar = trim(governorate_ar) and district_ar = trim(district_ar));
  end if;
end $$;


-- ---------- first order of a phone number ----------
alter table public.orders add column if not exists is_first_order boolean not null default false;

create or replace function public.orders_mark_first()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- runs before the order row exists and before place_order_core saves the customer
  new.is_first_order := not exists (select 1 from public.orders o where o.phone = new.phone);
  return new;
end;
$$;
revoke all on function public.orders_mark_first() from public, anon, authenticated;
drop trigger if exists orders_mark_first on public.orders;
create trigger orders_mark_first before insert on public.orders
  for each row execute function public.orders_mark_first();

update public.orders o set is_first_order = true
where o.id = (select min(o2.id) from public.orders o2 where o2.phone = o.phone) and not o.is_first_order;


-- ---------- tracking: payment received ----------
create or replace function public.track_order(p_order_no text, p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_phone text := public.normalize_phone(p_phone);
  v_no text := upper(trim(coalesce(p_order_no, '')));
  v jsonb;
begin
  if v_phone is null or v_no = '' or length(v_no) > 30 then
    return null;
  end if;
  select jsonb_build_object('order_no', o.order_no, 'status', o.status,
                            'created_at', o.created_at, 'updated_at', o.updated_at,
                            'payment_received', o.payment_method in ('WHISH', 'OMT') and o.payment_status = 'PAID')
    into v
  from public.orders o
  where upper(o.order_no) = v_no and o.phone = v_phone;
  return v;
end;
$$;
revoke all on function public.track_order(text, text) from public;
grant execute on function public.track_order(text, text) to anon, authenticated;
