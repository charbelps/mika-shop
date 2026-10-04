// Supabase connection for the website.
// The publishable key is PUBLIC by design: it is safe only because Row Level Security
// is ON for every table. NEVER put the secret / service_role key or a password here.
//
// Currently pointing at: TEST (mika-shop-test). Switched to LIVE at launch (Phase 1, step 14).
window.APP_CONFIG = {
  env: 'TEST',
  supabaseUrl: 'https://kdwsxpfeuaevmtcfhbwk.supabase.co',
  supabaseKey: 'sb_publishable_97v2jPeNQqpXp9_xYbdEiw_KmlsRwpi',
};
