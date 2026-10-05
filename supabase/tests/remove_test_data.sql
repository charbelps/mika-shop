-- =====================================================================
-- Mika Shop: REMOVE TEST DATA (TEST project).  *** DELETES ROWS ***
-- Do NOT run without Charbel's OK. Run the backup workflow first.
-- Removes only rows marked as test data:
--   orders whose name starts with "[TEST]" (and their items / stock log),
--   products with SKU "TEST-%", categories named "[TEST]%",
--   customers named "[TEST]%".
-- Photos in storage under TEST-*/ must be removed separately (dashboard).
-- =====================================================================
begin;
delete from public.stock_log   where sku like 'TEST-%'
                                  or order_id in (select id from public.orders where name like '[TEST]%');
delete from public.order_items where order_id in (select id from public.orders where name like '[TEST]%');
delete from public.orders      where name like '[TEST]%';
delete from public.customers   where name like '[TEST]%';
delete from public.variants    where sku like 'TEST-%';
delete from public.products    where sku like 'TEST-%';
delete from public.categories  where name_en like '[TEST]%' and parent_id is not null;
delete from public.categories  where name_en like '[TEST]%';
delete from public.delivery_zones where governorate like '[TEST]%';
commit;
