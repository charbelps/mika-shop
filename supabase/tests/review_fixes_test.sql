-- =====================================================================
-- Mika Shop: review fixes of 9 Oct (migration 25). ROLLED BACK, leaves nothing.
--  * product editor never writes back a stale stock (stock_seen / STOCK_CHANGED)
--  * visitors / logins have no TRUNCATE / REFERENCES / TRIGGER / MAINTAIN on any table
--  * row security rules evaluate my_role() / auth.uid() once per query
-- Run:  supabase db query --linked -f supabase/tests/review_fixes_test.sql
-- (The rules themselves are re-checked by rls_test.sql.)
-- =====================================================================
begin;

create temp table _r (n serial, who text, test text, expected text, got text);
grant all on _r to anon, authenticated;
grant all on sequence _r_n_seq to anon, authenticated;

create function pg_temp.try(p_who text, p_test text, p_sql text, p_expected text)
returns void language plpgsql as $$
declare v_n bigint; v_got text;
begin
  begin
    if p_sql ~* '^\s*select' then
      execute format('select count(*) from (%s) q', p_sql) into v_n;
    else
      execute p_sql;
      get diagnostics v_n = row_count;
    end if;
    v_got := 'rows:' || v_n;
  exception when others then
    v_got := 'error:' || sqlstate || case when sqlstate = 'P0001' then ':' || sqlerrm else '' end;
  end;
  insert into pg_temp._r (who, test, expected, got) values (p_who, p_test, p_expected, v_got);
end $$;
create function pg_temp.claims(p_uid uuid) returns text language sql as $$
  select case when p_uid is null then '{"role":"anon"}'
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end $$;
-- reads the stock as it is now (a volatile helper, so every check sees the latest value)
create function pg_temp.stock_of(p_sku text) returns int language plpgsql volatile as $$
declare v int; begin select stock into v from public.products where sku = p_sku; return v; end $$;
create function pg_temp.vstock(p_sku text) returns int language plpgsql volatile as $$
declare v int; begin select stock into v from public.variants where sku = p_sku; return v; end $$;
create function pg_temp.vid(p_sku text) returns bigint language plpgsql volatile as $$
declare v bigint; begin select id into v from public.variants where sku = p_sku; return v; end $$;
grant execute on function pg_temp.stock_of(text), pg_temp.vstock(text), pg_temp.vid(text) to authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000c1', 'reviewtest-admin@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000c1', 'REVIEWTEST admin', 'ADMIN');

-- ---------- 1. stale stock ----------
set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000c1'), true);
select pg_temp.try('admin', 'create RFTEST-1 (stock 5)',
  $q$select public.admin_save_product('{"sku":"RFTEST-1","name_en":"Bowl","price":"10","stock":"5"}'::jsonb, '[]'::jsonb, true)$q$, 'rows:1');
select pg_temp.try('admin', 'create RFTEST-2 with one option (stock 4)',
  $q$select public.admin_save_product('{"sku":"RFTEST-2","name_en":"Shirt","price":"20","has_variants":true}'::jsonb,
     '[{"label_en":"Size S","stock":"4"}]'::jsonb, true)$q$, 'rows:1');
reset role;

-- an order takes 1 bowl and 1 shirt while Mika has both editors open
select set_config('app.stock_reason', 'SALE', true);
update public.products set stock = stock - 1 where sku = 'RFTEST-1';
update public.variants set stock = stock - 1 where sku = 'RFTEST-2';
select set_config('app.stock_reason', '', true);

set local role authenticated;
select set_config('request.jwt.claims', pg_temp.claims('00000000-0000-4000-8000-0000000000c1'), true);
select pg_temp.try('admin', 'save with untouched stock field (5, seen 5): accepted',
  $q$select public.admin_save_product('{"sku":"RFTEST-1","name_en":"Bowl v2","price":"10","stock":"5","stock_seen":"5"}'::jsonb, '[]'::jsonb, false)$q$, 'rows:1');
