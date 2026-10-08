// Cart page + checkout page. The order itself is created by the database function
// place_order (step 7), which re-checks everything and takes prices from the database.
(function () {
  const t = (k, v) => I18n.t(k, v);
  const $ = (s, r = document) => r.querySelector(s);
  const esc = (s) => Shop.esc(s);
  const moneyHtml = (n) => `<bdi>${esc(Shop.money(n))}</bdi>`;
  const lineName = (l) => (I18n.lang === 'ar' && l.name_ar ? l.name_ar : l.name_en);
  const lineLabel = (l) => (I18n.lang === 'ar' && l.label_ar ? l.label_ar : l.label_en) || '';

  // Same rules as the SQL function normalize_phone() (shared with the staff screens, see db.js).
  const normalizePhone = (raw) => DB.normalizePhone(raw);

  // ---------- cart page ----------
  async function initCart() {
    await Shop.boot();
    Shop.setTitle(t('cart.title'));
    const box = $('#cart');
    const notes = $('#cart-notes');
    try {
      const { changes } = await Cart.refresh();
      notes.innerHTML = changes.map((c) => `<div class="alert alert-warn">${esc(t('cart.change_' + c.kind, { name: lineName(c.line) }))}</div>`).join('');
    } catch (ex) {
      console.error(ex);
      notes.innerHTML = `<div class="alert alert-warn">${esc(t('cart.offline'))}</div>`;
    }
    render();
    window.addEventListener('cart:change', render);

    function render() {
      const lines = Cart.items();
      if (!lines.length) {
        box.innerHTML = `<div class="empty"><p>${esc(t('cart.empty'))}</p><a class="btn btn-primary" href="index.html">${esc(t('shop.back_home'))}</a></div>`;
        return;
      }
      const ok = lines.filter((l) => !l.unavailable);
      const subtotal = ok.reduce((s, l) => s + l.qty * Number(l.price), 0);
      box.innerHTML = `<div class="cart-lines">${lines.map((l) => `
        <div class="cart-line${l.unavailable ? ' unavailable' : ''}" data-sku="${esc(l.sku)}" data-v="${l.variant_id || ''}">
          <a class="cl-img" href="product.html?sku=${encodeURIComponent(l.sku)}">${Shop.photoImg(l.photo, lineName(l), true)}</a>
          <div class="cl-body">
            <a class="cl-name" href="product.html?sku=${encodeURIComponent(l.sku)}">${esc(lineName(l))}</a>
            ${lineLabel(l) ? `<div class="muted">${esc(lineLabel(l))}</div>` : ''}
            <div class="price">${moneyHtml(l.price)}</div>
            ${l.unavailable ? `<div class="cl-warn">${esc(t('cart.unavailable'))}</div>` : `
            <div class="qty qty-small">
              <button type="button" data-act="minus" aria-label="−">−</button>
              <input type="number" inputmode="numeric" min="1" max="${l.max || 99}" value="${l.qty}" aria-label="${esc(t('shop.qty'))}">
              <button type="button" data-act="plus" aria-label="+">+</button>
            </div>`}
          </div>
          <button type="button" class="cl-remove" data-act="remove" aria-label="${esc(t('cart.remove'))}">✕</button>
        </div>`).join('')}</div>
        <div class="summary">
          <div class="sum-row"><span>${esc(t('cart.subtotal'))}</span><strong>${moneyHtml(subtotal)}</strong></div>
          <p class="muted">${esc(t('cart.delivery_next'))}</p>
          ${ok.length ? `<a class="btn btn-primary btn-block" href="checkout.html">${esc(t('cart.checkout'))}</a>` : ''}
          <a class="btn btn-block" href="index.html" style="margin-top:.5rem">${esc(t('cart.continue'))}</a>
        </div>`;
      box.querySelectorAll('.cart-line').forEach((row) => {
        const sku = row.dataset.sku;
        const v = row.dataset.v ? Number(row.dataset.v) : null;
        const line = lines.find((l) => l.sku === sku && (l.variant_id || null) === v);
        row.querySelectorAll('[data-act]').forEach((b) => b.addEventListener('click', () => {
          if (b.dataset.act === 'remove') Cart.remove(sku, v);
          if (b.dataset.act === 'minus') Cart.setQty(sku, v, line.qty - 1);
          if (b.dataset.act === 'plus') Cart.setQty(sku, v, line.qty + 1);
        }));
        const inp = row.querySelector('input');
        if (inp) inp.addEventListener('change', () => Cart.setQty(sku, v, Number(inp.value)));
      });
    }
  }

  // ---------- checkout page ----------
  const ME_KEY = 'checkout:me';
  function loadMe() { try { return JSON.parse(localStorage.getItem(ME_KEY)) || {}; } catch { return {}; } }
  function saveMe(me) { try { localStorage.setItem(ME_KEY, JSON.stringify(me)); } catch { /* ignore */ } }
  function forgetMe() { try { localStorage.removeItem(ME_KEY); } catch { /* ignore */ } }

  async function initCheckout() {
    await Shop.boot();
    Shop.setTitle(t('co.title'));
    const S = Shop.settings();
    // C1 emergency switch (Settings, default off): areas without a fee can still order,
    // the fee shows as "to be confirmed" and is paid in cash on delivery (12b #2)
    const feeTbc = (S.fee_tbc_enabled || '') === 'on';
    const form = $('#co-form');
    const err = $('#co-error');

    let refreshNote = '';
    try {
      const { changes } = await Cart.refresh();
      if (changes.length) refreshNote = changes.map((c) => t('cart.change_' + c.kind, { name: lineName(c.line) })).join(' ');
    } catch (ex) { console.error(ex); }
    const lines = () => Cart.items().filter((l) => !l.unavailable);
    if (!lines().length) {
      $('#checkout').innerHTML = `<div class="empty"><p>${esc(t('cart.empty'))}</p><a class="btn btn-primary" href="index.html">${esc(t('shop.back_home'))}</a></div>`;
      return;
    }
    if (refreshNote) $('#co-notes').innerHTML = `<div class="alert alert-warn">${esc(refreshNote)} <a href="cart.html">${esc(t('cart.title'))}</a></div>`;

    // items summary
    $('#co-items').innerHTML = lines().map((l) => `<div class="sum-row"><span>${l.qty} × ${esc(lineName(l))}${lineLabel(l) ? ' · ' + esc(lineLabel(l)) : ''}</span><span>${moneyHtml(l.qty * l.price)}</span></div>`).join('');

    // delivery zones
    const { data: zones, error: zErr } = await DB.client.from('delivery_zones')
      .select('id,governorate,governorate_ar,district,district_ar,fee,eta_days').eq('active', true).order('sort');
    if (zErr) { err.textContent = t('common.error_generic'); err.hidden = false; return; }
    const govs = [...new Map(zones.map((z) => [z.governorate, z])).values()];
    const govSel = form.governorate;
    const disSel = form.district;
    const label = (z, f) => (I18n.lang === 'ar' && z[f + '_ar'] ? z[f + '_ar'] : z[f]);
    govSel.innerHTML = `<option value="">${esc(t('co.choose'))}</option>` + govs.map((z) => `<option value="${esc(z.governorate)}">${esc(label(z, 'governorate'))}</option>`).join('');
    function fillDistricts() {
      const list = zones.filter((z) => z.governorate === govSel.value);
      disSel.innerHTML = `<option value="">${esc(t('co.choose'))}</option>` + list.map((z) => `<option value="${z.id}">${esc(label(z, 'district'))}</option>`).join('');
      disSel.disabled = !list.length;
      if (list.length === 1) disSel.value = list[0].id; // Beirut, Akkar...: only one district
    }
    govSel.addEventListener('change', () => { fillDistricts(); updateTotals(); });
    disSel.addEventListener('change', updateTotals);

    // payment methods: Whish / OMT only offered once their details are set in settings
    const methods = [{ code: 'COD', info: Shop.businessText('cod_checkout', 'co.cod_info') }];
    if ((S.whish_number || '').trim()) methods.push({ code: 'WHISH', info: Shop.businessText('whish_checkout', 'co.whish_info', { number: S.whish_number.trim() }) });
    if ((S.omt_details || '').trim()) methods.push({ code: 'OMT', info: Shop.businessText('omt_checkout', 'co.omt_info', { details: S.omt_details.trim() }) });
    const hours = parseInt(S.unpaid_cancel_hours, 10);
    $('#co-payments').innerHTML = methods.map((m, i) => `
      <label class="pay-opt"><input type="radio" name="payment" value="${m.code}" ${i === 0 ? 'checked' : ''}>
        <span><strong>${esc(t('co.pay_' + m.code))}</strong>
        <span class="pay-info" dir="auto">${esc(m.info)}${m.code !== 'COD' && hours > 0 ? ' ' + esc(Shop.businessText('pay_deadline', 'co.pay_within', { hours })) : ''}</span></span>
      </label>`).join('');
    const deliveryNote = Shop.optionalBusinessText('delivery_payment');
    if (deliveryNote) { $('#co-business-note').textContent = deliveryNote; $('#co-business-note').hidden = false; }
    const checkoutNote = Shop.optionalBusinessText('checkout_note');
    if (checkoutNote) { $('#co-checkout-note').textContent = checkoutNote; $('#co-checkout-note').hidden = false; }

    // prefill from last time
    const me = loadMe();
    if (me.name) {
      ['name', 'phone', 'town', 'building', 'floor', 'street', 'landmark'].forEach((k) => { if (me[k]) form[k].value = me[k]; });
      const z = zones.find((x) => x.id === me.zone_id);
      if (z) { govSel.value = z.governorate; fillDistricts(); disSel.value = z.id; }
    } else {
      disSel.disabled = true;
    }

    // live phone feedback
    const phoneHint = $('#co-phone-hint');
    function checkPhone() {
      const n = normalizePhone(form.phone.value);
      if (!form.phone.value.trim()) { phoneHint.textContent = t('co.phone_hint'); phoneHint.className = 'hint'; return null; }
      if (n) { phoneHint.textContent = '✓ ' + n; phoneHint.className = 'hint ok'; } else { phoneHint.textContent = t('co.phone_bad'); phoneHint.className = 'hint bad'; }
      return n;
    }
    form.phone.addEventListener('input', checkPhone);
    checkPhone();

    function zone() { return zones.find((z) => z.id === Number(disSel.value)); }
    function updateTotals() {
      const subtotal = lines().reduce((s, l) => s + l.qty * Number(l.price), 0);
      const z = zone();
      const feeRow = $('#co-fee');
      const submit = $('#co-submit');
      let fee = null;
      if (!z) {
        feeRow.innerHTML = `<span>${esc(t('co.delivery'))}</span><span class="muted">${esc(t('co.choose_area'))}</span>`;
      } else if (z.fee == null && feeTbc) {
        fee = 0;
        feeRow.innerHTML = `<span>${esc(t('co.delivery'))}</span><span class="muted">${esc(t('co.fee_tbc'))}</span>`;
      } else if (z.fee == null) {
        feeRow.innerHTML = `<span>${esc(t('co.delivery'))}</span><span class="bad">${esc(t('co.no_delivery'))}</span>`;
      } else {
        fee = Number(z.fee);
        const eta = z.eta_days ? ` <span class="muted">(${esc(t('co.eta', { days: z.eta_days }))})</span>` : '';
        feeRow.innerHTML = `<span>${esc(t('co.delivery'))}${eta}</span><span>${fee === 0 ? esc(t('co.free')) : moneyHtml(fee)}</span>`;
      }
      $('#co-subtotal').innerHTML = moneyHtml(subtotal);
      $('#co-total').innerHTML = fee == null ? '—' : moneyHtml(subtotal + fee);
      $('#co-fee-note').hidden = !(z && z.fee == null && feeTbc);
      submit.disabled = !!z && z.fee == null && !feeTbc;
    }
    updateTotals();

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      err.hidden = true;
      const phone = checkPhone();
      const z = zone();
      const need = [];
      if (!form.name.value.trim()) need.push('name');
      if (!phone) need.push('phone');
      if (!z) need.push(govSel.value ? 'district' : 'governorate');
      if (!form.town.value.trim()) need.push('town');
      if (!form.building.value.trim()) need.push('building');
      const loc = form.location_url.value.trim();
      if (loc && !/^https?:\/\/\S+$/i.test(loc)) need.push('location_url');
      form.querySelectorAll('[aria-invalid]').forEach((el) => el.removeAttribute('aria-invalid'));
      if (need.length) {
        need.forEach((n) => form[n] && form[n].setAttribute('aria-invalid', 'true'));
        err.textContent = t('co.fix_fields', { fields: need.map((n) => t('co.f_' + n)).join(I18n.lang === 'ar' ? '، ' : ', ') });
        err.hidden = false;
        form[need[0]] && form[need[0]].focus();
        return;
      }
      if (z.fee == null && !feeTbc) { err.textContent = t('co.no_delivery'); err.hidden = false; return; }

      const address = [
        form.building.value.trim() && 'Bldg: ' + form.building.value.trim(),
        form.floor.value.trim() && 'Floor: ' + form.floor.value.trim(),
        form.street.value.trim(),
      ].filter(Boolean).join(' · ');
      const payload = {
        p_customer: {
          name: form.name.value.trim(), phone, zone_id: z.id, town: form.town.value.trim(), address,
          landmark: form.landmark.value.trim(), location_url: loc,
          lang: I18n.lang, // the WhatsApp status updates go out in this language
        },
        p_items: lines().map((l) => ({ sku: l.sku, variant_id: l.variant_id || null, qty: l.qty })),
        p_payment: form.payment.value,
        p_honeypot: form.website.value,
      };

      const btn = $('#co-submit');
      btn.disabled = true;
      btn.textContent = t('co.placing');
      const { data, error } = await DB.client.rpc('place_order', payload);
      btn.disabled = false;
      btn.textContent = t('co.place_order');
      if (error) {
        const m = (error.message || '') + ' ' + (error.details || '');
        const code = (/[A-Z_]{6,}/.exec(error.message || '') || [''])[0];
        if (code === 'OUT_OF_STOCK' || code === 'ITEM_UNAVAILABLE') {
          await Cart.refresh().catch(() => {});
          err.innerHTML = `${esc(t('co.err_stock'))} <a href="cart.html">${esc(t('cart.title'))}</a>`;
        } else {
          err.textContent = t('co.err_' + code) !== 'co.err_' + code ? t('co.err_' + code) : t('common.error_generic');
        }
        err.hidden = false;
        console.warn('place_order failed:', m);
        err.scrollIntoView({ block: 'center' });
        return;
      }
      if (form.remember.checked) {
        saveMe({ name: form.name.value.trim(), phone: form.phone.value.trim(), zone_id: z.id, town: form.town.value.trim(),
          building: form.building.value.trim(), floor: form.floor.value.trim(), street: form.street.value.trim(), landmark: form.landmark.value.trim() });
      } else {
        forgetMe();
      }
      try { sessionStorage.setItem('lastOrder', JSON.stringify(data)); } catch { /* order page falls back */ }
      Cart.clear();
      location.href = 'order.html?no=' + encodeURIComponent(data.order_no);
    });
  }

  // ---------- confirmation page ----------
  async function initOrder() {
    await Shop.boot();
    const no = new URLSearchParams(location.search).get('no') || '';
    Shop.setTitle(t('ord.title'));
    let o = null;
    try { o = JSON.parse(sessionStorage.getItem('lastOrder')); } catch { o = null; }
    if (o && o.order_no !== no) o = null;
    const box = $('#order');
    const wa = Shop.waLink(Shop.businessText('whatsapp_order', 'ord.wa_msg', { no }));
    const waBtn = wa ? `<a class="btn btn-wa btn-block" href="${esc(wa)}" target="_blank" rel="noopener">${esc(t('ord.contact_whatsapp'))}</a>` : '';
    if (!no) { location.replace('index.html'); return; }

    let pay = '';
    if (o) {
      const hours = o.unpaid_cancel_hours ? ' ' + Shop.businessText('pay_deadline', 'co.pay_within', { hours: o.unpaid_cancel_hours }) : '';
      if (o.payment_method === 'COD') pay = `<p dir="auto">${esc(Shop.businessText('cod_confirm', 'ord.pay_cod', { total: Shop.money(o.total) }))}</p>`;
      if (o.payment_method === 'WHISH') pay = `<p dir="auto">${esc(Shop.businessText('whish_confirm', 'ord.pay_whish', { total: Shop.money(o.total), number: o.whish_number || '', no }))}${esc(hours)}</p>`;
      if (o.payment_method === 'OMT') pay = `<p dir="auto">${esc(Shop.businessText('omt_confirm', 'ord.pay_omt', { total: Shop.money(o.total), no }))}</p><p class="pay-info" dir="auto">${esc(o.omt_details || '')}</p><p>${esc(hours.trim())}</p>`;
    }
    const itemName = (i) => (I18n.lang === 'ar' && i.name_ar ? i.name_ar : i.name_en) + ((I18n.lang === 'ar' && i.label_ar) || i.label ? ' · ' + ((I18n.lang === 'ar' && i.label_ar) || i.label) : '');
    box.innerHTML = `
      <div class="ord-head">
        <div class="ord-check" aria-hidden="true">✓</div>
        <h1>${esc(t('ord.thanks'))}</h1>
        <p class="muted">${esc(t('ord.your_number'))}</p>
        ${Shop.optionalBusinessText('order_confirmation') ? `<p class="muted" dir="auto">${esc(Shop.optionalBusinessText('order_confirmation'))}</p>` : ''}
        <div class="ord-no" dir="ltr">${esc(no)}</div>
        <p class="muted">${esc(t('ord.keep_number'))}</p>
      </div>
      ${o ? `
      <section class="co-box">
        <h2>${esc(t('ord.payment'))}</h2>
        ${pay}
      </section>
      <section class="co-box">
        <h2>${esc(t('co.summary'))}</h2>
        ${(o.items || []).map((i) => `<div class="sum-row"><span>${i.qty} × ${esc(itemName(i))}</span><span>${moneyHtml(i.line_total)}</span></div>`).join('')}
        <div class="sum-row sep"><span>${esc(t('cart.subtotal'))}</span><span>${moneyHtml(o.subtotal)}</span></div>
        <div class="sum-row"><span>${esc(t('co.delivery'))}${o.eta_days ? ` <span class="muted">(${esc(t('co.eta', { days: o.eta_days }))})</span>` : ''}</span><span>${o.fee_to_confirm ? esc(t('co.fee_tbc')) : Number(o.delivery_fee) === 0 ? esc(t('co.free')) : moneyHtml(o.delivery_fee)}</span></div>
        <div class="sum-row total"><span>${esc(t('co.total'))}</span><strong>${moneyHtml(o.total)}</strong></div>
        ${o.fee_to_confirm ? `<p class="hint">${esc(t('co.fee_tbc_note'))}</p>` : ''}
      </section>
      <p>${esc(t('ord.next_steps'))}</p>` : `<p>${esc(t('ord.no_details'))}</p>`}
      <div class="buy"><a class="btn btn-primary btn-block" href="track.html?no=${encodeURIComponent(no)}">${esc(t('trk.title'))}</a>${waBtn}<a class="btn btn-block" href="index.html">${esc(t('cart.continue'))}</a></div>`;
  }

  // ---------- track order page ----------
  async function initTrack() {
    await Shop.boot();
    Shop.setTitle(t('trk.title'));
    const form = $('#trk-form');
    const out = $('#trk-result');
    const params = new URLSearchParams(location.search);
    if (params.get('no')) form.no.value = params.get('no');
    const me = loadMe();
    if (me.phone) form.phone.value = me.phone;

    const STEPS = ['NEW', 'CONFIRMED', 'PACKED', 'ON_THE_WAY', 'DELIVERED'];
    const stepOf = (s) => (s === 'OUT_FOR_DELIVERY' || s === 'WITH_COMPANY' ? 'ON_THE_WAY' : s);
    const fmt = (iso) => new Date(iso).toLocaleString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB',
      { day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' });

    async function run() {
      const no = form.no.value.trim();
      const phone = normalizePhone(form.phone.value);
      if (!no || !phone) {
        out.innerHTML = `<div class="alert alert-error">${esc(t(!no ? 'trk.need_no' : 'co.phone_bad'))}</div>`;
        return;
      }
      const btn = form.querySelector('button[type=submit]');
      btn.disabled = true;
      const { data, error } = await DB.client.rpc('track_order', { p_order_no: no, p_phone: phone });
      btn.disabled = false;
      if (error) { out.innerHTML = `<div class="alert alert-error">${esc(t('common.error_generic'))}</div>`; return; }
      if (!data) { out.innerHTML = `<div class="alert alert-warn">${esc(t('trk.not_found'))}</div>`; return; }
      const cur = stepOf(data.status);
      const special = ['CANCELLED', 'RETURNED', 'FAILED_ATTEMPT'].includes(data.status);
      const idx = STEPS.indexOf(cur);
      const wa = Shop.waLink(Shop.businessText('whatsapp_order', 'ord.wa_msg', { no: data.order_no }));
      out.innerHTML = `<section class="co-box trk-card">
          <p class="muted">${esc(t('ord.your_number'))} <strong dir="ltr">${esc(data.order_no)}</strong></p>
          <h2 class="trk-status">${esc(t('status.' + data.status))}</h2>
          ${data.payment_received ? `<p class="trk-paid">${esc(t('trk.payment_received'))}</p>` : ''}
          ${special ? `<div class="alert alert-warn">${esc(t('trk.note_' + data.status))}</div>` : `
          <ol class="trk-steps">${STEPS.map((s, i) => `<li class="${i < idx ? 'done' : i === idx ? 'now' : ''}">
            <span class="dot" aria-hidden="true">${i < idx ? '✓' : ''}</span>
            <span>${esc(s === 'ON_THE_WAY' ? t('trk.on_the_way') : t('status.' + s))}</span></li>`).join('')}</ol>`}
          <p class="muted">${esc(t('trk.placed', { date: fmt(data.created_at) }))}<br>${esc(t('trk.updated', { date: fmt(data.updated_at) }))}</p>
          ${wa ? `<a class="btn btn-wa btn-block" href="${esc(wa)}" target="_blank" rel="noopener">${esc(t('ord.contact_whatsapp'))}</a>` : ''}
        </section>`;
    }
    form.addEventListener('submit', (e) => { e.preventDefault(); run(); });
    if (form.no.value && form.phone.value) run();
  }

  window.Checkout = { initCart, initCheckout, initOrder, initTrack, normalizePhone };
})();
