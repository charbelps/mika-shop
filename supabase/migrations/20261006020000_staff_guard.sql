-- =====================================================================
-- Mika Shop: migration 15, staff safety (Phase 1c, A3 + advice #8).
-- Staff logins are managed from the admin Staff screen (Edge Function staff-admin).
-- This trigger protects the staff table whoever changes it (screen, function, SQL):
--  * LAST_ADMIN: the last active ADMIN can't be deactivated, demoted or removed.
--  * CANNOT_CHANGE_SELF: a logged-in admin can't deactivate, demote or remove themselves
--    (someone else has to do it), so nobody locks themselves out by mistake.
-- =====================================================================

create or replace function public.staff_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_losing_admin boolean;
begin
  -- does this change take away an active ADMIN?
  v_losing_admin := old.role = 'ADMIN' and old.active
    and (tg_op = 'DELETE' or new.role <> 'ADMIN' or not new.active);
  if not v_losing_admin then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if auth.uid() is not null and old.user_id = auth.uid() then
    raise exception 'CANNOT_CHANGE_SELF' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.staff s
                 where s.role = 'ADMIN' and s.active and s.user_id <> old.user_id) then
    raise exception 'LAST_ADMIN' using errcode = 'P0001';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
revoke all on function public.staff_guard() from public, anon, authenticated;

drop trigger if exists staff_guard on public.staff;
create trigger staff_guard before update or delete on public.staff
  for each row execute function public.staff_guard();