select pg_temp.try('admin', '... keeps the stock the order left (4), name saved',
  $q$select 1 from public.products where sku = 'RFTEST-1' and name_en = 'Bowl v2' and pg_temp.stock_of('RFTEST-1') = 4$q$, 'rows:1');
select pg_temp.try('admin', '... and logs no stock change',
  $q$select 1 from public.stock_log where sku = 'RFTEST-1'$q$, 'rows:2');
select pg_temp.try('admin', 'changed stock field (10) over a moved stock (seen 5): STOCK_CHANGED',
  $q$select public.admin_save_product('{"sku":"RFTEST-1","name_en":"Bowl v3","price":"10","stock":"10","stock_seen":"5"}'::jsonb, '[]'::jsonb, false)$q$, 'error:P0001:STOCK_CHANGED');
select pg_temp.try('admin', '... nothing saved (name and stock unchanged)',
  $q$select 1 from public.products where sku = 'RFTEST-1' and name_en = 'Bowl v2' and pg_temp.stock_of('RFTEST-1') = 4$q$, 'rows:1');
select pg_temp.try('admin', 'saved again with the fresh number (seen 4): 10 accepted',
  $q$select public.admin_save_product('{"sku":"RFTEST-1","name_en":"Bowl v3","price":"10","stock":"10","stock_seen":"4"}'::jsonb, '[]'::jsonb, false)$q$, 'rows:1');
select pg_temp.try('admin', '... stock 10, MANUAL +6 logged',
  $q$select 1 from public.stock_log where sku = 'RFTEST-1' and change = 6 and stock_after = 10 and reason = 'MANUAL' and pg_temp.stock_of('RFTEST-1') = 10$q$, 'rows:1');
select pg_temp.try('admin', 'no stock_seen sent (older callers): stock set as before',
  $q$select public.admin_save_product('{"sku":"RFTEST-1","name_en":"Bowl v3","price":"10","stock":"7"}'::jsonb, '[]'::jsonb, false)$q$, 'rows:1');
select pg_temp.try('admin', '... stock 7',
  $q$select 1 where pg_temp.stock_of('RFTEST-1') = 7$q$, 'rows:1');
select pg_temp.try('admin', 'option: untouched field (4, seen 4) keeps 3',
  $q$select public.admin_save_product('{"sku":"RFTEST-2","name_en":"Shirt","price":"20","has_variants":true}'::jsonb,
     jsonb_build_array(jsonb_build_object('id', pg_temp.vid('RFTEST-2'), 'label_en', 'Size S', 'stock', 4, 'stock_seen', 4)), false)$q$, 'rows:1');
select pg_temp.try('admin', '... option stock still 3',
  $q$select 1 where pg_temp.vstock('RFTEST-2') = 3$q$, 'rows:1');
select pg_temp.try('admin', 'option: changed field (6) over a moved stock: STOCK_CHANGED',
  $q$select public.admin_save_product('{"sku":"RFTEST-2","name_en":"Shirt","price":"20","has_variants":true}'::jsonb,
     jsonb_build_array(jsonb_build_object('id', pg_temp.vid('RFTEST-2'), 'label_en', 'Size S', 'stock', 6, 'stock_seen', 4)), false)$q$, 'error:P0001:STOCK_CHANGED');
select pg_temp.try('admin', 'option: with the fresh number (seen 3): 6 accepted',
  $q$select public.admin_save_product('{"sku":"RFTEST-2","name_en":"Shirt","price":"20","has_variants":true}'::jsonb,
     jsonb_build_array(jsonb_build_object('id', pg_temp.vid('RFTEST-2'), 'label_en', 'Size S', 'stock', 6, 'stock_seen', 3)), false)$q$, 'rows:1');
select pg_temp.try('admin', '... option stock 6',
  $q$select 1 where pg_temp.vstock('RFTEST-2') = 6$q$, 'rows:1');
