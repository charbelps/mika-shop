-- =====================================================================
-- Mika Shop: migration 9, prep screen actions (Phase 1, step 9).
--  * cancel_order_core(id, reason, is_return): internal (no role check; also used by the
--    auto-cancel job in step 10). Puts the stock back (stock_log reason CANCEL or RETURN,
--    linked to the order) and sets status CANCELLED / RETURNED with the reason.
--  * cancel_order(id, reason, is_return default false): ADMIN only wrapper.
--  * staff_confirm_payment(id, ref): ADMIN. Whish/OMT order AWAITING -> PAID + reference.
--  * staff_set_status(id, status): ADMIN. Prep moves only: NEW -> CONFIRMED,
--    NEW/CONFIRMED -> PACKED, CONFIRMED -> NEW (undo), PACKED -> CONFIRMED (undo).
--  * orders added to the Realtime publication, so the prep screen updates live
--    (Realtime still applies RLS: only staff who may read an order receive it).
-- =====================================================================

create or replace function public.cancel_order_core(p_order_id bigint, p_reason text, p_is_return boolean default false)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
  v_item  record;
begin
  if coalesce(trim(p_reason), '') = '' or length(p_reason) > 300 then
    raise exception 'REASON_REQUIRED' using errcode = 'P0001';
  end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_is_return then
    if v_order.status not in ('DELIVERED', 'FAILED_ATTEMPT') then
      raise exception 'CANNOT_RETURN' using errcode = 'P0001', detail = v_order.status;
    end if;
  elsif v_order.status not in ('NEW', 'CONFIRMED', 'PACKED') then
    raise exception 'CANNOT_CANCEL' using errcode = 'P0001', detail = v_order.status;
  end if;

  perform set_config('app.stock_reason', case when p_is_return then 'RETURN' else 'CANCEL' end, true);
  perform set_config('app.stock_order_id', v_order.id::text, true);
  -- lock in the same order as place_order (sku, then variant) so the two never deadlock
  for v_item in
    select sku, variant_id, sum(qty) as qty from public.order_items
    where order_id = v_order.id group by sku, variant_id order by sku, variant_id nulls first
  loop
    if v_item.variant_id is null then
      update public.products set stock = stock + v_item.qty where sku = v_item.sku;
    else
      update public.variants set stock = stock + v_item.qty where id = v_item.variant_id;
    end if;
    -- a product/option deleted since the order simply gets nothing back (never deleted in this app)
  end loop;
  perform set_config('app.stock_order_id', '', true);

  update public.orders
    set status = case when p_is_return then 'RETURNED' else 'CANCELLED' end,
        cancel_reason = trim(p_reason)
    where id = v_order.id;
  return case when p_is_return then 'RETURNED' else 'CANCELLED' end;
end;
$$;
revoke all on function public.cancel_order_core(bigint, text, boolean) from public;

create or replace function public.cancel_order(p_order_id bigint, p_reason text, p_is_return boolean default false)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can cancel orders' using errcode = '42501';
  end if;
  return public.cancel_order_core(p_order_id, p_reason, p_is_return);
end;
$$;
revoke all on function public.cancel_order(bigint, text, boolean) from public;
grant execute on function public.cancel_order(bigint, text, boolean) to authenticated;


create or replace function public.staff_confirm_payment(p_order_id bigint, p_ref text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.orders;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can confirm payments' using errcode = '42501';
  end if;
  if coalesce(trim(p_ref), '') = '' or length(p_ref) > 100 then
    raise exception 'REF_REQUIRED' using errcode = 'P0001';
  end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0001';
  end if;
  if v_order.payment_method not in ('WHISH', 'OMT') or v_order.payment_status <> 'AWAITING'
     or v_order.status in ('CANCELLED', 'RETURNED') then
    raise exception 'CANNOT_CONFIRM_PAYMENT' using errcode = 'P0001', detail = v_order.payment_status;
  end if;
  update public.orders set payment_status = 'PAID', payment_ref = trim(p_ref) where id = p_order_id;
  return 'PAID';
end;
$$;
revoke all on function public.staff_confirm_payment(bigint, text) from public;
grant execute on function public.staff_confirm_payment(bigint, text) to authenticated;


create or replace function public.staff_set_status(p_order_id bigint, p_status text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from text;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can change orders' using errcode = '42501';
  end if;
  select status into v_from from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0001';
  end if;
  if not ((v_from = 'NEW' and p_status in ('CONFIRMED', 'PACKED'))
       or (v_from = 'CONFIRMED' and p_status in ('PACKED', 'NEW'))
       or (v_from = 'PACKED' and p_status = 'CONFIRMED')) then
    raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001', detail = v_from || ' -> ' || coalesce(p_status, 'null');
  end if;
  update public.orders set status = p_status where id = p_order_id;
  return p_status;
end;
$$;
revoke all on function public.staff_set_status(bigint, text) from public;
grant execute on function public.staff_set_status(bigint, text) to authenticated;


-- Realtime: new and changed orders reach the prep screen live (RLS still applies).
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders') then
    alter publication supabase_realtime add table public.orders;
  end if;
end $$;
