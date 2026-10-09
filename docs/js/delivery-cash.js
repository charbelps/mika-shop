// Delivery screen, Cash tab (Phase 2): what our driver(s) and the delivery company owe for
// delivered orders whose cash wasn't handed over yet, and the cash Mika received before.
// Owed per order = the cash recorded as collected at delivery. "Record cash received" saves what
// Mika really got (staff_settle_cash keeps the difference, e.g. the company's own fee).
(function () {
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);
  const when = (iso) => new Date(iso).toLocaleString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB',
    { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
  let open = [];

  async function show() {
    const D = window.Delivery;
    const U = window.DeliveryDialog;
    if (!D || !U) return;
    const { esc } = U;
    const money = (n) => `<bdi>${esc(I18n.money(n, D.S.currency))}</bdi>`;
    const box = $('#dv-cash');
    if (!box.innerHTML) box.innerHTML = `<p class="hint">${esc(t('common.loading'))}</p>`;
    const [o, l] = await Promise.all([
      DB.client.from('orders')
        .select('id,order_no,name,is_gift,recipient_name,carrier,driver_id,cash_collected,delivered_at,total,delivery_fee,payment_method,payment_status,fee_tbc,fee_set_at')
        .not('delivered_at', 'is', null).is('cash_log_id', null).order('delivered_at', { ascending: true }).limit(500),
      DB.client.from('cash_log').select('id,created_at,source,driver_id,order_ids,expected,received,difference,note')
        .order('created_at', { ascending: false }).limit(30),
    ]);
    if (o.error || l.error) { box.innerHTML = `<div class="alert alert-error">${esc(U.errText(o.error || l.error))}</div>`; return; }
    open = o.data || [];
    const groups = new Map();
    open.forEach((x) => {
      const k = x.carrier === 'COMPANY' ? 'COMPANY' : 'D:' + (x.driver_id || '');
      if (!groups.has(k)) groups.set(k, []);
      groups.get(k).push(x);
    });
    const owed = (list) => list.reduce((s, x) => s + Number(x.cash_collected || 0), 0);
    let html = '';
    for (const [k, list] of groups) {
      const company = k === 'COMPANY';
      const name = company ? '' : D.staffName(k.slice(2));
      html += `<div class="dv-group" data-cash="${esc(k)}">
        <h2>${esc(company ? t('dv.owes_company', { amount: I18n.money(owed(list), D.S.currency) }) : t('dv.owes_driver', { name, amount: I18n.money(owed(list), D.S.currency) }))}</h2>
        <p class="hint">${esc(t('dv.open_n', { n: list.length }))}${company ? ' ' + esc(t('dv.company_fee_hint')) : ''}</p>
        <ul class="dv-rows">${list.map((x) => {
          const c = D.toCollect(x);
          const diff = !c.paid && c.amount != null && Number(c.amount) !== Number(x.cash_collected || 0);
          return `<li class="dv-row${D.canEdit ? '' : ' no-box'}">
            ${D.canEdit ? `<input type="checkbox" data-cpick="${x.id}" checked aria-label="${esc(t('dv.pick', { no: x.order_no }))}">` : ''}
            <div class="dv-what"><strong><span dir="ltr">${esc(x.order_no)}</span> · <span dir="auto">${esc(x.is_gift ? x.recipient_name : x.name)}</span></strong>
              <span class="meta">${esc(t('dv.delivered_at', { when: when(x.delivered_at) }))} · ${esc(t('dv.collected', { amount: I18n.money(x.cash_collected || 0, D.S.currency) }))}</span>
              ${diff ? `<span class="meta dv-diff-bad">${esc(t('dv.mismatch', { amount: I18n.money(c.amount, D.S.currency) }))}</span>` : ''}</div></li>`;
        }).join('')}</ul>
        <div class="dv-cash-line big"><span>${esc(t('dv.total'))}</span><span>${money(owed(list))}</span></div>
        ${D.canEdit ? `<div class="dv-acts"><button type="button" class="btn btn-primary" data-settle="${esc(k)}">💵 ${esc(t('dv.record'))}</button></div>` : ''}
      </div>`;
    }
    if (!groups.size) html += `<div class="pk-empty"><span aria-hidden="true">✓</span><p>${esc(t('dv.none_owed'))}</p></div>`;
    const log = l.data || [];
    html += `<div class="dv-group"><h2>${esc(t('dv.history'))}</h2>${log.length ? `<div class="dv-table-wrap"><table class="dv-log"><thead><tr>
        <th>${esc(t('dv.h_date'))}</th><th>${esc(t('dv.h_from'))}</th><th>${esc(t('dv.h_orders'))}</th><th>${esc(t('dv.h_expected'))}</th>
        <th>${esc(t('dv.h_received'))}</th><th>${esc(t('dv.h_diff'))}</th><th>${esc(t('dv.h_note'))}</th></tr></thead><tbody>
        ${log.map((r) => `<tr><td>${esc(when(r.created_at))}</td><td>${esc(r.source === 'COMPANY' ? t('set.carrier_COMPANY') : D.staffName(r.driver_id))}</td>
          <td>${r.order_ids.length}</td><td>${money(r.expected)}</td><td>${money(r.received)}</td>
          <td class="${Number(r.difference) < 0 ? 'dv-diff-bad' : ''}">${money(r.difference)}</td><td dir="auto">${esc(r.note || '')}</td></tr>`).join('')}
      </tbody></table></div>` : `<p class="hint">${esc(t('dv.none_history'))}</p>`}</div>`;
    box.innerHTML = html;
  }

  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-settle]');
    if (!b) return;
    const D = window.Delivery;
    const U = window.DeliveryDialog;
    if (!D || !D.canEdit) return;
    const { esc } = U;
    const group = b.closest('.dv-group');
    const ids = [...group.querySelectorAll('[data-cpick]:checked')].map((x) => Number(x.dataset.cpick));
    if (!ids.length) { U.toast(t('dv.pick_some'), true); return; }
    const k = b.dataset.settle;
    const company = k === 'COMPANY';
    const expected = open.filter((x) => ids.includes(x.id)).reduce((s, x) => s + Number(x.cash_collected || 0), 0);
    const from = company ? t('set.carrier_COMPANY') : D.staffName(k.slice(2));
    U.ask(t('dv.d_title', { name: from }),
      `<p class="dr-expect">${esc(t('dv.expected', { n: ids.length, amount: I18n.money(expected, D.S.currency) }))}</p>
       <label for="dv-received">${esc(t('dv.received'))}</label>
       <input id="dv-received" type="text" inputmode="decimal" dir="ltr" maxlength="10" value="${esc(Math.round(expected * 100) / 100)}">
       <label for="dv-note" style="margin-top:.75rem">${esc(t('dv.note'))}</label>
       <input id="dv-note" type="text" maxlength="300" dir="auto" placeholder="${esc(t(company ? 'dv.note_ph_company' : 'dv.note_ph'))}">`,
      t('dv.save_cash'), async () => {
        const raw = $('#dv-received').value.trim().replace(',', '.');
        if (!/^\d{1,7}(\.\d{1,2})?$/.test(raw)) { U.toast(t('prep.err_BAD_CASH'), true); return false; }
        const { data, error } = await DB.client.rpc('staff_settle_cash', {
          p_source: company ? 'COMPANY' : 'DRIVER', p_driver_id: company ? null : k.slice(2),
          p_order_ids: ids, p_received: Number(raw), p_note: $('#dv-note').value.trim() || null,
        });
        if (error) { U.toast(U.errText(error), true); show(); return false; }
        const diff = Number(data && data.difference) || 0;
        U.toast(t('dv.cash_saved', { amount: I18n.money(Number(raw), D.S.currency) })
          + (diff ? ' · ' + t('dv.diff', { amount: I18n.money(diff, D.S.currency) }) : ''));
        show();
        return true;
      });
  });

  window.DeliveryCash = { show };
})();
