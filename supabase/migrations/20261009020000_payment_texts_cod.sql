-- =====================================================================
-- Mika Shop: migration 23, the last fixed payment sentences become editable (Phase 1c, A5).
--  * cod_checkout_*  : under "Cash on delivery" at checkout
--  * cod_confirm_*   : on the confirmation page ({total})
--  * pay_deadline_*  : the "please pay within N hours" sentence for Whish / OMT ({hours})
-- Public (the shop shows them), empty = the standard sentence from the language files.
-- Additive only.
-- =====================================================================

insert into public.settings (key, value, is_public) values
  ('cod_checkout_en', '', true),
  ('cod_checkout_ar', '', true),
  ('cod_confirm_en', '', true),
  ('cod_confirm_ar', '', true),
  ('pay_deadline_en', '', true),
  ('pay_deadline_ar', '', true)
on conflict (key) do nothing;
