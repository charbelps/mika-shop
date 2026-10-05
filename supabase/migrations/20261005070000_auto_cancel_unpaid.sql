-- =====================================================================
-- Mika Shop: migration 10, auto-cancel unpaid Whish/OMT orders (Phase 1, step 10).
--  * cancel_unpaid_orders(): cancels orders still AWAITING payment (and not yet out for
--    delivery) that are older than settings.unpaid_cancel_hours, and returns their stock
--    (through cancel_order_core: stock_log reason CANCEL linked to the order).
--    unpaid_cancel_hours empty / not a whole number / 0 => does nothing (decision pending).
--    Each order is cancelled on its own, so one problem never blocks the others.
--  * pg_cron job 'cancel-unpaid-orders' every 15 minutes.
-- =====================================================================

create extension if not exists pg_cron;

create or replace function public.cancel_unpaid_orders()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hours_txt text;
  v_hours int;
  v_id bigint;
  v_done int := 0;
begin
  select trim(value) into v_hours_txt from public.settings where key = 'unpaid_cancel_hours';
  if v_hours_txt is null or v_hours_txt !~ '^[0-9]{1,4}$' then
    return 0;
  end if;
  v_hours := v_hours_txt::int;
  if v_hours <= 0 then
    return 0;
  end if;

  for v_id in
    select id from public.orders
    where payment_status = 'AWAITING'
      and payment_method in ('WHISH', 'OMT')
      and status in ('NEW', 'CONFIRMED', 'PACKED')
      and created_at < now() - make_interval(hours => v_hours)
    order by id
  loop
    begin
      perform public.cancel_order_core(v_id, format('Not paid within %s hours (automatic)', v_hours));
      v_done := v_done + 1;
    exception when others then
      raise warning 'cancel_unpaid_orders: order % not cancelled: %', v_id, sqlerrm;
    end;
  end loop;
  return v_done;
end;
$$;
revoke all on function public.cancel_unpaid_orders() from public;

select cron.schedule('cancel-unpaid-orders', '*/15 * * * *', 'select public.cancel_unpaid_orders()');
