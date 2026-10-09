// Owner dashboard (Phase 3). ADMIN and OWNER, read only. One database call (staff_dashboard)
// gives every number; Lebanon time, the week starts on Monday.
//  * Sales tiles: today / this week / this month (orders, items, delivery fees).
//  * For the chosen period (7 / 30 / 90 days): orders by status, best sellers, slow items,
//    sales per governorate. Low stock and cash owed are always "now".
// Sales = orders that are not cancelled or returned; "items" = their item total (subtotal),
// delivery fees are shown separately.
(async function () {
  const me = await StaffAuth.require(['ADMIN', 'OWNER']);
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);
  const S = await DB.settings().catch(() => ({}));
  const DAYS_KEY = 'staff:dashboard:days';
  let days = 30;
  try { const d = Number(localStorage.getItem(DAYS_KEY)); if ([7, 30, 90].includes(d)) days = d; } catch { /* storage blocked */ }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  }
  const money = (n) => `<bdi>${esc(I18n.money(n, S.currency))}</bdi>`;
  const num = (n) => Number(n || 0).toLocaleString('en-US');
  const name = (o) => (I18n.lang === 'ar' && o.name_ar ? o.name_ar : o.name_en);
  const label = (o) => (I18n.lang === 'ar' && o.label_ar ? o.label_ar : o.label_en) || '';
  const date = (iso) => new Date(iso).toLocaleDateString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB', { day: 'numeric', month: 'short' });
  const OPEN = ['NEW', 'CONFIRMED', 'PACKED', 'OUT_FOR_DELIVERY', 'WITH_COMPANY', 'FAILED_ATTEMPT'];
  const CLOSED = ['DELIVERED', 'CANCELLED', 'RETURNED'];

  document.querySelectorAll('[data-days]').forEach((b) => { b.textContent = t('db.days', { n: b.dataset.days }); });

  function tile(key, s) {
    return `<div class="db-tile"><p class="db-tile-label">${esc(t('db.' + key))}</p>
      <p class="db-tile-value">${money(s.items)}</p>
      <p class="db-tile-sub">${esc(t('db.orders_n', { n: num(s.orders) }))} · ${esc(t('db.plus_delivery'))} ${money(s.delivery)}</p></div>`;
  }
  const card = (title, inner, hint) => `<section class="db-card"><h2>${esc(title)}</h2>${hint ? `<p class="hint">${esc(hint)}</p>` : ''}${inner}</section>`;
  const table = (heads, rows, empty) => (rows.length
    ? `<div class="dv-table-wrap"><table class="db-table"><thead><tr>${heads.map((h, i) => `<th${i ? ' class="num"' : ''}>${esc(h)}</th>`).join('')}</tr></thead>
       <tbody>${rows.join('')}</tbody></table></div>`
    : `<p class="hint">${esc(empty)}</p>`);

  async function load() {
    $('#db-refresh').disabled = true;
    const { data: d, error } = await DB.client.rpc('staff_dashboard', { p_days: days });
    $('#db-refresh').disabled = false;
    document.querySelectorAll('[data-days]').forEach((b) => b.setAttribute('aria-pressed', String(Number(b.dataset.days) === days)));
    if (error) { $('#db-grid').innerHTML = `<div class="alert alert-error">${esc(error.code === '42501' ? t('admin.err_permission') : t('common.error_generic'))}</div>`; return; }
    $('#db-updated').textContent = t('db.updated', { time: new Date(d.generated_at).toLocaleTimeString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB', { hour: '2-digit', minute: '2-digit' }) });
    $('#db-kpis').innerHTML = tile('today', d.sales.today) + tile('week', d.sales.week) + tile('month', d.sales.month);
    const range = d.sales.range;
    const by = d.by_status || {};

    const status = `<div class="db-status">
        <p class="db-sub">${esc(t('db.open_now'))}</p>
        <ul class="db-pills">${OPEN.map((s) => `<li><a href="prep.html"><span class="pill">${esc(t('status.' + s))}</span> <strong>${num(by[s])}</strong></a></li>`).join('')}</ul>
        <p class="db-sub">${esc(t('db.in_period', { n: days }))}</p>
        <ul class="db-pills">${CLOSED.map((s) => `<li><span class="pill">${esc(t('status.' + s))}</span> <strong>${num(by[s])}</strong></li>`).join('')}</ul>
      </div>`;

    const best = table([t('db.product'), t('db.qty'), t('db.orders'), t('db.sales')],
      d.best_sellers.map((b) => `<tr><td dir="auto">${esc(name(b))}<div class="meta" dir="ltr">${esc(b.sku)}</div></td>
        <td class="num">${num(b.qty)}</td><td class="num">${num(b.orders)}</td><td class="num">${money(b.sales)}</td></tr>`), t('db.none_sold'));

    const slow = table([t('db.product'), t('db.in_stock'), t('db.last_sold')],
      d.slow_items.map((s) => `<tr><td dir="auto">${esc(name(s))}<div class="meta" dir="ltr">${esc(s.sku)}</div></td>
        <td class="num">${num(s.stock)}</td><td class="num">${esc(s.last_sold ? date(s.last_sold) : t('db.never'))}</td></tr>`), t('db.none_slow'));

    const low = table([t('db.product'), t('db.left')],
      d.low_stock.map((l) => `<tr><td dir="auto">${esc(name(l))}${label(l) ? ` <span class="meta">(${esc(label(l))})</span>` : ''}<div class="meta" dir="ltr">${esc(l.sku)}</div></td>
        <td class="num ${l.stock === 0 ? 'bad' : ''}">${l.stock === 0 ? esc(t('db.sold_out')) : num(l.stock)}</td></tr>`), t('db.none_low'));
    const lowHint = d.low_stock_threshold == null ? t('db.low_no_setting') : t('db.low_hint', { n: d.low_stock_threshold });

    const cashRows = d.cash.drivers.map((c) => `<div class="dv-cash-line"><span>🛵 ${esc(c.name || t('dl.driver_short'))} <span class="meta">(${esc(t('db.orders_n', { n: c.orders }))})</span></span><strong>${money(c.owed)}</strong></div>`).join('');
    const owedTotal = d.cash.drivers.reduce((s, c) => s + Number(c.owed), 0) + Number(d.cash.company.owed);
    const cash = `${cashRows}
      <div class="dv-cash-line"><span>📦 ${esc(t('set.carrier_COMPANY'))} <span class="meta">(${esc(t('db.orders_n', { n: d.cash.company.orders }))})</span></span><strong>${money(d.cash.company.owed)}</strong></div>
      <div class="dv-cash-line big"><span>${esc(t('db.owed_total'))}</span><span>${money(owedTotal)}</span></div>
      <p class="hint">${esc(t('db.on_the_way', { n: d.cash.on_the_way.orders, amount: I18n.money(d.cash.on_the_way.to_collect, S.currency) }))}</p>
      <p><a class="btn btn-small" href="delivery.html">${esc(t('db.to_cash'))}</a></p>`;

    const govTotal = d.governorates.reduce((s, g) => s + Number(g.items), 0) || 1;
    const gov = table([t('db.governorate'), t('db.orders'), t('db.sales'), t('db.share')],
      d.governorates.map((g) => `<tr><td dir="auto">${esc(I18n.lang === 'ar' && g.governorate_ar ? g.governorate_ar : g.governorate)}</td>
        <td class="num">${num(g.orders)}</td><td class="num">${money(g.items)}</td><td class="num">${Math.round((Number(g.items) / govTotal) * 100)}%</td></tr>`), t('db.none_sold'));

    $('#db-grid').innerHTML =
      card(t('db.period_title', { n: days }), `<p class="db-period"><strong>${money(range.items)}</strong> · ${esc(t('db.orders_n', { n: num(range.orders) }))} · ${esc(t('db.plus_delivery'))} ${money(range.delivery)}</p>`)
      + card(t('db.by_status'), status)
      + card(t('db.cash'), cash, t('db.cash_hint'))
      + card(t('db.best'), best, t('db.best_hint', { n: days }))
      + card(t('db.slow'), slow, t('db.slow_hint', { n: days }))
      + card(t('db.low'), low, lowHint)
      + card(t('db.gov'), gov, t('db.gov_hint', { n: days }));
  }

  document.querySelectorAll('[data-days]').forEach((b) => b.addEventListener('click', () => {
    days = Number(b.dataset.days);
    try { localStorage.setItem(DAYS_KEY, String(days)); } catch { /* storage blocked */ }
    load();
  }));
  $('#db-refresh').addEventListener('click', load);
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') load(); });
  load();
  window.Dashboard = { load, me };
})();
