-- =====================================================================
-- Mika Shop: migration 5, fix log_stock_change().
-- The first version read new.id directly, but products has no id column
-- (only variants do), so saving a product without variants failed (42703).
-- Read the variant id through jsonb instead, which works for both tables.
-- =====================================================================

create or replace function public.log_stock_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_change integer;
begin
  if tg_op = 'INSERT' then
    v_change := new.stock;
  else
    v_change := new.stock - old.stock;
  end if;
  if v_change is null or v_change = 0 then
    return new;
  end if;

  insert into public.stock_log (sku, variant_id, change, stock_after, reason, order_id, by_user)
  values (
    new.sku,
    case when tg_table_name = 'variants' then (to_jsonb(new)->>'id')::bigint end,
    v_change,
    new.stock,
    coalesce(nullif(current_setting('app.stock_reason', true), ''), 'MANUAL'),
    nullif(current_setting('app.stock_order_id', true), '')::bigint,
    auth.uid()
  );
  return new;
end;
$$;
revoke all on function public.log_stock_change() from public;
