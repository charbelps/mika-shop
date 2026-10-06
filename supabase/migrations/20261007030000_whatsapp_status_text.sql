-- =====================================================================
-- Mika Shop: editable WhatsApp order-status template (Phase 1c, W1).
-- =====================================================================

insert into public.settings (key, value, is_public) values
  ('whatsapp_status_en', '', true),
  ('whatsapp_status_ar', '', true)
on conflict (key) do nothing;
