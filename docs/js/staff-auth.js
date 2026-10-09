// Staff login, role check and routing. Used by every page in docs/staff/.
//   Login page:  StaffAuth.initLoginPage()
//   Other pages: const me = await StaffAuth.require(['ADMIN']);   -> { user, role, name }
(function () {
  // Where each role lands after logging in.
  // OWNER lands on the dashboard since it exists (12b #5)
  const HOME = { ADMIN: 'admin.html', OWNER: 'dashboard.html', DRIVER: 'driver.html' };
  const never = () => new Promise(() => {}); // stop the page while redirecting

  async function getRole() {
    const { data, error } = await DB.client.rpc('my_role');
    if (error) throw error;
    return data; // 'ADMIN' | 'OWNER' | 'DRIVER' | null
  }

  async function getName(userId) {
    const { data } = await DB.client.from('staff').select('name').eq('user_id', userId).maybeSingle();
    return data ? data.name : '';
  }

  // Guard for a staff page: redirects away unless logged in with one of the allowed roles.
  async function require(allowed) {
    const { data: { session } } = await DB.client.auth.getSession();
    if (!session) {
      const here = location.pathname.split('/').pop() || 'admin.html';
      location.replace('login.html?next=' + encodeURIComponent(here));
      return never();
    }
    const role = await getRole();
    if (!role) {
      await DB.client.auth.signOut();
      location.replace('login.html?e=nostaff');
      return never();
    }
    if (!allowed.includes(role)) {
      location.replace(HOME[role]);
      return never();
    }
    const me = { user: session.user, role, name: await getName(session.user.id) };
    await I18n.ready;
    fillShell(me);
    document.body.classList.remove('auth-pending');
    return me;
  }

  // Common header / nav bits present on staff pages.
  function fillShell(me) {
    document.querySelectorAll('[data-staff-name]').forEach((el) => {
      el.textContent = I18n.t('staff.hello', { name: me.name || me.user.email });
    });
    document.querySelectorAll('[data-staff-role]').forEach((el) => {
      el.textContent = I18n.t('staff.role_' + me.role);
    });
    // Hide nav links this role can't use: <a data-roles="ADMIN OWNER">
    document.querySelectorAll('[data-roles]').forEach((el) => {
      if (!el.dataset.roles.split(/\s+/).includes(me.role)) el.remove();
    });
    document.querySelectorAll('[data-sign-out]').forEach((b) => b.addEventListener('click', signOut));
    DB.settings().then((s) => {
      const name = I18n.lang === 'ar' ? (s.shop_name_ar || s.shop_name_en) : (s.shop_name_en || s.shop_name_ar);
      document.querySelectorAll('[data-shop-name]').forEach((el) => { if (name) el.textContent = name; });
    }).catch(() => {});
  }

  async function signOut() {
    await DB.client.auth.signOut();
    location.replace('login.html');
  }

  // Only allow redirects to a staff page in this folder (no open redirects).
  function safeNext(next) {
    return /^[a-z-]+\.html$/.test(next || '') ? next : null;
  }

  async function initLoginPage() {
    await I18n.ready;
    const form = document.getElementById('login-form');
    const err = document.getElementById('login-error');
    const btn = form.querySelector('button[type=submit]');
    const pw = document.getElementById('password');
    const params = new URLSearchParams(location.search);

    const showError = (key) => { err.textContent = I18n.t(key); err.hidden = false; };
    if (params.get('e') === 'nostaff') showError('staff.err_nostaff');

    DB.settings().then((s) => {
      const name = I18n.lang === 'ar' ? (s.shop_name_ar || s.shop_name_en) : (s.shop_name_en || s.shop_name_ar);
      if (name) document.getElementById('shop-name').textContent = name;
    }).catch(() => {});

    document.getElementById('toggle-password').addEventListener('click', (e) => {
      const show = pw.type === 'password';
      pw.type = show ? 'text' : 'password';
      e.currentTarget.textContent = I18n.t(show ? 'staff.hide_password' : 'staff.show_password');
    });

    // Already logged in? Go straight to the right screen.
    const { data: { session } } = await DB.client.auth.getSession();
    if (session) {
      const role = await getRole().catch(() => null);
      if (role) { location.replace(safeNext(params.get('next')) || HOME[role]); return; }
      await DB.client.auth.signOut();
    }
    document.body.classList.remove('auth-pending');

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      err.hidden = true;
      btn.disabled = true;
      btn.textContent = I18n.t('staff.signing_in');
      try {
        const { error } = await DB.client.auth.signInWithPassword({
          email: form.email.value.trim(),
          password: pw.value,
        });
        if (error) {
          showError(error.status === 400 ? 'staff.err_invalid' : 'common.error_generic');
          return;
        }
        const role = await getRole();
        if (!role) {
          await DB.client.auth.signOut();
          showError('staff.err_nostaff');
          return;
        }
        location.replace(safeNext(params.get('next')) || HOME[role]);
      } catch (ex) {
        console.error(ex);
        showError('common.error_generic');
      } finally {
        btn.disabled = false;
        btn.textContent = I18n.t('staff.sign_in');
      }
    });
  }

  window.StaffAuth = { HOME, require, signOut, initLoginPage, getRole };
})();
