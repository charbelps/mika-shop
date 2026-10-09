// Driver screen (Phase 2): the logged-in driver's deliveries.
//  * To deliver: orders given to him that are ready at the shop (PACKED: "I have it"), on the way
//    (OUT_FOR_DELIVERY: Delivered / Not delivered) or failed (FAILED_ATTEMPT: Try again).
//  * Done today: what he delivered (with the cash collected) or couldn't deliver today.
// Every move goes through driver_delivery (the database checks it is his order and a valid move).
// What to collect = DB.amountToCollect (the same rule as the packing slip and cards).
// Live: his orders change on the screen by themselves (Realtime + reload when the phone wakes up).
(async function () {
  const me = await StaffAuth.require(['DRIVER']);
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);
  const S = await DB.settings().catch(() => ({}));
  const money = (n) => `<bdi>${esc(I18n.money(n, S.currency))}</bdi>`;
  const REASONS = ['no_answer', 'wrong_address', 'refused', 'later'];
  let orders = [];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  }
  let toastTimer;
  function toast(msg, isError) {
    let el = $('.toast');
    if (!el) { el = document.createElement('div'); el.className = 'toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg;
    el.classList.toggle('error', !!isError);
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, isError ? 6000 : 3500);
  }
  function errText(error) {
    const code = (/[A-Z_]{6,}/.exec((error && error.message) || '') || [''])[0];
    if (error && error.code === '42501') return t('admin.err_permission');
    const k = 'drv.err_' + code;
    return t(k) !== k ? t(k) : t('common.error_generic') + ' (' + ((error && error.message) || '') + ')';
  }
  const time = (iso) => new Date(iso).toLocaleTimeString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB', { hour: '2-digit', minute: '2-digit' });
  const startOfToday = () => { const d = new Date(); d.setHours(0, 0, 0, 0); return d; };
  const digits = (p) => String(p || '').replace(/\D/g, '');
  const itemName = (i) => (I18n.lang === 'ar' && i.name_ar ? i.name_ar : i.name_en) + ((I18n.lang === 'ar' && i.label_ar) || i.label ? ' (' + ((I18n.lang === 'ar' && i.label_ar) || i.label) + ')' : '');

  // ---------- data ----------
  let req = 0;
  async function load() {
    const my = ++req;
    const today = startOfToday().toISOString();
    const { data, error } = await DB.client.from('orders')
      .select('id,order_no,status,name,phone,governorate,district,town,address,landmark,location_url,notes,total,delivery_fee,' +
              'payment_method,payment_status,fee_tbc,fee_set_at,is_gift,recipient_name,recipient_phone,gift_note,cash_collected,' +
              'out_at,delivered_at,failed_at,failed_reason,created_at,order_items(qty,name_en,name_ar,label,label_ar)')
      .eq('driver_id', me.user.id)
      .in('status', ['PACKED', 'OUT_FOR_DELIVERY', 'FAILED_ATTEMPT', 'DELIVERED'])
      .or(`status.neq.DELIVERED,delivered_at.gte.${today}`)
      .order('created_at', { ascending: true })
      .limit(200);
    if (my !== req) return;
    if (error) { $('#dr-todo').innerHTML = `<div class="alert alert-error">${esc(errText(error))}</div>`; return; }
    orders = data || [];
    render();
  }

  // what the driver collects for this order (gifts are always prepaid)
  function collect(o) {
    const c = DB.amountToCollect(o);
    if (o.is_gift || c.kind === 'paid') return { paid: true, amount: 0, html: esc(t('drv.paid')) };
    if (c.kind === 'fee') {
      return c.amount == null
        ? { paid: false, amount: null, html: `${esc(t('drv.items_paid'))}<br>${esc(t('drv.fee_unknown'))}` }
        : { paid: false, amount: c.amount, html: `${esc(t('drv.items_paid'))}<br>${esc(t('drv.collect'))} ${money(c.amount)}` };
    }
    return { paid: false, amount: c.amount, html: `${esc(t('drv.collect'))}<br>${money(c.amount)}${c.feePending ? `<br><small>${esc(t('drv.fee_unknown'))}</small>` : ''}` };
  }

  function mapLink(o) {
    if (o.location_url) return o.location_url;
    const q = [o.address, o.landmark, o.town, o.district, 'Lebanon'].filter(Boolean).join(', ');
    return 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(q);
  }

  // ---------- render ----------
  function card(o) {
    const c = collect(o);
    const who = o.is_gift ? t('drv.gift_for', { name: o.recipient_name || '' }) : o.name;
    const tel = o.is_gift ? o.recipient_phone : o.phone;
    const done = o.status === 'DELIVERED';
    const items = o.order_items || [];
    const n = items.reduce((s, i) => s + i.qty, 0);
    const state = o.status === 'PACKED' ? t('drv.state_ready')
      : o.status === 'OUT_FOR_DELIVERY' ? t('drv.state_out', { time: time(o.out_at || o.created_at) })
      : o.status === 'FAILED_ATTEMPT' ? t('drv.state_failed', { time: time(o.failed_at || o.created_at) })
      : t('drv.state_done', { time: time(o.delivered_at || o.created_at) });
    return `<article class="dr-card${o.status === 'FAILED_ATTEMPT' ? ' failed' : ''}${done ? ' done' : ''}" data-id="${o.id}">
      <div class="dr-top">
        <div><h3 dir="ltr">${esc(o.order_no)}</h3><p class="dr-state">${esc(state)}</p></div>
        <div class="dr-money ${c.paid ? 'paid' : 'collect'}">${done ? `${esc(t('drv.got'))}<br>${money(o.cash_collected || 0)}` : c.html}</div>
      </div>
      <p class="dr-who" dir="auto">${esc(who)}</p>
      <p class="dr-addr" dir="auto">${esc(o.town)}, ${esc(o.district)}<br>${esc(o.address)}${o.landmark ? `<br><span class="meta">${esc(o.landmark)}</span>` : ''}</p>
      ${done ? '' : `<div class="dr-links">
        <a class="btn" href="tel:${esc(tel)}">📞 ${esc(t('drv.call'))}</a>
        <a class="btn" href="https://wa.me/${esc(digits(tel))}" target="_blank" rel="noopener">💬 ${esc(t('drv.whatsapp'))}</a>
        <a class="btn" href="${esc(mapLink(o))}" target="_blank" rel="noopener noreferrer">📍 ${esc(t('drv.map'))}</a>
      </div>`}
      ${o.status === 'FAILED_ATTEMPT' && o.failed_reason ? `<p class="dr-fail" dir="auto">${esc(t('drv.failed_msg', { reason: o.failed_reason }))}</p>` : ''}
      ${o.notes ? `<p class="dr-note" dir="auto">📝 ${esc(o.notes)}</p>` : ''}
      <details class="dr-items"><summary>${esc(t('drv.items', { n }))}</summary>
        <ul>${items.map((i) => `<li dir="auto">${i.qty} × ${esc(itemName(i))}</li>`).join('')}</ul></details>
      ${o.status === 'PACKED' ? `<div class="dr-acts"><button type="button" class="btn btn-primary" data-act="START">▶ ${esc(t('drv.start'))}</button></div>` : ''}
      ${o.status === 'OUT_FOR_DELIVERY' ? `<div class="dr-acts">
        <button type="button" class="btn btn-primary" data-act="DELIVERED">✓ ${esc(t('drv.delivered'))}</button>
        <button type="button" class="btn" data-act="FAILED">✗ ${esc(t('drv.not_delivered'))}</button></div>` : ''}
      ${o.status === 'FAILED_ATTEMPT' ? `<div class="dr-acts"><button type="button" class="btn btn-primary" data-act="START">↻ ${esc(t('drv.try_again'))}</button></div>` : ''}
    </article>`;
  }

  function render() {
    const today = startOfToday();
    // on the way first, then ready at the shop, then failed ones to try again
    const todo = orders.filter((o) => o.status !== 'DELIVERED');
    const order = { OUT_FOR_DELIVERY: 0, PACKED: 1, FAILED_ATTEMPT: 2 };
    todo.sort((a, b) => order[a.status] - order[b.status] || new Date(a.out_at || a.created_at) - new Date(b.out_at || b.created_at));
    const done = orders.filter((o) => o.status === 'DELIVERED' && new Date(o.delivered_at) >= today)
      .sort((a, b) => new Date(b.delivered_at) - new Date(a.delivered_at));
    const cash = done.reduce((s, o) => s + Number(o.cash_collected || 0), 0);
    $('#dr-summary').innerHTML = `<span>${esc(t('drv.n_to_deliver', { n: todo.length }))}</span>
      <span>${esc(t('drv.n_done', { n: done.length }))}</span><span>${esc(t('drv.cash_today'))} ${money(cash)}</span>`;
    $('#dr-todo').innerHTML = todo.length ? todo.map(card).join('') : `<div class="pk-empty"><span aria-hidden="true">✓</span><p>${esc(t('drv.none'))}</p></div>`;
    $('#dr-done').innerHTML = done.length ? done.map(card).join('') : `<p class="hint">${esc(t('drv.none_done'))}</p>`;
  }

  // ---------- actions ----------
  const dlg = $('#dr-dialog');
  dlg.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => dlg.close()));
  let pending = null;   // { order, action }

  async function send(o, action, extra) {
    const { error } = await DB.client.rpc('driver_delivery', { p_order_id: o.id, p_action: action, ...extra });
    if (error) { toast(errText(error), true); return false; }
    toast(t(action === 'START' ? 'drv.started' : action === 'DELIVERED' ? 'drv.saved_delivered' : 'drv.saved_failed', { no: o.order_no }));
    await load();
    return true;
  }

  function ask(o, action) {
    pending = { o, action };
    const body = $('#dr-d-body');
    if (action === 'DELIVERED') {
      const c = collect(o);
      $('#dr-d-title').textContent = t('drv.d_delivered', { no: o.order_no });
      body.innerHTML = `<p class="dr-expect">${c.paid ? esc(t('drv.expect_paid')) : c.amount == null ? esc(t('drv.fee_unknown')) : `${esc(t('drv.expect'))} ${money(c.amount)}`}</p>
        <label for="dr-cash">${esc(t('drv.cash'))}</label>
        <input id="dr-cash" type="text" inputmode="decimal" dir="ltr" maxlength="9" value="${c.amount == null ? '' : esc(c.amount)}">
        <p class="hint">${esc(t('drv.cash_hint'))}</p>`;
      $('#dr-d-go').textContent = t('drv.confirm_delivered');
    } else {
      $('#dr-d-title').textContent = t('drv.d_failed', { no: o.order_no });
      body.innerHTML = `<p class="hint">${esc(t('drv.reason'))}</p>
        <div class="dr-reasons">${REASONS.map((r) => `<button type="button" class="chip-btn" data-reason="${r}" aria-pressed="false">${esc(t('drv.r_' + r))}</button>`).join('')}</div>
        <label for="dr-reason">${esc(t('drv.reason_other'))}</label>
        <input id="dr-reason" type="text" maxlength="300" dir="auto">`;
      body.querySelectorAll('[data-reason]').forEach((b) => b.addEventListener('click', () => {
        body.querySelectorAll('[data-reason]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
        $('#dr-reason').value = t('drv.r_' + b.dataset.reason);
      }));
      $('#dr-d-go').textContent = t('drv.confirm_failed');
    }
    dlg.showModal();
  }

  $('#dr-d-go').addEventListener('click', async () => {
    if (!pending) return;
    const { o, action } = pending;
    const btn = $('#dr-d-go');
    if (action === 'DELIVERED') {
      const raw = $('#dr-cash').value.trim().replace(',', '.');
      if (!/^\d{1,6}(\.\d{1,2})?$/.test(raw)) { toast(t('drv.err_BAD_CASH'), true); $('#dr-cash').focus(); return; }
      btn.disabled = true;
      const ok = await send(o, 'DELIVERED', { p_cash: Number(raw) });
      btn.disabled = false;
      if (ok) dlg.close();
    } else {
      const reason = $('#dr-reason').value.trim();
      if (!reason) { toast(t('drv.err_REASON_REQUIRED'), true); $('#dr-reason').focus(); return; }
      btn.disabled = true;
      const ok = await send(o, 'FAILED', { p_reason: reason });
      btn.disabled = false;
      if (ok) dlg.close();
    }
  });

  document.querySelector('.dr-main').addEventListener('click', (e) => {
    const b = e.target.closest('[data-act]');
    if (!b) return;
    const o = orders.find((x) => x.id === Number(b.closest('[data-id]').dataset.id));
    if (!o) return;
    if (b.dataset.act === 'START') { b.disabled = true; send(o, 'START').finally(() => { b.disabled = false; }); }
    else ask(o, b.dataset.act);
  });

  // ---------- keep the screen on (phones that support it) ----------
  const wakeBtn = $('#dr-wake');
  let wake = null;
  if ('wakeLock' in navigator) {
    wakeBtn.hidden = false;
    const label = () => { wakeBtn.textContent = wake ? '☀ ' + t('drv.keep_on_on') : '☀ ' + t('drv.keep_on'); };
    label();
    wakeBtn.addEventListener('click', async () => {
      try {
        if (wake) { await wake.release(); wake = null; }
        else { wake = await navigator.wakeLock.request('screen'); wake.addEventListener('release', () => { wake = null; label(); }); }
      } catch { wake = null; }
      label();
    });
  }

  // ---------- live ----------
  let reloadTimer;
  const live = $('#dr-live');
  DB.client.channel('driver-' + me.user.id)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, () => { clearTimeout(reloadTimer); reloadTimer = setTimeout(load, 400); })
    .subscribe((status) => {
      const ok = status === 'SUBSCRIBED';
      live.textContent = ok ? '● ' + t('prep.live') : t('prep.offline');
      live.className = 'pill ' + (ok ? 'pill-ok' : 'pill-warn');
    });
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') load(); });

  load();
  window.Driver = { load, collect, mapLink };
})();
