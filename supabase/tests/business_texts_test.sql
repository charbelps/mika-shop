-- =====================================================================
-- Mika Shop: public business text settings (Phase 1c, A5). ROLLED BACK.
-- Run: supabase db query --linked -f supabase/tests/business_texts_test.sql
-- =====================================================================
begin;

create temp table _r (n serial, test text, expected text, got text);
grant all on _r to anon, authenticated;
grant all on sequence _r_n_seq to anon, authenticated;

create function pg_temp.try(p_test text, p_sql text, p_expected text)
returns void language plpgsql as $$
declare v_got text;
begin
  begin
    execute p_sql into v_got;
  exception when others then
    v_got := 'error:' || sqlstate || case when sqlstate = 'P0001' then ':' || sqlerrm else '' end;
  end;
  insert into pg_temp._r (test, expected, got) values (p_test, p_expected, coalesce(v_got, 'null'));
end $$;
create function pg_temp.as_user(p_uid text) returns void language plpgsql as $$
begin
  if p_uid is null then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  else
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  end if;
end $$;
grant execute on function pg_temp.as_user(text) to anon, authenticated;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-4000-8000-0000000000f1', 'textstest-admin@example.test', 'authenticated', 'authenticated'),
  ('00000000-0000-4000-8000-0000000000f2', 'textstest-owner@example.test', 'authenticated', 'authenticated');
insert into public.staff (user_id, name, role) values
  ('00000000-0000-4000-8000-0000000000f1', 'TEXTSTEST admin', 'ADMIN'),
  ('00000000-0000-4000-8000-0000000000f2', 'TEXTSTEST owner', 'OWNER');

select pg_temp.try('all 16 customer text settings exist and are public',
  $q$select count(*)::text from public.settings where key in (
    'shop_intro_en','shop_intro_ar','delivery_payment_en','delivery_payment_ar',
    'checkout_note_en','checkout_note_ar','order_confirmation_en','order_confirmation_ar',
    'whatsapp_ask_en','whatsapp_ask_ar','whatsapp_share_en','whatsapp_share_ar',
    'whatsapp_order_en','whatsapp_order_ar','whatsapp_status_en','whatsapp_status_ar',
    'footer_note_en','footer_note_ar'
  ) and is_public$q$, '18');

set local role anon;
select pg_temp.as_user(null);
select pg_temp.try('visitor reads public business text', $q$select coalesce(value, '') from public.settings where key = 'shop_intro_en'$q$, '');
select pg_temp.try('visitor cannot edit business text', $q$update public.settings set value = 'bad' where key = 'shop_intro_en' returning value$q$, 'error:42501');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000f2');
select pg_temp.try('OWNER sees public business text', $q$select is_public::text from public.settings where key = 'footer_note_ar'$q$, 'true');
select pg_temp.try('OWNER cannot change business text', $q$select public.admin_save_settings('{"shop_intro_en":"bad"}')::text$q$, 'error:42501');
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-4000-8000-0000000000f1');
select pg_temp.try('ADMIN changes English and Arabic messages',
  $q$select public.admin_save_settings('{"shop_intro_en":"A warm local shop.","whatsapp_share_ar":"شوف {name}"}')::text$q$, '2');
select pg_temp.try('English text saved', $q$select value from public.settings where key = 'shop_intro_en'$q$, 'A warm local shop.');
select pg_temp.try('Arabic template saved as written', $q$select value from public.settings where key = 'whatsapp_share_ar'$q$, 'شوف {name}');
select pg_temp.try('status message template is editable',
  $q$select public.admin_save_settings('{"whatsapp_status_en":"Order {no}: {status}. Track: {url}"}')::text$q$, '1');
select pg_temp.try('status message template saved exactly', $q$select value from public.settings where key = 'whatsapp_status_en'$q$, 'Order {no}: {status}. Track: {url}');
select pg_temp.try('too-long text refused', $q$select public.admin_save_settings(jsonb_build_object('checkout_note_en', repeat('x', 5001)))::text$q$, 'error:P0001:TOO_LONG');
select pg_temp.try('bad batch saved nothing', $q$select public.admin_save_settings('{"shop_intro_ar":"should roll back","unpaid_cancel_hours":"bad"}')::text$q$, 'error:P0001:BAD_NUMBER');
select pg_temp.try('failed batch left Arabic text unchanged', $q$select value from public.settings where key = 'shop_intro_ar'$q$, '');
reset role;

select test, expected, got, expected = got as pass from _r order by n;
rollback;
