-- =====================================================================
-- Mika Shop: editable customer-facing business messages (Phase 1c, A5).
-- Text is public because the shop displays it to visitors. ADMIN edits through
-- admin_save_settings; OWNER and visitors can only read public settings.
-- =====================================================================

insert into public.settings (key, value, is_public) values
  ('shop_intro_en', '', true),
  ('shop_intro_ar', '', true),
  ('delivery_payment_en', '', true),
  ('delivery_payment_ar', '', true),
  ('checkout_note_en', '', true),
  ('checkout_note_ar', '', true),
  ('order_confirmation_en', '', true),
  ('order_confirmation_ar', '', true),
  ('whatsapp_ask_en', '', true),
  ('whatsapp_ask_ar', '', true),
  ('whatsapp_share_en', '', true),
  ('whatsapp_share_ar', '', true),
  ('whatsapp_order_en', '', true),
  ('whatsapp_order_ar', '', true),
  ('footer_note_en', '', true),
  ('footer_note_ar', '', true)
on conflict (key) do nothing;
