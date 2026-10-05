-- =====================================================================
-- Mika Shop: migration 8, Telegram alert on every new order (Phase 1, step 8).
--  * orders.alert_sent_at (additive): set by the Edge Function once the alert went out,
--    so an order is never alerted twice.
--  * settings 'order_alert_url' (private): the Edge Function address of THIS project
--    (TEST and LIVE differ). Empty = alerts off.
--  * Trigger after INSERT on orders -> pg_net POST {order_id} to that address.
--    pg_net only sends after the transaction commits, so the function always sees the
--    order WITH its items, and nothing is sent for orders that were rolled back.
--    The function reads the order itself with the service key; the request carries only the id.
-- =====================================================================

create extension if not exists pg_net with schema extensions;

alter table public.orders add column if not exists alert_sent_at timestamptz;

insert into public.settings (key, value, is_public) values ('order_alert_url', '', false)
on conflict (key) do nothing;

create or replace function public.notify_new_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
begin
  select value into v_url from public.settings where key = 'order_alert_url';
  if coalesce(trim(v_url), '') <> '' then
    perform net.http_post(
      url := trim(v_url),
      body := jsonb_build_object('order_id', new.id),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 10000
    );
  end if;
  return new;
exception when others then
  -- An alert problem must never block an order.
  raise warning 'notify_new_order failed for order %: %', new.id, sqlerrm;
  return new;
end;
$$;
revoke all on function public.notify_new_order() from public;

create trigger orders_notify_new after insert on public.orders
  for each row execute function public.notify_new_order();
