// Packing tab (Phase 1c, P1): orders that are ready to pack, shown two ways.
//  * Pick list: every item of those orders added up (e.g. "Ceramic mug x3, in 2 orders"), with a
//    tick when it has been taken from the shelf.
//  * Order cards: one big card per order (oldest first) with a tick per item, then "Packed".
// Ready to pack = NEW or CONFIRMED, and cash on delivery or already paid (Charbel 9 Oct): unpaid
// Whish / OMT orders stay in "Waiting for payment" on the Orders screen.
// Ticks are shared (order_items.picked / checked, saved by staff_tick_items) and never block
// "Packed". ADMIN acts; OWNER sees everything read-only. Live: orders and ticks via Realtime.
(async function () {
  const me = await StaffAuth.require(['ADMIN', 'OWNER']);
  const canEdit = me.role === 'ADMIN';
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);
  const S = await DB.settings().catch(() => ({}));
  const money = (n) => `<bdi>${esc(I18n.money(n, S.currency))}</bdi>`;
  const VIEW_KEY = 'staff:packing:view';
  let orders = [];
  let view = 'pick';
  try { if (localStorage.getItem(VIEW_KEY) === 'cards') view = 'cards'; } catch { /* storage blocked */ }

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
    const k = 'prep.err_' + code;
    return t(k) !== k ? t(k) : t('common.error_generic') + ' (' + ((error && error.message) || '') + ')';
  }
  const itemName = (i) => (I18n.lang === 'ar' && i.name_ar ? i.name_ar : i.name_en);
  const itemLabel = (i) => (I18n.lang === 'ar' && i.label_ar) || i.label || '';
  const when = (iso) => new Date(iso).toLocaleString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB',
    { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });

  $('#pk-readonly').hidden = canEdit;

  // ---------- data ----------
  let req = 0;
  async function load() {
    const my = ++req;
    const { data, error } = await DB.client.from('orders')
      .select('id,order_no,created_at,name,town,district,total,delivery_fee,payment_method,payment_status,status,source,is_first_order,notes,fee_tbc,fee_set_at,' +
              'is_gift,recipient_name,gift_note,' +
              'order_items(id,sku,variant_id,name_en,name_ar,label,label_ar,qty,picked,checked)')
      .in('status', ['NEW', 'CONFIRMED'])
      .or('payment_method.eq.COD,payment_status.eq.PAID')
      .order('created_at', { ascending: true })
      .limit(200);
    if (my !== req) return;          // a newer load is on its way
    if (error) { $('#pk-pick').innerHTML = $('#pk-cards').innerHTML = `<div class="alert alert-error">${esc(errText(error))}</div>`; return; }
    orders = (data || []).map((o) => ({ ...o, order_items: (o.order_items || []).slice().sort((a, b) => a.id - b.id) }));
    render();
  }

  // the pick list: same product + same option added up over all ready orders
  function pickRows() {
    const rows = new Map();
    orders.forEach((o) => o.order_items.forEach((i) => {
      const key = i.sku + '|' + (i.variant_id || '');
      if (!rows.has(key)) rows.set(key, { key, sku: i.sku, name: itemName(i), label: itemLabel(i), qty: 0, picked: 0, ids: [], orders: [] });
      const r = rows.get(key);
      r.qty += i.qty;
      if (i.picked) r.picked += i.qty;
      r.ids.push(i.id);
      if (!r.orders.includes(o.order_no)) r.orders.push(o.order_no);
    }));
    return [...rows.values()].sort((a, b) => a.name.localeCompare(b.name, I18n.lang) || a.label.localeCompare(b.label, I18n.lang));
  }

  // ---------- render ----------
  function tickBox(on, attrs) {
    return `<button type="button" class="pk-tick" role="checkbox" aria-checked="${on}" ${canEdit ? '' : 'disabled'} ${attrs}>
      <span class="pk-box" aria-hidden="true">${on ? '✓' : ''}</span>`;
  }

  function render() {
    const rows = pickRows();
    $('#pk-n-pick').textContent = rows.length ? `(${rows.length})` : '';
    $('#pk-n-cards').textContent = orders.length ? `(${orders.length})` : '';
    document.querySelectorAll('.pk-view').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.view === view)));
    $('#pk-pick').hidden = view !== 'pick';
    $('#pk-cards').hidden = view !== 'cards';
    const empty = `<div class="pk-empty"><span aria-hidden="true">✓</span><p>${esc(t('pk.empty'))}</p></div>`;

    $('#pk-pick').innerHTML = !rows.length ? empty : `
      <p class="hint">${esc(t('pk.pick_help'))}</p>
      <ul class="pk-list">${rows.map((r) => {
        const all = r.picked >= r.qty;
        const part = r.picked > 0 && !all;
        return `<li class="pk-row${all ? ' done' : ''}">
          ${tickBox(all, `data-pick="${esc(r.key)}" aria-label="${esc(t('pk.tick_picked', { name: r.name }))}"`)}
            <span class="pk-qty" dir="ltr">×${r.qty}</span>
            <span class="pk-what"><span class="pk-name" dir="auto">${esc(r.name)}</span>
              ${r.label ? `<span class="pk-label" dir="auto">${esc(r.label)}</span>` : ''}
              <span class="pk-meta">${esc(t(r.orders.length === 1 ? 'pk.in_one_order' : 'pk.in_orders', { n: r.orders.length }))}
                · <span dir="ltr">${r.orders.map(esc).join(', ')}</span>${part ? ` · ${esc(t('pk.picked_of', { n: r.picked, total: r.qty }))}` : ''}</span>
            </span>
          </button>
        </li>`;
      }).join('')}</ul>`;

    $('#pk-cards').innerHTML = !orders.length ? empty : orders.map((o) => {
      const done = o.order_items.filter((i) => i.checked).length;
      const n = o.order_items.length;
      const c = DB.amountToCollect(o);
      return `<article class="pk-card${done === n ? ' all-done' : ''}" data-order="${o.id}">
        <header class="pk-card-head">
          <div>
            <h2 dir="ltr">${esc(o.order_no)}</h2>
            ${o.is_gift
              ? `<p class="pk-who" dir="auto">${esc(t('pk.gift_to', { name: o.recipient_name }))}</p><p class="hint" dir="auto">${esc(t('pk.gift_from', { name: o.name }))}</p>`
              : `<p class="pk-who" dir="auto">${esc(o.name)}</p>`}
            <p class="hint">${esc(o.town)}, ${esc(o.district)} · ${esc(when(o.created_at))}</p>
          </div>
          <div class="pk-pay ${c.kind === 'paid' ? 'paid' : 'collect'}">${c.kind === 'paid' ? esc(t('pk.paid'))
            : c.kind === 'fee' ? `${esc(t('pk.items_paid'))}<br>${esc(t('pk.collect_fee'))} ${c.amount == null ? esc(t('pk.fee_tbc_short')) : money(c.amount)}`
            : `${esc(t('pk.collect'))} ${money(c.amount)}${c.feePending ? `<br><small>${esc(t('pk.plus_fee_tbc'))}</small>` : ''}`}</div>
        </header>
        <div class="od-pills">
          ${o.is_gift ? `<span class="pill pill-gift">${esc(t('prep.gift'))}</span>` : ''}
          ${o.fee_tbc && !o.fee_set_at ? `<span class="pill pill-warn" title="${esc(t('prep.fee_tbc_hint'))}">${esc(t('prep.fee_tbc'))}</span>` : ''}
          ${o.is_first_order ? `<span class="pill pill-warn" title="${esc(t('prep.new_customer_hint'))}">${esc(t('prep.new_customer'))}</span>` : ''}
          ${o.source && o.source !== 'WEBSITE' ? `<span class="pill">${esc(t('prep.src_' + o.source))}</span>` : ''}
          <span class="pill">${esc(t('status.' + o.status))}</span>
        </div>
        ${o.is_gift ? `<p class="pk-giftcard" dir="auto">${esc(o.gift_note ? t('pk.card', { note: o.gift_note }) : t('pk.no_card'))}</p>` : ''}
        ${o.notes ? `<p class="pk-notes" dir="auto">📝 ${esc(o.notes)}</p>` : ''}
        <ul class="pk-list">${o.order_items.map((i) => `<li class="pk-row${i.checked ? ' done' : ''}">
          ${tickBox(i.checked, `data-check="${i.id}" data-order="${o.id}" aria-label="${esc(t('pk.tick_checked', { name: itemName(i) }))}"`)}
            <span class="pk-qty" dir="ltr">×${i.qty}</span>
            <span class="pk-what"><span class="pk-name" dir="auto">${esc(itemName(i))}</span>
              ${itemLabel(i) ? `<span class="pk-label" dir="auto">${esc(itemLabel(i))}</span>` : ''}
              <span class="pk-meta" dir="ltr">${esc(i.sku)}</span></span>
          </button>
        </li>`).join('')}</ul>
        <footer class="pk-card-foot">
          <span class="pk-progress">${esc(t('pk.checked_of', { n: done, total: n }))}</span>
          <a class="btn btn-small" href="prep.html?open=${o.id}">${esc(t('pk.details'))}</a>
          ${canEdit ? `<button type="button" class="btn btn-primary pk-packed" data-packed="${o.id}">✓ ${esc(t('pk.packed'))}</button>` : ''}
        </footer>
      </article>`;
    }).join('');
  }

  // ---------- actions ----------
  function setView(v) {
    view = v;
    try { localStorage.setItem(VIEW_KEY, v); } catch { /* storage blocked */ }
    render();
  }
  document.querySelectorAll('.pk-view').forEach((b) => b.addEventListener('click', () => setView(b.dataset.view)));

  async function tick(ids, field, value) {
    // show it straight away; the database answer (or the next live update) has the last word
    orders.forEach((o) => o.order_items.forEach((i) => { if (ids.includes(i.id)) i[field] = value; }));
    render();
    const { error } = await DB.client.rpc('staff_tick_items', { p_item_ids: ids, p_field: field, p_value: value });
    if (error) { toast(errText(error), true); load(); }
  }

  document.querySelector('.pk-main').addEventListener('click', async (e) => {
    if (!canEdit) return;
    const pick = e.target.closest('[data-pick]');
    if (pick) {
      const r = pickRows().find((x) => x.key === pick.dataset.pick);
      if (r) tick(r.ids, 'picked', r.picked < r.qty);
      return;
    }
    const check = e.target.closest('[data-check]');
    if (check) {
      const id = Number(check.dataset.check);
      const item = orders.flatMap((o) => o.order_items).find((i) => i.id === id);
      if (item) tick([id], 'checked', !item.checked);
      return;
    }
    const packed = e.target.closest('[data-packed]');
    if (packed) {
      const id = Number(packed.dataset.packed);
      const o = orders.find((x) => x.id === id);
      packed.disabled = true;
      const { error } = await DB.client.rpc('staff_set_status', { p_order_id: id, p_status: 'PACKED' });
      if (error) { packed.disabled = false; toast(errText(error), true); return; }
      orders = orders.filter((x) => x.id !== id);
      render();
      toast(t('pk.packed_toast', { no: o ? o.order_no : '' }));
    }
  });

  // ---------- live ----------
  let reloadTimer;
  function onChange(payload) {
    if (payload && payload.table === 'orders' && payload.eventType === 'INSERT' && payload.new && payload.new.order_no) {
      toast(t('prep.new_order', { no: payload.new.order_no }));
    }
    clearTimeout(reloadTimer);
    reloadTimer = setTimeout(load, 400);
  }
  const live = $('#pk-live');
  DB.client.channel('packing')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, onChange)
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'order_items' }, onChange)
    .subscribe((status) => {
      const ok = status === 'SUBSCRIBED';
      live.textContent = ok ? '● ' + t('prep.live') : t('prep.offline');
      live.className = 'pill ' + (ok ? 'pill-ok' : 'pill-warn');
    });
  // coming back to the tab (phone screen was off): refresh, a live update may have been missed
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') load(); });

  load();
  window.Packing = { load };
})();
