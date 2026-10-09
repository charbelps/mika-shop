-- =====================================================================
-- Mika Shop: migration 26, "Tell me when it's back" (Phase 2, F4; 12b #31).
--  * stock_alerts: a customer leaves a phone number (+ optional name) on a sold-out product or
--    option. One open request per phone + product + option. Never deleted: once Mika has sent
--    the WhatsApp, the request is marked notified (date + who), and kept as history.
--  * request_stock_alert(...): the ONLY way visitors can add one (validation + honeypot, at most
--    20 open requests per phone). Visitors can never read requests (not even their own).
--  * staff_stock_alerts_done(ids, done): ADMIN marks requests as notified (or back to waiting).
--  * Rights: ADMIN reads everything; OWNER reads (view only); nobody else.
--  * Setting whatsapp_back_en / _ar: the message Mika sends (empty = the standard sentence).
-- =====================================================================

create table public.stock_alerts (
  id          bigint generated always as identity primary key,
  sku         text not null references public.products (sku) on update cascade on delete restrict,
  variant_id  bigint references public.variants (id) on delete restrict,
  phone       text not null check (phone ~ '^\+961[0-9]{7,8}$'),
  name        text check (name is null or length(name) between 1 and 80),
  lang        text not null default 'en' check (lang in ('en', 'ar')),
  created_at  timestamptz not null default now(),
  notified_at timestamptz,
  notified_by uuid references auth.users (id) on delete set null
);
comment on table public.stock_alerts is 'Customers waiting for a sold-out product / option. Added only through request_stock_alert; staff mark them notified.';
-- one open request per phone + product + option (variant 0 = the product without options)
create unique index stock_alerts_open_uniq on public.stock_alerts (sku, coalesce(variant_id, 0), phone)
  where notified_at is null;
create index stock_alerts_open_sku_idx on public.stock_alerts (sku) where notified_at is null;
create index stock_alerts_phone_idx on public.stock_alerts (phone);

alter table public.stock_alerts enable row level security;
create policy stock_alerts_admin on public.stock_alerts for all to authenticated
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');
create policy stock_alerts_owner_read on public.stock_alerts for select to authenticated
  using ((select public.my_role()) = 'OWNER');
grant select on public.stock_alerts to authenticated;

-- ---------- visitors: ask to be told ----------
create or replace function public.request_stock_alert(
  p_sku text, p_variant_id bigint, p_phone text, p_name text, p_lang text, p_honeypot text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone   text := public.normalize_phone(p_phone);
  v_name    text := nullif(trim(coalesce(p_name, '')), '');
  v_product public.products;
  v_variant public.variants;
  v_open    int;
begin
  if coalesce(trim(p_honeypot), '') <> '' then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';   -- spam trap filled: say nothing more
  end if;
  if v_phone is null then
    raise exception 'INVALID_PHONE' using errcode = 'P0001';
  end if;
  if length(coalesce(v_name, '')) > 80 or coalesce(p_lang, '') not in ('en', 'ar') then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;

  select * into v_product from public.products where sku = trim(coalesce(p_sku, '')) and active;
  if not found then
    raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001';
  end if;
  if p_variant_id is null then
    -- a product with options needs the option (the shop always sends it)
    if v_product.has_variants then
      raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001';
    end if;
  else
    select * into v_variant from public.variants
      where id = p_variant_id and sku = v_product.sku and active;
    if not found or not v_product.has_variants then
      raise exception 'ITEM_UNAVAILABLE' using errcode = 'P0001';
    end if;
  end if;

  select count(*) into v_open from public.stock_alerts where phone = v_phone and notified_at is null;
  if v_open >= 20 then
    raise exception 'TOO_MANY_ALERTS' using errcode = 'P0001';
  end if;

  insert into public.stock_alerts (sku, variant_id, phone, name, lang)
  values (v_product.sku, p_variant_id, v_phone, v_name, p_lang)
  on conflict (sku, (coalesce(variant_id, 0)), phone) where notified_at is null do update
    set name = coalesce(excluded.name, public.stock_alerts.name), lang = excluded.lang;
  -- same answer whether it is new or was already there (nothing to learn about other people)
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.request_stock_alert(text, bigint, text, text, text, text) from public;
grant execute on function public.request_stock_alert(text, bigint, text, text, text, text) to anon, authenticated;

-- ---------- staff: mark as notified (or back to waiting) ----------
create or replace function public.staff_stock_alerts_done(p_ids bigint[], p_done boolean)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can change back-in-stock requests' using errcode = '42501';
  end if;
  if p_ids is null or cardinality(p_ids) = 0 or cardinality(p_ids) > 500 or p_done is null then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  if p_done then
    update public.stock_alerts set notified_at = now(), notified_by = auth.uid()
      where id = any (p_ids) and notified_at is null;
  else
    -- back to waiting, unless the same person already asked again (one open request each)
    update public.stock_alerts a set notified_at = null, notified_by = null
      where a.id = any (p_ids) and a.notified_at is not null
        and not exists (select 1 from public.stock_alerts b
                        where b.notified_at is null and b.sku = a.sku and b.phone = a.phone
                          and coalesce(b.variant_id, 0) = coalesce(a.variant_id, 0));
  end if;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.staff_stock_alerts_done(bigint[], boolean) from public, anon;
grant execute on function public.staff_stock_alerts_done(bigint[], boolean) to authenticated;

-- ---------- the WhatsApp message Mika sends ----------
insert into public.settings (key, value, is_public) values
  ('whatsapp_back_en', '', false),
  ('whatsapp_back_ar', '', false)
on conflict (key) do nothing;
