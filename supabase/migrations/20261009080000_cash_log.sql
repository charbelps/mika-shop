-- =====================================================================
-- Mika Shop: migration 29, cash reconciliation (Phase 2): what the driver and the delivery
-- company owe for delivered orders, and the money Mika received from them.
--  * cash_log (planned in CLAUDE.md section 5): one row each time Mika receives cash from our
--    driver or from the delivery company: which orders, expected, received, difference, note.
--  * orders.cash_log_id: the settlement an order's cash was handed over in (empty = still owed).
--    Owed = delivered orders (delivered_at set) whose cash isn't settled yet; the amount owed per
--    order is the cash recorded as collected at delivery (cash_collected).
--  * staff_settle_cash(source, driver, orders, received, note): ADMIN; checks every order really
--    is a delivered, not yet settled order of that driver / of the company. The difference
--    (received - expected) is saved, e.g. the company's own fee or missing cash, never decided here.
--  * Rights: ADMIN reads, OWNER reads (view only); nobody writes directly.
--  * Setting delivery_company_name (private, empty): printed on the handover sheet.
-- =====================================================================

create table public.cash_log (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  source     text not null check (source in ('DRIVER', 'COMPANY')),
  driver_id  uuid references public.staff (user_id) on delete set null,
  order_ids  bigint[] not null check (cardinality(order_ids) between 1 and 500),
  expected   numeric(10,2) not null check (expected >= 0),
  received   numeric(10,2) not null check (received >= 0),
  difference numeric(10,2) not null,
  note       text check (note is null or length(note) <= 300),
  by_user    uuid references auth.users (id) on delete set null
);
comment on table public.cash_log is 'Cash received from our driver or the delivery company for delivered orders (difference = received - expected).';
create index cash_log_created_idx on public.cash_log (created_at desc);

alter table public.orders add column if not exists cash_log_id bigint references public.cash_log (id) on delete restrict;
create index if not exists orders_cash_open_idx on public.orders (carrier, driver_id) where delivered_at is not null and cash_log_id is null;

alter table public.cash_log enable row level security;
create policy cash_log_admin on public.cash_log for all to authenticated
  using ((select public.my_role()) = 'ADMIN') with check ((select public.my_role()) = 'ADMIN');
create policy cash_log_owner_read on public.cash_log for select to authenticated
  using ((select public.my_role()) = 'OWNER');
grant select on public.cash_log to authenticated;

create or replace function public.staff_settle_cash(
  p_source text, p_driver_id uuid, p_order_ids bigint[], p_received numeric, p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_bad bigint;
  v_n int;
  v_expected numeric(10,2);
  v_id bigint;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can record cash' using errcode = '42501';
  end if;
  if p_source is null or p_source not in ('DRIVER', 'COMPANY')
     or (p_source = 'DRIVER') <> (p_driver_id is not null)
     or p_order_ids is null or cardinality(p_order_ids) = 0 or cardinality(p_order_ids) > 500
     or length(coalesce(v_note, '')) > 300 then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  if p_received is null or p_received < 0 or p_received > 1000000 or p_received <> round(p_received, 2) then
    raise exception 'BAD_CASH' using errcode = 'P0001';
  end if;

  -- lock the orders, then check each one belongs to this driver / the company and is still owed
  perform 1 from public.orders where id = any (p_order_ids) order by id for update;
  select x into v_bad from unnest(p_order_ids) x
   where not exists (select 1 from public.orders o
                     where o.id = x and o.delivered_at is not null and o.cash_log_id is null
                       and o.carrier = p_source
                       and (p_source = 'COMPANY' or o.driver_id = p_driver_id))
   limit 1;
  if v_bad is not null then
    raise exception 'CASH_ORDER_INVALID' using errcode = 'P0001', detail = v_bad::text;
  end if;

  select count(*), coalesce(sum(coalesce(cash_collected, 0)), 0) into v_n, v_expected
    from public.orders where id = any (p_order_ids);
  insert into public.cash_log (source, driver_id, order_ids, expected, received, difference, note, by_user)
  values (p_source, p_driver_id, (select array_agg(distinct x order by x) from unnest(p_order_ids) x),
          v_expected, p_received, p_received - v_expected, v_note, auth.uid())
  returning id into v_id;
  update public.orders set cash_log_id = v_id where id = any (p_order_ids);
  return jsonb_build_object('id', v_id, 'orders', v_n, 'expected', v_expected, 'received', p_received, 'difference', p_received - v_expected);
end;
$$;
revoke all on function public.staff_settle_cash(text, uuid, bigint[], numeric, text) from public, anon;
grant execute on function public.staff_settle_cash(text, uuid, bigint[], numeric, text) to authenticated;

insert into public.settings (key, value, is_public) values ('delivery_company_name', '', false)
on conflict (key) do nothing;
