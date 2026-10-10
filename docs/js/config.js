// Supabase connection for the website.
// The publishable keys are PUBLIC by design: they are safe only because Row Level Security
// is ON for every table. NEVER put a secret / service_role key or a password here.
//
// Two projects. Which one a browser uses:
//   * everyone: DEFAULT_ENV below (TEST until launch; set to 'LIVE' at launch, step 14)
//   * this computer (localhost preview): always TEST, unless switched
//   * any page opened with ?env=live or ?env=test switches THIS browser only (remembered;
//     ?env=default forgets it). Used to set up LIVE before the shop opens, and after launch
//     to try a change on TEST. A ribbon at the top shows whenever it isn't the real shop.
(function () {
  const PROJECTS = {
    TEST: { url: 'https://kdwsxpfeuaevmtcfhbwk.supabase.co', key: 'sb_publishable_97v2jPeNQqpXp9_xYbdEiw_KmlsRwpi' },
    // LIVE key: filled in at launch (step 14). While it's empty, LIVE can't be chosen.
    LIVE: { url: 'https://mbmhzfeviuljlzfotkhn.supabase.co', key: '' },
  };
  const DEFAULT_ENV = 'TEST';

  const ok = (e) => !!(PROJECTS[e] && PROJECTS[e].key);
  const local = /^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);
  let chosen = null;
  try {
    const asked = (new URLSearchParams(location.search).get('env') || '').toUpperCase();
    if (asked === 'DEFAULT') localStorage.removeItem('env');
    else if (ok(asked)) localStorage.setItem('env', asked);
    chosen = localStorage.getItem('env');
  } catch { /* private mode: no switching, the default is used */ }

  const env = ok(chosen) ? chosen : (local || !ok(DEFAULT_ENV) ? 'TEST' : DEFAULT_ENV);
  window.APP_CONFIG = {
    env,
    defaultEnv: DEFAULT_ENV,
    supabaseUrl: PROJECTS[env].url,
    supabaseKey: PROJECTS[env].key,
  };
})();
