-- =====================================================================
-- Mika Shop launch readiness check. READ-ONLY: it only looks, it changes nothing.
-- Lists what is still missing before the shop can open. Run it any time, on TEST or LIVE:
--   supabase db query --linked -f supabase\launch\launch_check.sql
-- Status: MISSING = must be done before opening, CHECK = look at it, OK = fine,
--         INFO = for your information only.
-- =====================================================================
with
s as (select key, value from public.settings),
v as (select coalesce((select value from s where key = k), '') as val, k from unnest(array[
  'shop_name_en','shop_name_ar','currency','whatsapp_number','order_prefix','low_stock_threshold',
  'return_policy_en','return_policy_ar','whish_number','omt_details','unpaid_cancel_hours',
  'push_public_key','order_alert_url','delivery_company_name','fee_tbc_enabled']) as k),
val as (select k, val from v),
z as (select * from public.delivery_zones),
st as (select role, count(*) filter (where active) as n from public.staff group by role),
checks(sort, area, item, status, detail) as (
  -- ---------- shop settings (Settings -> Shop) ----------
  select 10, 'Settings', 'Shop name (English + Arabic)',
    case when (select count(*) from val where k in ('shop_name_en','shop_name_ar') and val <> '') = 2 then 'OK' else 'MISSING' end,
    (select string_agg(k, ', ') from val where k in ('shop_name_en','shop_name_ar') and val = '')
  union all select 11, 'Settings', 'Currency', case when (select val from val where k = 'currency') <> '' then 'OK' else 'MISSING' end,
    nullif((select val from val where k = 'currency'), '')
  union all select 12, 'Settings', 'WhatsApp number (also "Call us")', case when (select val from val where k = 'whatsapp_number') <> '' then 'OK' else 'MISSING' end, null
  union all select 13, 'Settings', 'Order number prefix', case when (select val from val where k = 'order_prefix') <> '' then 'OK' else 'CHECK' end,
    case when (select val from val where k = 'order_prefix') = '' then 'empty = order numbers without letters (10001)' else (select val from val where k = 'order_prefix') end
  union all select 14, 'Settings', 'Low-stock warning level', case when (select val from val where k = 'low_stock_threshold') <> '' then 'OK' else 'CHECK' end,
    case when (select val from val where k = 'low_stock_threshold') = '' then 'empty = only sold-out items are listed as low stock' end
  union all select 15, 'Settings', 'Return policy (English + Arabic)',
    case when (select count(*) from val where k in ('return_policy_en','return_policy_ar') and val <> '') = 2 then 'OK' else 'CHECK' end,
    (select string_agg(k, ', ') from val where k in ('return_policy_en','return_policy_ar') and val = '')
  union all select 16, 'Settings', 'Whish / OMT offered',
    case when (select count(*) from val where k in ('whish_number','omt_details') and val <> '') > 0 then 'OK' else 'CHECK' end,
    case when (select count(*) from val where k in ('whish_number','omt_details') and val <> '') = 0 then 'neither is set: customers can only pay cash on delivery'
         else (select string_agg(case k when 'whish_number' then 'Whish' else 'OMT' end, ' + ') from val where k in ('whish_number','omt_details') and val <> '') end
  union all select 17, 'Settings', 'Hours before unpaid Whish / OMT orders are cancelled',
    case when (select val from val where k = 'unpaid_cancel_hours') <> '' then 'OK'
         when (select count(*) from val where k in ('whish_number','omt_details') and val <> '') > 0 then 'MISSING' else 'INFO' end,
    case when (select val from val where k = 'unpaid_cancel_hours') = '' then 'empty = unpaid orders are never cancelled automatically'
         else (select val from val where k = 'unpaid_cancel_hours') || ' hours' end
  union all select 18, 'Settings', 'Delivery company name (handover sheet)',
    case when (select val from val where k = 'delivery_company_name') <> '' or not exists (select 1 from z where active and default_carrier = 'COMPANY') then 'OK' else 'CHECK' end,
    case when exists (select 1 from z where active and default_carrier = 'COMPANY') and (select val from val where k = 'delivery_company_name') = '' then 'some areas use the company but it has no name' end
  union all select 19, 'Settings', '"Fee to be confirmed" emergency switch',
    case when (select val from val where k = 'fee_tbc_enabled') = 'on' then 'CHECK' else 'OK' end,
    case when (select val from val where k = 'fee_tbc_enabled') = 'on' then 'ON: areas without a fee accept orders' else 'off (normal)' end
  union all select 20, 'Settings', 'Customer texts typed by Mika (payment, messages, privacy...)', 'INFO',
    (select count(*) filter (where value <> '') || ' of ' || count(*) || ' filled; empty ones use the standard text'
       from s where key ~ '(_en|_ar)$' and key not in ('shop_name_en','shop_name_ar','return_policy_en','return_policy_ar'))
  -- ---------- delivery areas (Settings -> Delivery areas) ----------
  union all select 30, 'Delivery', 'Offered areas without a delivery fee',
    case when exists (select 1 from z where active and fee is null) then 'MISSING' else 'OK' end,
    (select count(*) || ': ' || string_agg(district, ', ' order by sort, district) from z where active and fee is null)
  union all select 31, 'Delivery', 'Offered areas without delivery days',
    case when exists (select 1 from z where active and coalesce(eta_days, '') = '') then 'CHECK' else 'OK' end,
    (select count(*)::text from z where active and coalesce(eta_days, '') = '')
  union all select 32, 'Delivery', 'Offered areas without "delivered by"',
    case when exists (select 1 from z where active and default_carrier is null) then 'CHECK' else 'OK' end,
    (select count(*)::text from z where active and default_carrier is null)
  union all select 33, 'Delivery', 'Areas offered / hidden', 'INFO',
    (select count(*) filter (where active) || ' offered, ' || count(*) filter (where not active) || ' hidden' from z)
  -- ---------- staff ----------
  union all select 40, 'Staff', 'Active ADMIN logins', case when coalesce((select n from st where role = 'ADMIN'), 0) >= 1 then 'OK' else 'MISSING' end,
    coalesce((select n from st where role = 'ADMIN'), 0)::text
  union all select 41, 'Staff', 'Active OWNER logins (parents)', 'INFO', coalesce((select n from st where role = 'OWNER'), 0)::text
  union all select 42, 'Staff', 'Active DRIVER logins',
    case when coalesce((select n from st where role = 'DRIVER'), 0) >= 1 or not exists (select 1 from z where active and default_carrier = 'DRIVER') then 'OK' else 'CHECK' end,
    coalesce((select n from st where role = 'DRIVER'), 0)::text || case when exists (select 1 from z where active and default_carrier = 'DRIVER') and coalesce((select n from st where role = 'DRIVER'), 0) = 0 then ' (some areas use our driver)' else '' end
  -- ---------- products ----------
  union all select 50, 'Products', 'Products on sale', case when exists (select 1 from public.products where active) then 'OK' else 'MISSING' end,
    (select count(*) filter (where active) || ' on sale, ' || count(*) filter (where not active) || ' hidden' from public.products)
  union all select 51, 'Products', 'On sale without a photo', case when exists (select 1 from public.products where active and cardinality(photos) = 0) then 'CHECK' else 'OK' end,
    (select count(*)::text from public.products where active and cardinality(photos) = 0)
  union all select 52, 'Products', 'On sale with Arabic not checked yet', case when exists (select 1 from public.products where active and ar_needs_review) then 'CHECK' else 'OK' end,
    (select count(*)::text from public.products where active and ar_needs_review)
  union all select 53, 'Products', 'Categories', case when exists (select 1 from public.categories where active) then 'OK' else 'MISSING' end,
    (select count(*) filter (where active)::text from public.categories)
  -- ---------- technical (Claude) ----------
  union all select 60, 'Technical', 'Phone notifications key (push_public_key)', case when (select val from val where k = 'push_public_key') <> '' then 'OK' else 'MISSING' end, null
  union all select 61, 'Technical', 'New-order alert address (order_alert_url)', case when (select val from val where k = 'order_alert_url') <> '' then 'OK' else 'MISSING' end,
    nullif((select val from val where k = 'order_alert_url'), '')
  union all select 62, 'Technical', 'Auto-cancel job scheduled',
    case when to_regclass('cron.job') is null then 'CHECK'
         when (xpath('/row/c/text()', query_to_xml('select count(*) as c from cron.job where jobname = ''cancel-unpaid-orders'' and active', false, true, '')))[1]::text = '1' then 'OK' else 'MISSING' end,
    case when to_regclass('cron.job') is null then 'pg_cron not visible here' end
  union all select 63, 'Technical', 'Row security ON for every table',
    case when exists (select 1 from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity) then 'MISSING' else 'OK' end, null
  -- ---------- test data must not be on LIVE ----------
  union all select 70, 'Test data', 'TEST- products / [TEST] categories, areas, orders, requests (must be none on LIVE)',
    case when exists (select 1 from public.products where sku like 'TEST-%') or exists (select 1 from z where governorate like '[TEST]%' or district like '[TEST]%')
           or exists (select 1 from public.orders where name like '[TEST]%') or exists (select 1 from public.categories where name_en like '[TEST]%') then 'CHECK' else 'OK' end,
    (select string_agg(x, ', ') from (
       select count(*) || ' products' as x from public.products where sku like 'TEST-%' having count(*) > 0
       union all select count(*) || ' categories' from public.categories where name_en like '[TEST]%' having count(*) > 0
       union all select count(*) || ' areas' from z where governorate like '[TEST]%' or district like '[TEST]%' having count(*) > 0
       union all select count(*) || ' orders' from public.orders where name like '[TEST]%' having count(*) > 0
       union all select count(*) || ' back-in-stock requests' from public.stock_alerts where name like '[TEST]%' having count(*) > 0) t)
  union all select 71, 'Orders', 'Orders so far', 'INFO', (select count(*)::text from public.orders)
)
select area, item, status, coalesce(detail, '') as detail from checks order by sort;
