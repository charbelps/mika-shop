-- =====================================================================
-- Mika Shop: migration 28, delivery flow (Phase 1c D1 / D2 basics, Phase 2 company handover).
--  * orders: out_at (given to the driver / the company), delivered_at, failed_at, failed_reason,
--    failed_count. Additive.
--  * amount_to_collect(order): the SAME rule as DB.amountToCollect in docs/js/db.js
--    (null = a "fee to be confirmed" that isn't set yet).
--  * staff_directory(): names / roles of staff for ADMIN and OWNER (driver lists, "delivered by").
--  * staff_assign_delivery(order, carrier, driver): ADMIN; our driver (an active DRIVER) or the
--    delivery company, until the order is delivered.
--  * delivery_move_core(...): internal; the only way an order moves through delivery:
--      OUT       PACKED / FAILED_ATTEMPT -> OUT_FOR_DELIVERY  (our driver, driver chosen)
--      COMPANY   PACKED / FAILED_ATTEMPT -> WITH_COMPANY      (delivery company, tracking no.)
--      DELIVERED OUT_FOR_DELIVERY / WITH_COMPANY -> DELIVERED (cash collected, a number)
--      FAILED    OUT_FOR_DELIVERY / WITH_COMPANY -> FAILED_ATTEMPT (reason required)
--      BACK      OUT_FOR_DELIVERY / WITH_COMPANY / FAILED_ATTEMPT -> PACKED (back at the shop)
--    Returns after delivery keep using cancel_order(id, reason, true) (stock back).
--  * staff_delivery(order, action, cash, reason, tracking): ADMIN, every action.
--  * driver_delivery(order, action, cash, reason): DRIVER, only HIS orders, only
--    START (= OUT), DELIVERED, FAILED.
--  * orders_driver_guard: a DRIVER can still write notes directly; status and cash only through
--    driver_delivery (so a driver can't e.g. set CANCELLED without the stock coming back).
-- =====================================================================

alter table public.orders
  add column if not exists out_at timestamptz,
  add column if not exists delivered_at timestamptz,
  add column if not exists failed_at timestamptz,
  add column if not exists failed_reason text check (failed_reason is null or length(failed_reason) <= 300),
  add column if not exists failed_count integer not null default 0 check (failed_count >= 0);
comment on column public.orders.out_at is 'When the order left with our driver or was handed to the delivery company.';
comment on column public.orders.failed_reason is 'Reason of the last failed delivery attempt.';

-- ---------- what the driver / company must collect (same rule as DB.amountToCollect) ----------
create or replace function public.amount_to_collect(o public.orders)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case
    when o.payment_status = 'PAID' then
      case when o.fee_tbc and (o.fee_set_at is null or o.delivery_fee > 0)
           then case when o.fee_set_at is null then null else o.delivery_fee end
           else 0 end
    else o.total
  end
$$;
revoke all on function public.amount_to_collect(public.orders) from public, anon;
grant execute on function public.amount_to_collect(public.orders) to authenticated;

-- ---------- staff names for ADMIN / OWNER ----------
create or replace function public.staff_directory()
returns table (user_id uuid, name text, role text, active boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select s.user_id, s.name, s.role, s.active from public.staff s
  where public.my_role() in ('ADMIN', 'OWNER')
  order by s.role, s.name
$$;
revoke all on function public.staff_directory() from public, anon;
grant execute on function public.staff_directory() to authenticated;

-- ---------- who delivers ----------
create or replace function public.staff_assign_delivery(p_order_id bigint, p_carrier text, p_driver_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.orders;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can assign deliveries' using errcode = '42501';
  end if;
  if p_carrier is not null and p_carrier not in ('DRIVER', 'COMPANY') then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  select * into v from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v.status in ('DELIVERED', 'CANCELLED', 'RETURNED') then
    raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001', detail = v.status;
  end if;
  -- out with one driver: give it back first (Back to the shop) before changing who delivers
  if v.status in ('OUT_FOR_DELIVERY', 'WITH_COMPANY') then
    raise exception 'ON_THE_WAY' using errcode = 'P0001';
  end if;
  if p_carrier = 'DRIVER' and p_driver_id is not null
     and not exists (select 1 from public.staff s where s.user_id = p_driver_id and s.role = 'DRIVER' and s.active) then
    raise exception 'NOT_A_DRIVER' using errcode = 'P0001';
  end if;
  update public.orders
     set carrier = p_carrier,
         driver_id = case when p_carrier = 'DRIVER' then p_driver_id end
   where id = p_order_id;
  return jsonb_build_object('carrier', p_carrier, 'driver_id', case when p_carrier = 'DRIVER' then p_driver_id end);
end;
$$;
revoke all on function public.staff_assign_delivery(bigint, text, uuid) from public, anon;
grant execute on function public.staff_assign_delivery(bigint, text, uuid) to authenticated;

-- ---------- the delivery moves (internal) ----------
create or replace function public.delivery_move_core(
  p_order_id bigint, p_action text, p_cash numeric, p_reason text, p_tracking text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.orders;
  v_to text;
  v_cash numeric;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_track text := nullif(trim(coalesce(p_tracking, '')), '');
begin
  select * into v from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0001';
  end if;

  if p_action = 'OUT' then
    if v.status not in ('PACKED', 'FAILED_ATTEMPT') then
      raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001', detail = v.status || ' -> OUT_FOR_DELIVERY';
    end if;
    if v.carrier is distinct from 'DRIVER' or v.driver_id is null then
      raise exception 'NO_DRIVER' using errcode = 'P0001';
    end if;
    v_to := 'OUT_FOR_DELIVERY';
  elsif p_action = 'COMPANY' then
    if v.status not in ('PACKED', 'FAILED_ATTEMPT') then
      raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001', detail = v.status || ' -> WITH_COMPANY';
    end if;
    if v.carrier is distinct from 'COMPANY' then
      raise exception 'NOT_COMPANY' using errcode = 'P0001';
    end if;
    if length(coalesce(v_track, '')) > 60 then
      raise exception 'INVALID_INPUT' using errcode = 'P0001';
    end if;
    v_to := 'WITH_COMPANY';
  elsif p_action = 'DELIVERED' then
    if v.status not in ('OUT_FOR_DELIVERY', 'WITH_COMPANY') then
      raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001', detail = v.status || ' -> DELIVERED';
    end if;
    v_cash := p_cash;
    if v_cash is null or v_cash < 0 or v_cash > 100000 or v_cash <> round(v_cash, 2) then
      raise exception 'BAD_CASH' using errcode = 'P0001';
    end if;
    v_to := 'DELIVERED';
  elsif p_action = 'FAILED' then
    if v.status not in ('OUT_FOR_DELIVERY', 'WITH_COMPANY') then
      raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001', detail = v.status || ' -> FAILED_ATTEMPT';
    end if;
    if v_reason is null or length(v_reason) > 300 then
      raise exception 'REASON_REQUIRED' using errcode = 'P0001';
    end if;
    v_to := 'FAILED_ATTEMPT';
  elsif p_action = 'BACK' then
    if v.status not in ('OUT_FOR_DELIVERY', 'WITH_COMPANY', 'FAILED_ATTEMPT') then
      raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001', detail = v.status || ' -> PACKED';
    end if;
    v_to := 'PACKED';
  else
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;

  perform set_config('app.delivery_move', 'on', true);   -- lets the driver guard accept this update
  update public.orders set
    status         = v_to,
    out_at         = case when v_to in ('OUT_FOR_DELIVERY', 'WITH_COMPANY') then now() else out_at end,
    tracking_no    = case when p_action = 'COMPANY' and v_track is not null then v_track else tracking_no end,
    delivered_at   = case when v_to = 'DELIVERED' then now() else delivered_at end,
    cash_collected = case when v_to = 'DELIVERED' then v_cash else cash_collected end,
    failed_at      = case when v_to = 'FAILED_ATTEMPT' then now() else failed_at end,
    failed_reason  = case when v_to = 'FAILED_ATTEMPT' then v_reason else failed_reason end,
    failed_count   = failed_count + case when v_to = 'FAILED_ATTEMPT' then 1 else 0 end
  where id = p_order_id;
  perform set_config('app.delivery_move', '', true);
  return jsonb_build_object('status', v_to);
end;
$$;
revoke all on function public.delivery_move_core(bigint, text, numeric, text, text) from public, anon, authenticated;

create or replace function public.staff_delivery(
  p_order_id bigint, p_action text, p_cash numeric default null, p_reason text default null, p_tracking text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can change deliveries' using errcode = '42501';
  end if;
  return public.delivery_move_core(p_order_id, p_action, p_cash, p_reason, p_tracking);
end;
$$;
revoke all on function public.staff_delivery(bigint, text, numeric, text, text) from public, anon;
grant execute on function public.staff_delivery(bigint, text, numeric, text, text) to authenticated;

create or replace function public.driver_delivery(
  p_order_id bigint, p_action text, p_cash numeric default null, p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.my_role() is distinct from 'DRIVER' then
    raise exception 'Only drivers can use this' using errcode = '42501';
  end if;
  -- only his own orders (anything else answers "not found", like an order he can't see)
  if not exists (select 1 from public.orders o where o.id = p_order_id and o.driver_id = auth.uid() and o.carrier = 'DRIVER') then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_action is null or p_action not in ('START', 'DELIVERED', 'FAILED') then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  return public.delivery_move_core(p_order_id, case when p_action = 'START' then 'OUT' else p_action end, p_cash, p_reason, null);
end;
$$;
revoke all on function public.driver_delivery(bigint, text, numeric, text) from public, anon;
grant execute on function public.driver_delivery(bigint, text, numeric, text) to authenticated;

-- ---------- drivers: notes directly, status / cash only through driver_delivery ----------
create or replace function public.orders_driver_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.my_role() = 'DRIVER' and coalesce(current_setting('app.delivery_move', true), '') <> 'on' then
    if (to_jsonb(new) - array['notes', 'updated_at']) is distinct from (to_jsonb(old) - array['notes', 'updated_at']) then
      raise exception 'Drivers can only change notes here; deliveries go through the driver screen'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.orders_driver_guard() from public, anon, authenticated;
