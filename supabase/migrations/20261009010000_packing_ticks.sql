-- =====================================================================
-- Mika Shop: migration 22, packing tab (Phase 1c, P1; Charbel 9 Oct: ticks shared).
--  * order_items.picked  : taken from the shelf (tick on the combined pick list)
--    order_items.checked : put in this order's box (tick on the order card)
--    Ticks are a memory aid: they never block "Packed". Shared, so Mika can start on the
--    laptop and finish on the phone; the parents (OWNER) see the progress read-only.
--  * staff_tick_items(item_ids, field, value): ADMIN only; only items of orders that are still
--    NEW or CONFIRMED (a packed / cancelled order's ticks can't change any more).
--  * order_items joins the realtime publication, so ticks show live on the other device.
-- Additive only: two new columns with default false, nothing dropped or rewritten.
-- =====================================================================

alter table public.order_items
  add column if not exists picked  boolean not null default false,
  add column if not exists checked boolean not null default false;
comment on column public.order_items.picked  is 'Packing tab: taken from the shelf (pick list tick).';
comment on column public.order_items.checked is 'Packing tab: put in the box (order card tick).';

create or replace function public.staff_tick_items(p_item_ids bigint[], p_field text, p_value boolean)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  if public.my_role() is distinct from 'ADMIN' then
    raise exception 'Only ADMIN can pack orders' using errcode = '42501';
  end if;
  if p_field is null or p_field not in ('picked', 'checked') or p_value is null
     or p_item_ids is null or cardinality(p_item_ids) = 0 or cardinality(p_item_ids) > 500 then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  update public.order_items i
     set picked  = case when p_field = 'picked'  then p_value else i.picked  end,
         checked = case when p_field = 'checked' then p_value else i.checked end
    from public.orders o
   where i.id = any (p_item_ids)
     and o.id = i.order_id
     and o.status in ('NEW', 'CONFIRMED');
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.staff_tick_items(bigint[], text, boolean) from public, anon;
grant execute on function public.staff_tick_items(bigint[], text, boolean) to authenticated;

-- Realtime: ticks reach the other device live (RLS still applies).
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'order_items') then
    alter publication supabase_realtime add table public.order_items;
  end if;
end $$;
