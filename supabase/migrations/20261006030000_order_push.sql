-- =====================================================================
-- Mika Shop: migration 17, new-order alerts without Telegram (Phase 1c, A4; 12b #21).
--  * push_subscriptions: one row per phone / computer that turned on order notifications
--    (web push). Staff manage only their own devices, through two functions:
--      save_push_subscription(endpoint, p256dh, auth, user_agent)
--      remove_push_subscription(endpoint)
--  * setting push_public_key (public, technical): the public half of the notification key.
--    The private half is an Edge Function secret (VAPID_PRIVATE_KEY), never in the database.
--  * admin_save_settings: technical keys (order_alert_url, push_public_key) stay read-only.
--  * service_role GRANTs for the Edge Function new-order-alert (auto-expose is OFF): read the
--    order, its items and settings, set orders.alert_sent_at, read / drop device rows.
-- =====================================================================

create table if not exists public.push_subscriptions (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  endpoint   text not null unique check (endpoint ~ '^https://' and length(endpoint) <= 1000),
  p256dh     text not null check (length(p256dh) between 20 and 200),
  auth       text not null check (length(auth) between 8 and 100),
  user_agent text check (length(user_agent) <= 300),
  created_at timestamptz not null default now()
);
comment on table public.push_subscriptions is 'Devices that get a notification for every new order. Rows are managed with save/remove_push_subscription.';
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;

-- staff see their own devices (the screen shows "notifications on for this phone")
drop policy if exists push_own_read on public.push_subscriptions;
create policy push_own_read on public.push_subscriptions for select to authenticated
  using (user_id = auth.uid() and public.my_role() is not null);
grant select on public.push_subscriptions to authenticated;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.my_role() is null then
    raise exception 'Only staff can turn on order notifications' using errcode = '42501';
  end if;
  -- the same browser may have been registered by another login before: it now belongs to this one
  delete from public.push_subscriptions where endpoint = p_endpoint;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300));
  return true;
exception when check_violation then
  raise exception 'INVALID_INPUT' using errcode = 'P0001';
end;
$$;
revoke all on function public.save_push_subscription(text, text, text, text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;

create or replace function public.remove_push_subscription(p_endpoint text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
  return found;
end;
$$;
revoke all on function public.remove_push_subscription(text) from public, anon;
grant execute on function public.remove_push_subscription(text) to authenticated;

insert into public.settings (key, value, is_public) values ('push_public_key', '', true)
on conflict (key) do nothing;

-- the Edge Function new-order-alert (service_role)
grant select on public.orders, public.order_items, public.settings, public.staff to service_role;
grant update (alert_sent_at) on public.orders to service_role;
grant select, delete on public.push_subscriptions to service_role;


-- technical keys can't be changed from the Settings screen
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
