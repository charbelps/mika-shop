-- =====================================================================
-- Mika Shop: protect push registrations and remember each staff member's language.
-- The earlier save function allowed a logged-in staff member to replace a device
-- registration owned by someone else if they knew its endpoint.
-- =====================================================================

alter table public.push_subscriptions
  add column if not exists lang text not null default 'en' check (lang in ('en', 'ar'));

create or replace function public.save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text,
  p_lang text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows int;
begin
  if public.my_role() is null then
    raise exception 'Only staff can turn on order notifications' using errcode = '42501';
  end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000
     or p_p256dh is null or length(p_p256dh) not between 20 and 200
     or p_auth is null or length(p_auth) not between 8 and 100
     or p_lang is null or p_lang not in ('en', 'ar') then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;

  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent, lang)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300), p_lang)
  on conflict (endpoint) do update
    set p256dh = excluded.p256dh,
        auth = excluded.auth,
        user_agent = excluded.user_agent,
        lang = excluded.lang
    where public.push_subscriptions.user_id = auth.uid();
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'ENDPOINT_IN_USE' using errcode = 'P0001';
  end if;
  return true;
end;
$$;
revoke all on function public.save_push_subscription(text, text, text, text, text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text, text) to authenticated;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text default null)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  return public.save_push_subscription(p_endpoint, p_p256dh, p_auth, p_user_agent, 'en');
end;
$$;
revoke all on function public.save_push_subscription(text, text, text, text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
