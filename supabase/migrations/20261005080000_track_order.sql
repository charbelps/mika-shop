-- =====================================================================
-- Mika Shop: migration 11, order tracking for customers (Phase 1, step 11).
--  * track_order(order_no, phone): for logged-out visitors. Returns ONLY
--    { order_no, status, created_at, updated_at } when BOTH the order number and the phone
--    (any format, normalized) match; otherwise null. A wrong phone and a wrong number look the
--    same, so nobody can find out which order numbers exist.
-- =====================================================================

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
                            'created_at', o.created_at, 'updated_at', o.updated_at)
    into v
  from public.orders o
  where upper(o.order_no) = v_no and o.phone = v_phone;
  return v;
end;
$$;
revoke all on function public.track_order(text, text) from public;
grant execute on function public.track_order(text, text) to anon, authenticated;
