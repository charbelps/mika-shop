// Prep screen: orders newest first, live updates (Supabase Realtime), payment confirmation,
// confirm / pack / cancel, staff notes, bilingual packing slip. ADMIN acts; OWNER views only.
// All changes go through database functions that check the role again.
(async function () {
  const me = await StaffAuth.require(['ADMIN', 'OWNER']);
  const canEdit = me.role === 'ADMIN';
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);
  let settingsError = null;
  const S = await DB.settings().catch((error) => { settingsError = error; return {}; });
  const money = (n) => `<bdi>${esc(I18n.money(n, S.currency))}</bdi>`;
  const PAGE = 30;
  const state = { tab: 'todo', q: '', page: 0, req: 0, current: null };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  }
  let toastTimer;
  function toast(msg, isError, duration) {
    let el = $('.toast');
    if (!el) { el = document.createElement('div'); el.className = 'toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg;
    el.classList.toggle('error', !!isError);
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, duration || (isError ? 6000 : 3500));
  }
  function errText(error) {
    const code = (/[A-Z_]{6,}/.exec((error && error.message) || '') || [''])[0];
    if (error && error.code === '42501') return t('admin.err_permission');
    const k = 'prep.err_' + code;
    return t(k) !== k ? t(k) : t('common.error_generic') + ' (' + ((error && error.message) || '') + ')';
  }
  const when = (iso) => new Date(iso).toLocaleString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB',
    { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });

  // ---------- new-order alerts ----------
  let audioContext = null;
  let soundEnabled = false;
  let pushRegistration = null;
  let pushSubscription = null;
  let pushSaved = false;
  const pushButton = $('#push-enable');
  const pushTestButton = $('#push-test');
  const pushStatus = $('#push-status');
  const soundButton = $('#sound-enable');
  if (!window.AudioContext && !window.webkitAudioContext) {
    soundButton.disabled = true;
    soundButton.textContent = t('prep.sound_unsupported');
  }

  function pushMessage(key) {
    pushStatus.textContent = t(key);
    pushStatus.classList.toggle('bad', key.includes('error') || key.includes('denied'));
    pushStatus.classList.toggle('ok', key.includes('enabled'));
  }

  function decodeVapidKey(key) {
    const padding = '='.repeat((4 - key.length % 4) % 4);
    const base64 = (key + padding).replace(/-/g, '+').replace(/_/g, '/');
    return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  }

  async function savePushSubscription(subscription) {
    const keys = subscription.toJSON().keys;
    if (!keys || !keys.p256dh || !keys.auth) throw new Error(t('prep.push_error_keys'));
    const { error } = await DB.client.rpc('save_push_subscription', {
      p_endpoint: subscription.endpoint,
      p_p256dh: keys.p256dh,
      p_auth: keys.auth,
      p_user_agent: navigator.userAgent,
      p_lang: I18n.lang,
    });
    if (error) throw error;
    pushSubscription = subscription;
    pushSaved = true;
    pushButton.textContent = t('prep.push_disable');
    pushTestButton.disabled = false;
    pushMessage('prep.push_enabled');
  }

  async function initPush() {
    if (!('Notification' in window) || !('serviceWorker' in navigator) || !('PushManager' in window)) {
      pushButton.disabled = true;
      // iPhone / iPad: notifications only work from the Home Screen app (iOS 16.4 or newer)
      const ios = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
      const standalone = window.navigator.standalone === true || window.matchMedia('(display-mode: standalone)').matches;
      pushMessage(ios && !standalone ? 'prep.push_ios_home' : 'prep.push_unsupported');
      return;
    }
    if (settingsError) {
      pushButton.disabled = true;
      pushMessage('prep.push_error');
      toast(errText(settingsError), true);
      return;
    }
    if (!S.push_public_key) {
      pushButton.disabled = true;
      pushMessage('prep.push_not_configured');
      return;
    }
    pushButton.disabled = true;
    const scope = new URL('../', document.baseURI).pathname;
    pushRegistration = await navigator.serviceWorker.register(new URL('../sw.js', document.baseURI), { scope });
    pushSubscription = await pushRegistration.pushManager.getSubscription();
    if (!pushSubscription) {
      if (Notification.permission === 'denied') {
        pushMessage('prep.push_denied');
        return;
      }
      pushButton.disabled = false;
      pushMessage('prep.push_off');
      return;
    }
    const { data, error } = await DB.client.from('push_subscriptions').select('id')
      .eq('endpoint', pushSubscription.endpoint).maybeSingle();
    if (error) {
      pushMessage('prep.push_error');
      toast(errText(error), true);
      return;
    }
    if (data) {
      pushSaved = true;
      pushButton.textContent = t('prep.push_disable');
      pushTestButton.disabled = false;
      pushMessage(Notification.permission === 'denied' ? 'prep.push_denied' : 'prep.push_enabled');
    } else {
      if (Notification.permission === 'denied') {
        pushMessage('prep.push_denied');
        return;
      }
      pushButton.disabled = false;
      pushMessage('prep.push_finish_setup');
    }
  }

  pushButton.addEventListener('click', async () => {
    pushButton.disabled = true;
    try {
      if (pushSaved && pushSubscription) {
        const endpoint = pushSubscription.endpoint;
        await pushSubscription.unsubscribe();
        const { error } = await DB.client.rpc('remove_push_subscription', { p_endpoint: endpoint });
        if (error) throw error;
        pushSubscription = null;
        pushSaved = false;
        pushTestButton.disabled = true;
        pushButton.textContent = t('prep.push_enable');
        pushMessage('prep.push_off');
        return;
      }
      if (Notification.permission === 'default') {
        const permission = await Notification.requestPermission();
        if (permission !== 'granted') {
          pushMessage(permission === 'denied' ? 'prep.push_denied' : 'prep.push_not_enabled');
          return;
        }
      } else if (Notification.permission !== 'granted') {
        pushMessage('prep.push_denied');
        return;
      }
      if (!pushRegistration) {
        const scope = new URL('../', document.baseURI).pathname;
        pushRegistration = await navigator.serviceWorker.register(new URL('../sw.js', document.baseURI), { scope });
      }
      pushSubscription = await pushRegistration.pushManager.getSubscription()
        || await pushRegistration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: decodeVapidKey(S.push_public_key),
        });
      await savePushSubscription(pushSubscription);
      toast(t('prep.push_enabled'));
    } catch (error) {
      pushMessage('prep.push_error');
      toast(errText(error), true);
    } finally {
      pushButton.disabled = false;
    }
  });

  pushTestButton.addEventListener('click', async () => {
    pushTestButton.disabled = true;
    try {
      const { data, error } = await DB.client.functions.invoke('new-order-alert', { body: { action: 'test' } });
      if (error) throw error;
      if (data && data.error === 'NOTIFICATIONS_NOT_CONFIGURED') throw new Error(t('prep.push_not_configured'));
      if (!data || !data.sent) throw new Error(t('prep.push_test_none'));
      toast(t('prep.push_test_sent'));
    } catch (error) {
      toast(errText(error), true);
    } finally {
      pushTestButton.disabled = !pushSaved;
    }
  });

  // The sound choice is remembered on this device. Browsers only allow sound after a tap, so on
  // the next visit the first tap anywhere on the screen switches it back on.
  const SOUND_KEY = 'staff:orders:sound';
  const rememberSound = (on) => { try { localStorage.setItem(SOUND_KEY, on ? '1' : '0'); } catch { /* storage blocked */ } };
  async function startSound(beep) {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) throw new Error(t('prep.sound_unsupported'));
    audioContext ||= new AudioContextClass();
    await audioContext.resume();
    soundEnabled = true;
    soundButton.textContent = t('prep.sound_disable');
    if (beep) playAlertSound();
  }
  soundButton.addEventListener('click', async () => {
    if (soundEnabled) {
      soundEnabled = false;
      rememberSound(false);
      soundButton.textContent = t('prep.sound_enable');
      return;
    }
    try {
      await startSound(true);
      rememberSound(true);
    } catch (error) {
      toast(errText(error), true);
    }
  });
  let soundWanted = false;
  try { soundWanted = localStorage.getItem(SOUND_KEY) === '1'; } catch { /* storage blocked */ }
  if (soundWanted && !soundButton.disabled) {
    soundButton.textContent = t('prep.sound_tap_to_resume');
    const resume = (event) => {
      if (event.target.closest && event.target.closest('#sound-enable')) return; // the button handles itself
      document.removeEventListener('pointerdown', resume, true);
      document.removeEventListener('keydown', resume, true);
      if (!soundEnabled) startSound(false).catch(() => { soundButton.textContent = t('prep.sound_enable'); });
    };
    document.addEventListener('pointerdown', resume, true);
    document.addEventListener('keydown', resume, true);
  }

  function playAlertSound() {
    if (!soundEnabled || !audioContext) return;
    const now = audioContext.currentTime;
    [880, 660].forEach((frequency, index) => {
      const oscillator = audioContext.createOscillator();
      const gain = audioContext.createGain();
      const start = now + index * .2;
      oscillator.frequency.value = frequency;
      gain.gain.setValueAtTime(.0001, start);
      gain.gain.exponentialRampToValueAtTime(.16, start + .02);
      gain.gain.exponentialRampToValueAtTime(.0001, start + .16);
      oscillator.connect(gain);
      gain.connect(audioContext.destination);
      oscillator.start(start);
      oscillator.stop(start + .17);
    });
  }

  initPush().catch((error) => {
    pushButton.disabled = true;
    pushMessage('prep.push_error');
    toast(errText(error), true);
  });
  function payPill(o) {
    const cls = o.payment_status === 'PAID' ? 'pill-ok' : o.payment_status === 'AWAITING' ? 'pill-warn' : '';
    return `<span class="pill ${cls}">${esc(t('prep.method_' + o.payment_method))} · ${esc(t('status.pay_' + o.payment_status))}</span>`;
  }
  // Orders Mika entered herself (F7); website orders get no pill.
  const srcPill = (o) => (o.source && o.source !== 'WEBSITE' ? ` <span class="pill">${esc(t('prep.src_' + o.source))}</span>` : '');
  // First order from this phone number (advice #2): Mika can check it before packing.
  // C1: "fee to be confirmed" order whose delivery fee Mika hasn't set yet
  const feePill = (o) => (o.fee_tbc && !o.fee_set_at ? ` <span class="pill pill-warn" title="${esc(t('prep.fee_tbc_hint'))}">${esc(t('prep.fee_tbc'))}</span>` : '');
  const newPill = (o) => (o.is_first_order ? ` <span class="pill pill-warn" title="${esc(t('prep.new_customer_hint'))}">${esc(t('prep.new_customer'))}</span>` : '');
  function statusPill(s) {
    const cls = s === 'CANCELLED' || s === 'RETURNED' ? 'pill-off' : s === 'NEW' ? 'pill-danger' : s === 'PACKED' ? 'pill-ok' : '';
    return `<span class="pill ${cls}">${esc(t('status.' + s))}</span>`;
  }
  function fillTemplate(template, values) {
    return template.replace(/\{(\w+)\}/g, (match, key) =>
      Object.prototype.hasOwnProperty.call(values, key) ? String(values[key]) : match);
  }
  // The status message goes out in the language the customer ordered in (orders.lang, since 8 Oct).
  // Older orders have no language: the screen's language is used, and the screen says so.
  async function statusWhatsApp(o) {
    const known = o.lang === 'en' || o.lang === 'ar';
    let lang = known ? o.lang : I18n.lang;
    let tc = t;
    try { tc = await I18n.translator(lang); } catch { lang = I18n.lang; } // offline: screen's language
    const track = new URL('../track.html', location.href);
    track.searchParams.set('no', o.order_no);
    const values = { name: o.name, no: o.order_no, status: tc('status.' + o.status), url: track.href };
    const custom = String(S['whatsapp_status_' + lang] || '').trim();
    const message = custom ? fillTemplate(custom, values) : tc('ord.wa_status', values);
    return {
      href: 'https://wa.me/' + o.phone.replace(/\D/g, '') + '?text=' + encodeURIComponent(message),
      note: t(known && lang === o.lang ? 'prep.whatsapp_status_in' : 'prep.whatsapp_status_unknown', { lang: t('prep.lang_' + lang) }),
    };
  }

  // ---------- list ----------
  async function load() {
    const reqId = ++state.req;
    let q = DB.client.from('orders')
      .select('id,order_no,created_at,name,phone,district,total,payment_method,payment_status,status,source,is_first_order,fee_tbc,fee_set_at', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range(state.page * PAGE, state.page * PAGE + PAGE - 1);
    if (state.tab === 'todo') q = q.in('status', ['NEW', 'CONFIRMED']);
    if (state.tab === 'awaiting') q = q.eq('payment_status', 'AWAITING').not('status', 'in', '(CANCELLED,RETURNED)');
    if (state.tab === 'packed') q = q.eq('status', 'PACKED');
    const s = state.q.replace(/[",()\\*%]/g, ' ').trim();
    if (s) {
      const digits = s.replace(/\D/g, '');
      const ors = [`order_no.ilike."*${s}*"`, `name.ilike."*${s}*"`];
      if (digits.length >= 3) ors.push(`phone.ilike."*${digits.replace(/^0/, '')}*"`);
      q = q.or(ors.join(','));
    }
    const { data, error, count } = await q;
    if (reqId !== state.req) return;
    const box = $('#o-list');
    if (error) { box.innerHTML = `<div class="alert alert-error">${esc(errText(error))}</div>`; return; }
    $('#o-count').textContent = t('prep.count', { n: count || 0 });
    const pages = Math.max(1, Math.ceil((count || 0) / PAGE));
    $('#o-pager').hidden = pages <= 1;
    $('#o-page').textContent = t('admin.page', { n: state.page + 1, total: pages });
    $('#o-prev').disabled = state.page === 0;
    $('#o-next').disabled = state.page >= pages - 1;
    if (!data.length) { box.innerHTML = `<p class="empty">${esc(t('prep.none'))}</p>`; return; }
    box.innerHTML = '';
    data.forEach((o) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'row-item order-row';
      b.dataset.id = o.id;
      b.innerHTML = `<div class="body">
          <div class="title"><span dir="ltr">${esc(o.order_no)}</span> · ${esc(o.name)}</div>
          <div class="meta">${esc(when(o.created_at))} · ${esc(o.district)}</div>
          <div>${statusPill(o.status)} ${payPill(o)}${srcPill(o)}${newPill(o)}${feePill(o)}</div>
        </div>
        <div class="end"><strong>${money(o.total)}</strong></div>`;
      b.addEventListener('click', () => open(o.id));
      box.appendChild(b);
    });
  }

  document.querySelectorAll('[data-otab]').forEach((c) => c.addEventListener('click', () => {
    state.tab = c.dataset.otab; state.page = 0;
    document.querySelectorAll('[data-otab]').forEach((x) => x.setAttribute('aria-pressed', String(x === c)));
    load();
  }));
  let st;
  $('#o-search').addEventListener('input', (e) => { clearTimeout(st); st = setTimeout(() => { state.q = e.target.value; state.page = 0; load(); }, 300); });
  $('#o-prev').addEventListener('click', () => { state.page--; load(); });
  $('#o-next').addEventListener('click', () => { state.page++; load(); });

  // ---------- detail ----------
  const dlg = $('#order-dialog');
  dlg.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => dlg.close()));

  async function open(id) {
    const { data: o, error } = await DB.client.from('orders')
      .select('*, order_items(sku,name_en,name_ar,label,label_ar,qty,unit_price,line_total)').eq('id', id).single();
    if (error) { toast(errText(error), true); return; }
    if (canEdit && o.status !== 'NEW') o._wa = await statusWhatsApp(o);
    state.current = o;
    render(o);
    if (!dlg.open) dlg.showModal();
  }

  function render(o) {
    $('#od-title').innerHTML = esc(t('prep.order', { no: '' })) + `<span dir="ltr">${esc(o.order_no)}</span>`;
    const digits = o.phone.replace(/\D/g, '');
    const items = o.order_items || [];
    const awaiting = o.payment_status === 'AWAITING' && !['CANCELLED', 'RETURNED'].includes(o.status);
    const done = ['CANCELLED', 'RETURNED'].includes(o.status);
    $('#od-body').innerHTML = `
      <div class="od-pills">${statusPill(o.status)} ${payPill(o)}${srcPill(o)}${newPill(o)}${feePill(o)} ${canEdit ? '' : `<span class="pill">${esc(t('prep.readonly'))}</span>`}</div>
      <p class="meta">${esc(when(o.created_at))}</p>
      ${o.is_first_order ? `<p class="hint">${esc(t('prep.new_customer_hint'))}</p>` : ''}
      ${o.cancel_reason ? `<div class="alert alert-warn">${esc(t('prep.cancelled_because', { reason: o.cancel_reason }))}</div>` : ''}

      <fieldset><legend>${esc(t('prep.customer'))}</legend>
        <p class="od-name">${esc(o.name)}</p>
        <p dir="ltr" class="od-phone">${esc(o.phone)}</p>
        <div class="od-links">
          <a class="btn btn-small" href="tel:${esc(o.phone)}">📞 ${esc(t('prep.call'))}</a>
          <a class="btn btn-small" href="https://wa.me/${esc(digits)}" target="_blank" rel="noopener">💬 ${esc(t('prep.whatsapp'))}</a>
          ${o.location_url ? `<a class="btn btn-small" href="${esc(o.location_url)}" target="_blank" rel="noopener noreferrer">📍 ${esc(t('prep.map'))}</a>` : ''}
          ${o._wa ? `<a class="btn btn-small" href="${esc(o._wa.href)}" target="_blank" rel="noopener">${esc(t('prep.whatsapp_status'))}</a>` : ''}
        </div>
        ${o._wa ? `<p class="hint" id="od-wa-lang">${esc(o._wa.note)}</p>` : ''}
        <p>${esc(o.town)}, ${esc(o.district)} (${esc(o.governorate)})<br>${esc(o.address)}${o.landmark ? `<br><span class="meta">${esc(o.landmark)}</span>` : ''}</p>
      </fieldset>

      <fieldset><legend>${esc(t('prep.items'))}</legend>
        ${items.map((i) => `<div class="od-item">
            <div><strong>${i.qty} ×</strong> ${esc(i.name_en)}${i.label ? ` <span class="meta">(${esc(i.label)})</span>` : ''}
              ${i.name_ar ? `<div class="meta" dir="rtl" lang="ar">${esc(i.name_ar)}${i.label_ar ? ` (${esc(i.label_ar)})` : ''}</div>` : ''}
              <div class="meta" dir="ltr">${esc(i.sku)}</div></div>
            <div>${money(i.line_total)}</div></div>`).join('')}
        <div class="od-sum"><span>${esc(t('cart.subtotal'))}</span><span>${money(o.subtotal)}</span></div>
        <div class="od-sum"><span>${esc(t('co.delivery'))}${o.fee_tbc && o.fee_set_at ? ` <span class="meta">(${esc(t('prep.fee_set_later'))})</span>` : ''}</span><span>${o.fee_tbc && !o.fee_set_at ? esc(t('co.fee_tbc')) : money(o.delivery_fee)}</span></div>
        <div class="od-sum total"><span>${esc(t('co.total'))}</span><strong>${money(o.total)}</strong></div>
        ${canEdit && o.fee_tbc && !['DELIVERED', 'CANCELLED', 'RETURNED'].includes(o.status) ? `<div class="field" style="margin-top:.6rem">
          <label for="od-fee">${esc(t(o.fee_set_at ? 'prep.fee_change' : 'prep.fee_set'))}</label>
          <div class="input-with-btn"><input id="od-fee" type="text" inputmode="decimal" dir="ltr" maxlength="8" value="${o.fee_set_at ? esc(o.delivery_fee) : ''}" placeholder="0.00">
          <button type="button" class="btn btn-primary" id="od-fee-save">${esc(t('prep.fee_save'))}</button></div>
          <p class="hint">${esc(t(o.payment_method === 'COD' ? 'prep.fee_help_cod' : 'prep.fee_help_paid'))}</p></div>` : ''}
      </fieldset>

      <fieldset><legend>${esc(t('prep.payment'))}</legend>
        <p>${esc(t('prep.method_' + o.payment_method))} · ${esc(t('status.pay_' + o.payment_status))}</p>
        ${o.payment_status === 'PAID' && o.payment_ref ? `<p class="ok">✓ ${esc(t('prep.paid_ref', { ref: o.payment_ref }))}</p>` : ''}
        ${awaiting && canEdit ? `<div class="field"><label for="od-ref">${esc(t('prep.ref'))}</label>
          <div class="input-with-btn"><input id="od-ref" type="text" dir="ltr" maxlength="100" placeholder="${esc(t('prep.ref_ph'))}">
          <button type="button" class="btn btn-primary" id="od-pay">${esc(t('prep.confirm_payment'))}</button></div></div>` : ''}
      </fieldset>

      ${canEdit && !done ? `<fieldset><legend>${esc(t('prep.actions'))}</legend><div class="od-actions">
        ${o.status === 'NEW' ? `<button type="button" class="btn" data-status="CONFIRMED">${esc(t('prep.confirm'))}</button>` : ''}
        ${['NEW', 'CONFIRMED'].includes(o.status) ? `<button type="button" class="btn btn-primary" data-status="PACKED">${esc(t('prep.pack'))}</button>` : ''}
        ${o.status === 'CONFIRMED' ? `<button type="button" class="btn btn-ghost" data-status="NEW">${esc(t('prep.undo_confirm'))}</button>` : ''}
        ${o.status === 'PACKED' ? `<button type="button" class="btn btn-ghost" data-status="CONFIRMED">${esc(t('prep.undo_pack'))}</button>` : ''}
        ${['NEW', 'CONFIRMED', 'PACKED'].includes(o.status) ? `<button type="button" class="btn btn-danger" id="od-cancel">${esc(t('prep.cancel'))}</button>` : ''}
      </div></fieldset>` : ''}

      <button type="button" class="btn btn-block" id="od-print">🖨️ ${esc(t('prep.print'))}</button>

      <div class="field" style="margin-top:1rem"><label for="od-notes">${esc(t('prep.notes'))}</label>
        <textarea id="od-notes" maxlength="1000" ${canEdit ? '' : 'readonly'}>${esc(o.notes || '')}</textarea>
        ${canEdit ? `<button type="button" class="btn btn-small" id="od-save-notes" style="margin-top:.4rem">${esc(t('prep.save_notes'))}</button>` : ''}
      </div>`;

    const body = $('#od-body');
    const pay = $('#od-pay', body);
    if (pay) pay.addEventListener('click', () => {
      const ref = $('#od-ref').value.trim();
      if (!ref) { toast(t('prep.err_REF_REQUIRED'), true); $('#od-ref').focus(); return; }
      act(() => DB.client.rpc('staff_confirm_payment', { p_order_id: o.id, p_ref: ref }));
    });
    body.querySelectorAll('[data-status]').forEach((b) => b.addEventListener('click', () => {
      if (b.dataset.status === 'PACKED' && o.payment_status === 'AWAITING' && !confirm(t('prep.pack_unpaid'))) return;
      act(() => DB.client.rpc('staff_set_status', { p_order_id: o.id, p_status: b.dataset.status }));
    }));
    const feeSave = $('#od-fee-save', body);
    if (feeSave) feeSave.addEventListener('click', () => {
      const raw = $('#od-fee').value.trim().replace(',', '.');
      const fee = Number(raw);
      if (!raw || !/^\d{1,4}(\.\d{1,2})?$/.test(raw) || Number.isNaN(fee)) { toast(t('prep.err_BAD_FEE'), true); $('#od-fee').focus(); return; }
      act(() => DB.client.rpc('staff_set_delivery_fee', { p_order_id: o.id, p_fee: fee }));
    });
    const cancelBtn = $('#od-cancel', body);
    if (cancelBtn) cancelBtn.addEventListener('click', () => openCancel(o));
    $('#od-print', body).addEventListener('click', () => printSlip(o));
    const sn = $('#od-save-notes', body);
    if (sn) sn.addEventListener('click', async () => {
      const { error } = await DB.client.from('orders').update({ notes: $('#od-notes').value }).eq('id', o.id);
      if (error) toast(errText(error), true); else toast(t('prep.saved'));
    });
  }

  async function act(fn) {
    const o = state.current;
    const { error } = await fn();
    if (error) { toast(errText(error), true); return; }
    toast(t('prep.saved'));
    await open(o.id);
    load();
  }

  // cancel confirmation
  const cdlg = $('#cancel-dialog');
  cdlg.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => cdlg.close()));
  function openCancel(o) {
    $('#cx-title').innerHTML = esc(t('prep.cancel_title', { no: '' })).replace(/\?$/, '') + `<span dir="ltr">${esc(o.order_no)}</span>?`;
    $('#cx-reason').value = '';
    $('#cx-error').hidden = true;
    cdlg.showModal();
  }
  $('#cx-go').addEventListener('click', async () => {
    const reason = $('#cx-reason').value.trim();
    if (!reason) { $('#cx-error').textContent = t('prep.err_REASON_REQUIRED'); $('#cx-error').hidden = false; return; }
    const o = state.current;
    const { error } = await DB.client.rpc('cancel_order', { p_order_id: o.id, p_reason: reason });
    if (error) { $('#cx-error').textContent = errText(error); $('#cx-error').hidden = false; return; }
    cdlg.close();
    toast(t('status.CANCELLED'));
    await open(o.id);
    load();
  });

  // ---------- packing slip (bilingual, print.css shows only .slip) ----------
  function printSlip(o) {
    const slip = $('#slip');
    const c = DB.amountToCollect(o);
    const collect = c.kind !== 'paid';
    const amount = I18n.money(o.total, S.currency);
    const collectHtml = c.kind === 'total'
      ? `${esc(t('prep.slip_collect'))}<div class="slip-amount"><bdi>${esc(I18n.money(c.amount, S.currency))}</bdi></div>${c.feePending ? `<div>${esc(t('prep.slip_fee_tbc'))}</div>` : ''}`
      : c.kind === 'fee'
        ? `${esc(t('prep.slip_items_paid'))}<br>${esc(t('prep.slip_collect_fee'))}<div class="slip-amount">${c.amount == null ? esc(t('prep.slip_fee_tbc_amount')) : `<bdi>${esc(I18n.money(c.amount, S.currency))}</bdi>`}</div>`
        : esc(t('prep.slip_paid'));
    const shop = [S.shop_name_en, S.shop_name_ar].filter(Boolean).join(' · ');
    slip.innerHTML = `
      <div class="slip-head"><div class="slip-shop">${esc(shop)}</div>
        <div><span class="slip-label">${esc(t('prep.slip_order'))}</span> <strong class="slip-no" dir="ltr">${esc(o.order_no)}</strong></div>
        <div><span class="slip-label">${esc(t('prep.slip_date'))}</span> ${esc(new Date(o.created_at).toLocaleString('en-GB'))}</div></div>
      <table class="slip-to"><tbody>
        <tr><th>${esc(t('prep.slip_customer'))}</th><td>${esc(o.name)}</td></tr>
        <tr><th>${esc(t('prep.slip_phone'))}</th><td dir="ltr">${esc(o.phone)}</td></tr>
        ${o.source && o.source !== 'WEBSITE' ? `<tr><th>${esc(t('prep.slip_source'))}</th><td>${esc(t('prep.slip_src_' + o.source))}</td></tr>` : ''}
        <tr><th>${esc(t('prep.slip_address'))}</th><td>${esc(o.town)}, ${esc(o.district)} (${esc(o.governorate)})<br>${esc(o.address)}${o.landmark ? '<br>' + esc(o.landmark) : ''}</td></tr>
      </tbody></table>
      <table class="slip-items"><thead><tr><th>${esc(t('prep.slip_item'))}</th><th>${esc(t('prep.slip_qty'))}</th></tr></thead><tbody>
        ${(o.order_items || []).map((i) => `<tr><td>${esc(i.name_en)}${i.label ? ' (' + esc(i.label) + ')' : ''}
          ${i.name_ar ? `<div dir="rtl" lang="ar">${esc(i.name_ar)}${i.label_ar ? ' (' + esc(i.label_ar) + ')' : ''}</div>` : ''}
          <div class="slip-sku" dir="ltr">${esc(i.sku)}</div></td><td class="slip-qty">${i.qty}</td></tr>`).join('')}
      </tbody></table>
      <div class="slip-total"><span>${esc(t('prep.slip_total'))}</span> <bdi>${esc(amount)}</bdi></div>
      <div class="slip-collect ${collect ? '' : 'paid'}">${collectHtml}</div>`;
    window.print();
  }

  // ---------- realtime ----------
  let reloadTimer;
  function onChange(payload) {
    if (payload && payload.eventType === 'INSERT' && payload.new && payload.new.order_no) {
      toast(t('prep.new_order', { no: payload.new.order_no }), false, 12000);
      playAlertSound();
    }
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(load, 400);
    if (state.current && payload && payload.new && payload.new.id === state.current.id && dlg.open) open(state.current.id);
  }
  const live = $('#o-live');
  DB.client.channel('prep-orders')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, onChange)
    .subscribe((status) => {
      const ok = status === 'SUBSCRIBED';
      live.textContent = ok ? '● ' + t('prep.live') : t('prep.offline');
      live.className = 'pill ' + (ok ? 'pill-ok' : 'pill-warn');
    });

  load();
  // prep.html?open=123 (link from the New order screen): open that order straight away.
  const openId = Number(new URLSearchParams(location.search).get('open'));
  if (Number.isInteger(openId) && openId > 0) open(openId);
  // A tapped phone notification (sw.js) when this screen is already open: show that order, but
  // never on top of an order Mika has open (she may be typing a note); then a pop-up is enough.
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', (event) => {
      const m = event.data;
      if (!m || m.type !== 'open-order' || !Number.isInteger(m.id) || m.id <= 0) return;
      load();
      if (dlg.open) toast(t('prep.new_order_tap'), false, 8000);
      else open(m.id);
    });
  }
  window.Prep = { load, open, onChange, printSlip };
})();