select pg_temp.try('admin', 'missing product still PRODUCT_NOT_FOUND',
  $q$select public.admin_save_product('{"sku":"RFTEST-404","name_en":"X","price":"1","stock":"1","stock_seen":"1"}'::jsonb, '[]'::jsonb, false)$q$, 'error:P0001:PRODUCT_NOT_FOUND');
select pg_temp.try('admin', 'other product''s option still VARIANT_NOT_FOUND',
  $q$select public.admin_save_product('{"sku":"RFTEST-1","name_en":"Bowl","price":"10","stock":"7"}'::jsonb,
     jsonb_build_array(jsonb_build_object('id', pg_temp.vid('RFTEST-2'), 'label_en', 'hack', 'stock', 0)), false)$q$, 'error:P0001:VARIANT_NOT_FOUND');
reset role;

set local role anon;
select set_config('request.jwt.claims', pg_temp.claims(null), true);
select pg_temp.try('anon', 'save product still refused',
  $q$select public.admin_save_product('{"sku":"RFTEST-1","name_en":"Hacked","price":"0"}'::jsonb, '[]'::jsonb, false)$q$, 'error:42501');
reset role;

-- ---------- 2. table rights ----------
select pg_temp.try('grants', 'no public table gives anon / authenticated TRUNCATE, REFERENCES, TRIGGER or MAINTAIN',
  $q$select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
     cross join (values ('anon'), ('authenticated')) r(role)
     cross join (values ('TRUNCATE'), ('REFERENCES'), ('TRIGGER'), ('MAINTAIN')) p(priv)
     where s.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p') and has_table_privilege(r.role, c.oid, p.priv)$q$, 'rows:0');
select pg_temp.try('grants', 'anon still reads the catalog (products, settings)',
  $q$select 1 where has_table_privilege('anon', 'public.products', 'SELECT') and has_table_privilege('anon', 'public.settings', 'SELECT')$q$, 'rows:1');
select pg_temp.try('grants', 'anon still has no SELECT on orders / customers',
  $q$select 1 where has_table_privilege('anon', 'public.orders', 'SELECT') or has_table_privilege('anon', 'public.customers', 'SELECT')$q$, 'rows:0');
select pg_temp.try('grants', 'logins keep select/insert/update/delete on orders (RLS decides)',
  $q$select 1 where has_table_privilege('authenticated', 'public.orders', 'SELECT,INSERT,UPDATE,DELETE')$q$, 'rows:1');
select pg_temp.try('grants', 'Edge Functions (service_role) keep their rights',
  $q$select 1 where has_table_privilege('service_role', 'public.orders', 'SELECT') and has_table_privilege('service_role', 'public.push_subscriptions', 'DELETE')$q$, 'rows:1');
create table public._review_probe (x int);
select pg_temp.try('grants', 'a NEW table gets no TRUNCATE / TRIGGER for anon / authenticated',
  $q$select 1 where has_table_privilege('anon', 'public._review_probe', 'TRUNCATE') or has_table_privilege('authenticated', 'public._review_probe', 'TRIGGER')
     or has_table_privilege('anon', 'public._review_probe', 'MAINTAIN')$q$, 'rows:0');

-- ---------- 3. policies evaluate the role once per query ----------
select pg_temp.try('policies', 'every my_role() / auth.uid() in public policies is wrapped in (select ...)',
  $q$select 1 from pg_policies where schemaname = 'public'
     and replace(replace(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                 'SELECT my_role() AS my_role', ''), 'SELECT auth.uid() AS uid', '') ~ '(my_role|uid)\(\)'$q$, 'rows:0');
select pg_temp.try('policies', 'none of the 24 policies of 9 Oct was lost (later migrations add more)',
  $q$select 1 where (select count(*) from pg_policies where schemaname = 'public') >= 24$q$, 'rows:1');

select n, who, test, expected, got, (expected = got) as pass from _r order by (expected = got), n;
rollback;
