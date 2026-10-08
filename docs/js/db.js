// Supabase client + small shared helpers.
// Load order on every page: config.js -> supabase-js (CDN) -> i18n.js -> db.js -> page scripts.
(function () {
  const cfg = window.APP_CONFIG;
  const isStaffPage = /\/staff\//.test(location.pathname);

  // The shop never logs in, so its client keeps no session: it always talks to the
  // database as a logged-out visitor, even if a staff member is logged in in the same browser.
  const client = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
    auth: isStaffPage
      ? { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
      : { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  let settingsPromise = null;

  window.DB = {
    client,
    env: cfg.env,

    // Public URL of a file in the product-photos bucket.
    photoUrl(path) {
      if (!path) return '';
      const clean = String(path).split('/').map(encodeURIComponent).join('/');
      return `${cfg.supabaseUrl}/storage/v1/object/public/product-photos/${clean}`;
    },

    // Thumbnail (400px) of a stored photo: "<SKU>/<id>.jpg" -> "<SKU>/<id>_t.jpg".
    thumbUrl(path) {
      return path ? this.photoUrl(String(path).replace(/\.jpg$/i, '_t.jpg')) : '';
    },

    // Same rules as the SQL function normalize_phone(): +961 followed by 7 or 8 digits, or null.
    // Accepts 0 / 961 / +961 / 00961 prefixes, spaces, dashes, dots, brackets, Arabic digits.
    // Used by the checkout and by the staff "New order" screen.
    normalizePhone(raw) {
      let s = String(raw || '')
        .replace(/[٠-٩]/g, (d) => String('٠١٢٣٤٥٦٧٨٩'.indexOf(d)))
        .replace(/[۰-۹]/g, (d) => String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)))
        .replace(/[\s\-().\/]/g, '');
      if (s.startsWith('+')) {
        if (!s.startsWith('+961')) return null;
        s = s.slice(4);
      } else if (s.startsWith('00961')) {
        s = s.slice(5);
      } else if (s.startsWith('961') && s.length >= 10) {
        s = s.slice(3);
      }
      if (s.startsWith('0')) s = s.slice(1);
      return /^\d{7,8}$/.test(s) ? '+961' + s : null;
    },

    // What to collect on delivery (CLAUDE.md section 7), shared by the slip and the packing tab:
    //   { kind: 'total', amount }  not paid: collect the total
    //   { kind: 'fee', amount }    paid by Whish / OMT, but its delivery fee was set afterwards
    //                              (C1, 12b #2: the transfer paid the items); amount null = not set yet
    //   { kind: 'paid' }           paid: collect nothing
    // feePending: a "fee to be confirmed" order whose fee Mika hasn't set yet.
    amountToCollect(o) {
      const feePending = !!o.fee_tbc && !o.fee_set_at;
      if (o.payment_status === 'PAID') {
        if (o.fee_tbc && (feePending || Number(o.delivery_fee) > 0)) {
          return { kind: 'fee', amount: feePending ? null : Number(o.delivery_fee), feePending };
        }
        return { kind: 'paid', amount: 0, feePending };
      }
      return { kind: 'total', amount: Number(o.total), feePending };
    },

    // Settings the current user may read, as { key: value }. Cached per page load.
    settings() {
      settingsPromise ||= client.from('settings').select('key,value').then(({ data, error }) => {
        if (error) { settingsPromise = null; throw error; }
        return Object.fromEntries(data.map((r) => [r.key, r.value]));
      });
      return settingsPromise;
    },
  };

  // Show a "TEST" ribbon on every page while pointing at the TEST project.
  if (cfg.env !== 'LIVE') {
    document.addEventListener('DOMContentLoaded', () => {
      const b = document.createElement('div');
      b.className = 'env-badge';
      b.textContent = cfg.env;
      b.title = 'Connected to the ' + cfg.env + ' database';
      document.body.appendChild(b);
    });
  }
})();
