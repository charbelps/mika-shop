// Delivery screen (Phase 2). ADMIN acts; OWNER sees everything read-only.
//  * To send: packed orders by who delivers them. Choose our driver / the delivery company per
//    order; "Out with <driver>" for his orders; for the company: tracking numbers, the printable
//    handover sheet, "Handed over".
//  * On the way: orders out with a driver or with the company (and failed attempts). The company's
//    deliveries are confirmed here (the driver confirms his on the driver screen).
//  * Cash: what each driver and the company owe for delivered orders, and the money received.
// Every change goes through database functions that check the role and the order's status.
(async function () {
  const me = await StaffAuth.require(['ADMIN', 'OWNER']);
  const canEdit = me.role === 'ADMIN';
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);
  const S = await DB.settings().catch(() => ({}));
  const staffList = await DB.client.rpc('staff_directory').then(({ data }) => data || [], () => []);
  const drivers = () => staffList.filter((s) => s.role === 'DRIVER' && s.active);
  const staffName = (id) => (staffList.find((s) => s.user_id === id) || {}).name || t('dl.driver_short');
  const money = (n) => `<bdi>${esc(I18n.money(n, S.currency))}</bdi>`;
  const VIEW_KEY = 'staff:delivery:view';
  const COLS = 'id,order_no,created_at,status,name,phone,town,district,governorate,address,landmark,total,delivery_fee,payment_method,payment_status,' +
    'fee_tbc,fee_set_at,is_gift,recipient_name,recipient_phone,carrier,driver_id,tracking_no,out_at,failed_reason,failed_count';
  let orders = [];
  let view = 'send';
  try { const v = localStorage.getItem(VIEW_KEY); if (['send', 'way', 'cash'].includes(v)) view = v; } catch { /* storage blocked */ }

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
    for (const k of ['dv.err_' + code, 'prep.err_' + code]) if (t(k) !== k) return t(k);
    return t('common.error_generic') + ' (' + ((error && error.message) || '') + ')';
  }
  const when = (iso) => new Date(iso).toLocaleString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB',
    { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
  const who = (o) => (o.is_gift ? t('drv.gift_for', { name: o.recipient_name || '' }) : o.name);
  // what the driver / company collects (gifts are prepaid); amount null = fee not set yet
  function toCollect(o) {
    const c = DB.amountToCollect(o);
    return o.is_gift || c.kind === 'paid' ? { paid: true, amount: 0 } : { paid: false, amount: c.amount };
  }
  function moneyHtml(o) {
    const c = toCollect(o);
    if (c.paid) return `<span class="dv-money paid">${esc(t('dv.paid'))}</span>`;
    if (c.amount == null) return `<span class="dv-money">${esc(t('dv.fee_unknown'))}</span>`;
    return `<span class="dv-money">${esc(t('dv.collect'))} ${money(c.amount)}</span>`;
  }
  const sumCollect = (list) => list.reduce((s, o) => s + (toCollect(o).amount || 0), 0);

  $('#dv-readonly').hidden = canEdit;

  // ---------- data ----------
  let req = 0;
  async function load() {
    const my = ++req;
    const { data, error } = await DB.client.from('orders').select(COLS)
      .in('status', ['PACKED', 'OUT_FOR_DELIVERY', 'WITH_COMPANY', 'FAILED_ATTEMPT'])
      .order('created_at', { ascending: true }).limit(300);
    if (my !== req) return;
    if (error) { $('#dv-send').innerHTML = `<div class="alert alert-error">${esc(errText(error))}</div>`; return; }
    orders = data || [];
    render();
  }

  // ---------- pieces ----------
  function whoSelect(o) {
    if (!canEdit) return '';
    const val = o.carrier === 'COMPANY' ? 'COMPANY' : o.carrier === 'DRIVER' && o.driver_id ? 'D:' + o.driver_id : '';
    return `<select data-assign="${o.id}" aria-label="${esc(t('dl.by'))}">
      <option value="">${esc(t('dv.who_choose'))}</option>
      ${drivers().map((d) => `<option value="D:${esc(d.user_id)}" ${val === 'D:' + d.user_id ? 'selected' : ''}>🛵 ${esc(d.name)}</option>`).join('')}
      <option value="COMPANY" ${val === 'COMPANY' ? 'selected' : ''}>📦 ${esc(t('set.carrier_COMPANY'))}</option></select>`;
  }
  function row(o, { box = false, ctl = '' } = {}) {
    const box2 = box && canEdit;
    return `<li class="dv-row${box2 ? '' : ' no-box'}" data-id="${o.id}">
      ${box2 ? `<input type="checkbox" data-pick="${o.id}" checked aria-label="${esc(t('dv.pick', { no: o.order_no }))}">` : ''}
      <div class="dv-what"><strong><span dir="ltr">${esc(o.order_no)}</span> · <span dir="auto">${esc(who(o))}</span></strong>
        <span class="meta" dir="auto">${esc(o.town)}, ${esc(o.district)} · ${esc(o.address)}</span>
        ${moneyHtml(o)}
        ${o.status === 'FAILED_ATTEMPT' ? `<span class="meta">⚠ ${esc(t('dl.failed_msg', { n: o.failed_count, reason: o.failed_reason || '' }))}</span>` : ''}
        ${o.status !== 'PACKED' && o.out_at ? `<span class="meta">${esc(t('dl.left_at', { when: when(o.out_at) }))}${o.tracking_no ? ' · ' + esc(t('dl.tracking')) + ': ' + esc(o.tracking_no) : ''}</span>` : ''}
      </div>
      ${ctl ? `<div class="dv-ctl">${ctl}</div>` : ''}
    </li>`;
  }
  const empty = (key) => `<div class="pk-empty"><span aria-hidden="true">✓</span><p>${esc(t(key))}</p></div>`;
  const openLink = (o) => `<a class="btn btn-small" href="prep.html?open=${o.id}">${esc(t('dv.open'))}</a>`;

  // ---------- To send ----------
  function renderSend() {
    const packed = orders.filter((o) => o.status === 'PACKED');
    $('#dv-n-send').textContent = packed.length ? `(${packed.length})` : '';
    if (!packed.length) { $('#dv-send').innerHTML = empty('dv.none_send'); return; }
    const none = packed.filter((o) => !o.carrier || (o.carrier === 'DRIVER' && !o.driver_id));
    const company = packed.filter((o) => o.carrier === 'COMPANY');
    const byDriver = new Map();
    packed.filter((o) => o.carrier === 'DRIVER' && o.driver_id).forEach((o) => {
      if (!byDriver.has(o.driver_id)) byDriver.set(o.driver_id, []);
      byDriver.get(o.driver_id).push(o);
    });
    let html = '';
    if (none.length) {
      html += `<div class="dv-group" data-group="none"><h2>${esc(t('dv.g_none', { n: none.length }))}</h2>
        <p class="hint">${esc(t(drivers().length ? 'dv.g_none_hint' : 'dl.no_drivers'))}</p>
        <ul class="dv-rows">${none.map((o) => row(o, { ctl: whoSelect(o) })).join('')}</ul></div>`;
    }
    for (const [id, list] of byDriver) {
      html += `<div class="dv-group" data-group="D:${esc(id)}"><h2>🛵 ${esc(staffName(id))} (${list.length})</h2>
        <p class="hint">${esc(t('dv.to_collect', { amount: I18n.money(sumCollect(list), S.currency) }))}</p>
        <ul class="dv-rows">${list.map((o) => row(o, { box: true, ctl: whoSelect(o) })).join('')}</ul>
        ${canEdit ? `<div class="dv-acts"><button type="button" class="btn btn-primary" data-out="${esc(id)}">🛵 ${esc(t('dv.out_with', { name: staffName(id) }))}</button></div>` : ''}</div>`;
    }
    if (company.length) {
      html += `<div class="dv-group" data-group="COMPANY"><h2>📦 ${esc(t('set.carrier_COMPANY'))} (${company.length})</h2>
        <p class="hint">${esc(t('dv.company_hint'))} ${esc(t('dv.to_collect', { amount: I18n.money(sumCollect(company), S.currency) }))}</p>
        <ul class="dv-rows">${company.map((o) => row(o, { box: true,
          ctl: (canEdit ? `<input type="text" data-track="${o.id}" dir="ltr" maxlength="60" placeholder="${esc(t('dl.tracking'))}" value="${esc(o.tracking_no || '')}">` : '') + whoSelect(o) })).join('')}</ul>
        <div class="dv-acts"><button type="button" class="btn" data-sheet>🖨️ ${esc(t('dv.sheet'))}</button>
          ${canEdit ? `<button type="button" class="btn btn-primary" data-handed>📦 ${esc(t('dv.handed'))}</button>` : ''}</div></div>`;
    }
    $('#dv-send').innerHTML = html;
  }

  // ---------- On the way ----------
  function renderWay() {
    const way = orders.filter((o) => ['OUT_FOR_DELIVERY', 'WITH_COMPANY', 'FAILED_ATTEMPT'].includes(o.status));
    $('#dv-n-way').textContent = way.length ? `(${way.length})` : '';
    if (!way.length) { $('#dv-way').innerHTML = empty('dv.none_way'); return; }
    const company = way.filter((o) => o.carrier === 'COMPANY');
    const byDriver = new Map();
    way.filter((o) => o.carrier !== 'COMPANY').forEach((o) => {
      const k = o.driver_id || '';
      if (!byDriver.has(k)) byDriver.set(k, []);
      byDriver.get(k).push(o);
    });
    let html = '';
    for (const [id, list] of byDriver) {
      html += `<div class="dv-group"><h2>🛵 ${esc(id ? staffName(id) : t('dl.driver_none'))} (${list.length})</h2>
        <p class="hint">${esc(t('dv.driver_way_hint'))} ${esc(t('dv.to_collect', { amount: I18n.money(sumCollect(list), S.currency) }))}</p>
        <ul class="dv-rows">${list.map((o) => row(o, { ctl: `<span class="pill">${esc(t('status.' + o.status))}</span>` + openLink(o) })).join('')}</ul></div>`;
    }
    if (company.length) {
      html += `<div class="dv-group"><h2>📦 ${esc(t('set.carrier_COMPANY'))} (${company.length})</h2>
        <p class="hint">${esc(t('dv.company_way_hint'))}</p>
        <ul class="dv-rows">${company.map((o) => row(o, { ctl: `<span class="pill">${esc(t('status.' + o.status))}</span>`
          + (canEdit && o.status === 'WITH_COMPANY' ? `<button type="button" class="btn btn-small btn-primary" data-deliver="${o.id}">✓ ${esc(t('dl.delivered'))}</button>
             <button type="button" class="btn btn-small" data-fail="${o.id}">✗ ${esc(t('dl.failed'))}</button>` : '') + openLink(o) })).join('')}</ul></div>`;
    }
    $('#dv-way').innerHTML = html;
  }

  function render() {
    document.querySelectorAll('.dv-views .pk-view').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.view === view)));
    ['send', 'way', 'cash'].forEach((v) => { $('#dv-' + v).hidden = v !== view; });
    renderSend();
    renderWay();
    if (view === 'cash' && window.DeliveryCash) window.DeliveryCash.show();
  }

  // ---------- company handover sheet (printed) ----------
  function printSheet(list) {
    const shop = [S.shop_name_en, S.shop_name_ar].filter(Boolean).join(' · ');
    const track = (o) => { const el = $(`[data-track="${o.id}"]`); return el ? el.value.trim() : (o.tracking_no || ''); };
    const cell = (o) => { const c = toCollect(o); return c.paid ? esc(t('dv.m_paid')) : c.amount == null ? '?' : `<bdi>${esc(I18n.money(c.amount, S.currency))}</bdi>`; };
    $('#manifest').innerHTML = `
      <div class="slip-head"><div class="slip-shop">${esc(shop)}</div>
        <div><strong>${esc(t('dv.m_title'))}</strong></div>
        <div><span class="slip-label">${esc(t('dv.m_company'))}</span> ${esc(S.delivery_company_name || '____________________')}</div>
        <div><span class="slip-label">${esc(t('prep.slip_date'))}</span> ${esc(new Date().toLocaleString('en-GB'))}</div></div>
      <table class="slip-items mf"><thead><tr><th>#</th><th>${esc(t('prep.slip_order'))}</th><th>${esc(t('prep.slip_customer'))}</th><th>${esc(t('prep.slip_phone'))}</th>
        <th>${esc(t('prep.slip_address'))}</th><th>${esc(t('dv.m_collect'))}</th><th>${esc(t('dv.m_tracking'))}</th></tr></thead><tbody>
        ${list.map((o, i) => `<tr><td>${i + 1}</td><td dir="ltr">${esc(o.order_no)}</td><td>${esc(o.is_gift ? o.recipient_name : o.name)}</td>
          <td dir="ltr">${esc(o.is_gift ? o.recipient_phone : o.phone)}</td><td>${esc(o.town)}, ${esc(o.district)} (${esc(o.governorate)})<br>${esc(o.address)}${o.landmark ? '<br>' + esc(o.landmark) : ''}</td>
          <td>${cell(o)}</td><td dir="ltr">${esc(track(o))}</td></tr>`).join('')}
      </tbody></table>
      <div class="slip-total">${esc(t('dv.m_total', { n: list.length }))} <bdi>${esc(I18n.money(sumCollect(list), S.currency))}</bdi></div>
      <div class="mf-sign"><div>${esc(t('dv.m_handed_by'))} ____________________</div><div>${esc(t('dv.m_received_by'))} ____________________</div></div>`;
    window.print();
  }

  // ---------- small questions ----------
  const dlg = $('#dv-dialog');
  dlg.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => dlg.close()));
  let answer = null;
  function ask(title, bodyHtml, goLabel, onGo) {
    $('#dv-d-title').textContent = title;
    $('#dv-d-body').innerHTML = bodyHtml;
    $('#dv-d-go').textContent = goLabel;
    answer = onGo;
    dlg.showModal();
    const first = $('#dv-d-body input');
    if (first) first.focus();
  }
  $('#dv-d-go').addEventListener('click', async () => {
    if (!answer) return;
    const btn = $('#dv-d-go');
    btn.disabled = true;
    const ok = await answer();
    btn.disabled = false;
    if (ok) dlg.close();
  });
  window.DeliveryDialog = { ask, toast, errText, money, esc };

  // several orders, one after the other; one summary at the end
  async function runAll(ids, fn, doneKey) {
    let ok = 0;
    let firstError = null;
    for (const id of ids) {
      const { error } = await fn(id);
      if (error) firstError ||= error; else ok++;
    }
    if (firstError) toast(t('dv.some_failed', { ok, n: ids.length }) + ' ' + errText(firstError), true);
    else toast(t(doneKey, { n: ok }));
    await load();
  }
  const checked = (group) => [...group.querySelectorAll('[data-pick]:checked')].map((b) => Number(b.dataset.pick));

  // ---------- events ----------
  document.querySelectorAll('.dv-views .pk-view').forEach((b) => b.addEventListener('click', () => {
    view = b.dataset.view;
    try { localStorage.setItem(VIEW_KEY, view); } catch { /* storage blocked */ }
    render();
  }));
  document.querySelector('.dv-main').addEventListener('change', async (e) => {
    const sel = e.target.closest('[data-assign]');
    if (!sel || !canEdit) return;
    const v = sel.value;
    const args = { p_order_id: Number(sel.dataset.assign), p_carrier: v === 'COMPANY' ? 'COMPANY' : v ? 'DRIVER' : null,
      p_driver_id: v.startsWith('D:') ? v.slice(2) : null };
    sel.disabled = true;
    const { error } = await DB.client.rpc('staff_assign_delivery', args);
    sel.disabled = false;
    if (error) toast(errText(error), true); else toast(t('prep.saved'));
    load();
  });
  document.querySelector('.dv-main').addEventListener('click', (e) => {
    const out = e.target.closest('[data-out]');
    const sheet = e.target.closest('[data-sheet]');
    const handed = e.target.closest('[data-handed]');
    const deliver = e.target.closest('[data-deliver]');
    const fail = e.target.closest('[data-fail]');
    if (out && canEdit) {
      const ids = checked(out.closest('.dv-group'));
      if (!ids.length) { toast(t('dv.pick_some'), true); return; }
      runAll(ids, (id) => DB.client.rpc('staff_delivery', { p_order_id: id, p_action: 'OUT' }), 'dv.done_out');
    }
    if (sheet) {
      const group = sheet.closest('.dv-group');
      const ids = canEdit ? checked(group) : orders.filter((o) => o.status === 'PACKED' && o.carrier === 'COMPANY').map((o) => o.id);
      if (!ids.length) { toast(t('dv.pick_some'), true); return; }
      printSheet(orders.filter((o) => ids.includes(o.id)));
    }
    if (handed && canEdit) {
      const ids = checked(handed.closest('.dv-group'));
      if (!ids.length) { toast(t('dv.pick_some'), true); return; }
      runAll(ids, (id) => DB.client.rpc('staff_delivery', { p_order_id: id, p_action: 'COMPANY', p_tracking: ($(`[data-track="${id}"]`) || {}).value || null }), 'dv.done_handed');
    }
    if (deliver && canEdit) {
      const o = orders.find((x) => x.id === Number(deliver.dataset.deliver));
      const c = toCollect(o);
      ask(t('drv.d_delivered', { no: o.order_no }),
        `<label for="dv-cash-in">${esc(t('dl.cash'))}</label><input id="dv-cash-in" type="text" inputmode="decimal" dir="ltr" maxlength="9" value="${c.amount == null ? '' : esc(c.amount)}">
         <p class="hint">${esc(t('dv.company_cash_hint'))}</p>`,
        t('drv.confirm_delivered'), async () => {
          const raw = $('#dv-cash-in').value.trim().replace(',', '.');
          if (!/^\d{1,6}(\.\d{1,2})?$/.test(raw)) { toast(t('prep.err_BAD_CASH'), true); return false; }
          const { error } = await DB.client.rpc('staff_delivery', { p_order_id: o.id, p_action: 'DELIVERED', p_cash: Number(raw) });
          if (error) { toast(errText(error), true); return false; }
          toast(t('drv.saved_delivered', { no: o.order_no }));
          load();
          return true;
        });
    }
    if (fail && canEdit) {
      const o = orders.find((x) => x.id === Number(fail.dataset.fail));
      ask(t('drv.d_failed', { no: o.order_no }),
        `<label for="dv-reason">${esc(t('dl.fail_reason'))}</label><input id="dv-reason" type="text" maxlength="300" dir="auto">`,
        t('drv.confirm_failed'), async () => {
          const reason = $('#dv-reason').value.trim();
          if (!reason) { toast(t('prep.err_REASON_REQUIRED'), true); return false; }
          const { error } = await DB.client.rpc('staff_delivery', { p_order_id: o.id, p_action: 'FAILED', p_reason: reason });
          if (error) { toast(errText(error), true); return false; }
          toast(t('drv.saved_failed', { no: o.order_no }));
          load();
          return true;
        });
    }
  });

  // ---------- live ----------
  let reloadTimer;
  const live = $('#dv-live');
  DB.client.channel('delivery')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, () => { clearTimeout(reloadTimer); reloadTimer = setTimeout(load, 400); })
    .subscribe((status) => {
      const ok = status === 'SUBSCRIBED';
      live.textContent = ok ? '● ' + t('prep.live') : t('prep.offline');
      live.className = 'pill ' + (ok ? 'pill-ok' : 'pill-warn');
    });
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') load(); });

  window.Delivery = { load, me, canEdit, S, staffList, staffName, toCollect, printSheet };
  load();
})();
