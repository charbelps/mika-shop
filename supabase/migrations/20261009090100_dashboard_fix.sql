-- =====================================================================
-- Mika Shop: migration 31, fix for migration 30 (staff_dashboard).
-- Migration 30 created the function, but its "sales" block put a total inside another total,
-- which Postgres refuses at run time ("aggregate function calls cannot be nested"), so every
-- call failed. Same function, the sales block now adds up per period first. Nothing else changes.
-- (Migration 30 is not edited: it already ran.)
-- =====================================================================

create or replace function public.staff_dashboard(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz constant text := 'Asia/Beirut';
  v_now timestamptz := now();
  v_today timestamptz := date_trunc('day', v_now at time zone v_tz) at time zone v_tz;
  v_week timestamptz := date_trunc('week', v_now at time zone v_tz) at time zone v_tz;
  v_month timestamptz := date_trunc('month', v_now at time zone v_tz) at time zone v_tz;
  v_from timestamptz;
  v_low_txt text;
  v_low integer;
begin
  if coalesce(public.my_role(), '') not in ('ADMIN', 'OWNER') then
    raise exception 'Only ADMIN and OWNER can see the dashboard' using errcode = '42501';
  end if;
  if p_days is null or p_days not in (7, 30, 90, 365) then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  v_from := v_today - make_interval(days => p_days - 1);   -- the last N days, today included
  select trim(value) into v_low_txt from public.settings where key = 'low_stock_threshold';
  v_low := case when v_low_txt ~ '^[0-9]{1,4}$' then v_low_txt::integer end;

  return jsonb_build_object(
    'generated_at', v_now,
    'days', p_days,
    'low_stock_threshold', v_low,
    'sales', (
      select jsonb_object_agg(t.name, jsonb_build_object('orders', t.orders, 'items', t.items, 'delivery', t.delivery, 'total', t.total))
      from (select p.name, count(o.id) as orders, coalesce(sum(o.subtotal), 0) as items,
                   coalesce(sum(o.delivery_fee), 0) as delivery, coalesce(sum(o.total), 0) as total
            from (values ('today', v_today), ('week', v_week), ('month', v_month), ('range', v_from)) p(name, since)
            left join public.orders o on o.created_at >= p.since and o.status not in ('CANCELLED', 'RETURNED')
            group by p.name) t
    ),
    'by_status', (
      select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (
        select o.status, count(*) as n from public.orders o
        where o.status in ('NEW', 'CONFIRMED', 'PACKED', 'OUT_FOR_DELIVERY', 'WITH_COMPANY', 'FAILED_ATTEMPT')
           or o.created_at >= v_from
        group by o.status) s
    ),
    'best_sellers', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.qty desc, x.sales desc), '[]'::jsonb) from (
        select i.sku, max(i.name_en) as name_en, max(i.name_ar) as name_ar, sum(i.qty)::integer as qty,
               sum(i.line_total) as sales, count(distinct i.order_id)::integer as orders
        from public.order_items i join public.orders o on o.id = i.order_id
        where o.created_at >= v_from and o.status not in ('CANCELLED', 'RETURNED')
        group by i.sku
        order by sum(i.qty) desc, sum(i.line_total) desc
        limit 10) x
    ),
    'slow_items', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.stock desc, x.name_en), '[]'::jsonb) from (
        select p.sku, p.name_en, p.name_ar,
               (case when p.has_variants then coalesce(vs.stock, 0) else p.stock end)::integer as stock,
               ls.last_sold
        from public.products p
        left join lateral (select sum(v.stock) as stock from public.variants v where v.sku = p.sku and v.active) vs on true
        left join lateral (select max(o.created_at) as last_sold
                           from public.order_items i join public.orders o on o.id = i.order_id
                           where i.sku = p.sku and o.status not in ('CANCELLED', 'RETURNED')) ls on true
        where p.active
          and (case when p.has_variants then coalesce(vs.stock, 0) else p.stock end) > 0
          and p.created_at < v_from
          and (ls.last_sold is null or ls.last_sold < v_from)
        order by 4 desc, p.name_en
        limit 20) x
    ),
    'low_stock', (
      select coalesce(jsonb_agg(to_jsonb(x) order by x.stock, x.name_en), '[]'::jsonb) from (
        select * from (
          select p.sku, p.name_en, p.name_ar, null::text as label_en, null::text as label_ar, p.stock
          from public.products p
          where p.active and not p.has_variants and p.stock <= coalesce(v_low, 0)
          union all
          select v.sku, p.name_en, p.name_ar, v.label_en, v.label_ar, v.stock
          from public.variants v join public.products p on p.sku = v.sku
          where p.active and p.has_variants and v.active and v.stock <= coalesce(v_low, 0)
        ) u
        order by u.stock, u.name_en
        limit 30) x
    ),
    'cash', jsonb_build_object(
      'drivers', (
        select coalesce(jsonb_agg(jsonb_build_object('driver_id', d.driver_id, 'name', s.name, 'owed', d.owed, 'orders', d.n) order by d.owed desc), '[]'::jsonb)
        from (select o.driver_id, sum(coalesce(o.cash_collected, 0)) as owed, count(*)::integer as n
              from public.orders o
              where o.carrier = 'DRIVER' and o.delivered_at is not null and o.cash_log_id is null
              group by o.driver_id) d
        left join public.staff s on s.user_id = d.driver_id
      ),
      'company', (
        select jsonb_build_object('owed', coalesce(sum(coalesce(o.cash_collected, 0)), 0), 'orders', count(*))
        from public.orders o
        where o.carrier = 'COMPANY' and o.delivered_at is not null and o.cash_log_id is null
      ),
      'on_the_way', (
        select jsonb_build_object('to_collect', coalesce(sum(public.amount_to_collect(o)), 0), 'orders', count(*))
        from public.orders o where o.status in ('OUT_FOR_DELIVERY', 'WITH_COMPANY')
      )
    ),
    'governorates', (
      select coalesce(jsonb_agg(to_jsonb(g) order by g.items desc), '[]'::jsonb) from (
        select o.governorate,
               (select max(z.governorate_ar) from public.delivery_zones z where z.governorate = o.governorate) as governorate_ar,
               count(*)::integer as orders, sum(o.subtotal) as items
        from public.orders o
        where o.created_at >= v_from and o.status not in ('CANCELLED', 'RETURNED')
        group by o.governorate) g
    )
  );
end;
$$;
revoke all on function public.staff_dashboard(integer) from public, anon;
grant execute on function public.staff_dashboard(integer) to authenticated;
