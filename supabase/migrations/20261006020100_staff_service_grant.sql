-- =====================================================================
-- Mika Shop: migration 16. The Edge Function staff-admin works with the service_role key.
-- service_role bypasses RLS but still needs table GRANTs, and the projects have
-- "Automatically expose new tables" OFF, so it had none: grant exactly what the function
-- does on staff (read, add, change). No delete: people are deactivated, never removed.
-- (Found by the first real end-to-end test of the Staff screen, 6 Oct 2026.)
-- =====================================================================
grant select, insert, update on public.staff to service_role;
