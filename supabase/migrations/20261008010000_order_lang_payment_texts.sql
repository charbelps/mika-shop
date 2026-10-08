-- =====================================================================
-- Mika Shop: migration 21 (8 Oct 2026, review of Copilot's A5 / W1).
--  * orders.lang: the language the customer ordered in ('en' / 'ar'; empty for older orders).
--    The shop sends it as p_customer.lang; the New order screen sends the language Mika picks.
--    place_order / staff_place_order hand it to the insert through the transaction-only
--    setting app.order_lang (same pattern as app.stock_reason), so place_order_core is untouched.
--    Used by the WhatsApp status button: the message goes out in the customer's language.
--  * 8 editable payment-instruction texts (A5 gap, 12b #15), public because the shop shows them.
--    Empty = the standard sentence from the language files.
-- Additive only: no rows changed, nothing dropped.
-- =====================================================================

alter table public.orders
  add column if not exists lang text check (lang in ('en', 'ar'));
comment on column public.orders.lang is 'Language the customer ordered in (en / ar). Empty for orders placed before 8 Oct 2026.';

create or replace function public.set_order_lang()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v text := current_setting('app.order_lang', true);
begin
  if new.lang is null and v in ('en', 'ar') then
    new.lang := v;
  end if;
  return new;
end;
$$;
revoke all on function public.set_order_lang() from public, anon, authenticated;

drop trigger if exists orders_set_lang on public.orders;
create trigger orders_set_lang before insert on public.orders
  for each row execute function public.set_order_lang();


-- The shop's checkout: same parameters, same answer as before; now also keeps the language.
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
begin
  if coalesce(trim(p_honeypot), '') <> '' then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';  -- spam trap filled: say nothing more
  end if;
  perform set_config('app.order_lang',
    case when p_customer->>'lang' in ('en', 'ar') then p_customer->>'lang' else '' end, true);
  return public.place_order_core(p_customer, p_items, p_payment, 'WEBSITE', 'NEW') - 'order_id';
end;
$$;
revoke all on function public.place_order(jsonb, jsonb, text, text) from public;
grant execute on function public.place_order(jsonb, jsonb, text, text) to anon, authenticated;


-- Orders Mika takes by phone / Instagram / WhatsApp: same rules as before, plus the language.
create or replace function public.staff_place_order(
  p_customer jsonb,
  p_items jsonb,
  p_payment text,
  p_source text,
  p_notes text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can enter orders' using errcode = '42501';
  end if;
  if p_source is null or p_source not in ('PHONE', 'INSTAGRAM', 'WHATSAPP') then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  perform set_config('app.order_lang',
    case when p_customer->>'lang' in ('en', 'ar') then p_customer->>'lang' else '' end, true);
  return public.place_order_core(p_customer, p_items, p_payment, p_source, 'CONFIRMED', p_notes);
end;
$$;
revoke all on function public.staff_place_order(jsonb, jsonb, text, text, text) from public;
grant execute on function public.staff_place_order(jsonb, jsonb, text, text, text) to authenticated;


-- Whish / OMT instructions Mika can rewrite (checkout = before ordering; confirm = after).
insert into public.settings (key, value, is_public) values
  ('whish_checkout_en', '', true),
  ('whish_checkout_ar', '', true),
  ('whish_confirm_en', '', true),
  ('whish_confirm_ar', '', true),
  ('omt_checkout_en', '', true),
  ('omt_checkout_ar', '', true),
  ('omt_confirm_en', '', true),
  ('omt_confirm_ar', '', true)
on conflict (key) do nothing;
