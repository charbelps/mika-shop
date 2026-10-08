// Staff "New order" screen (F7): Mika enters an order she took by phone, Instagram or WhatsApp.
// ADMIN only. The order is created by the database function staff_place_order, which shares
// place_order's core: prices come from the database, stock is locked and taken, the customer
// is saved. Nothing typed here is trusted for prices.
// A draft is kept on this phone (localStorage) so a reload or language switch loses nothing.
(async function () {
  await StaffAuth.require(['ADMIN']);
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);
  const S = await DB.settings().catch(() => ({}));
  const money = (n) => `<bdi>${esc(I18n.money(n, S.currency))}</bdi>`;
  const DRAFT_KEY = 'staff:new-order:draft';
  const FIELDS = ['phone', 'name', 'town', 'building', 'floor', 'street', 'landmark', 'location_url', 'notes', 'lang'];
  const form = $('#no-form');
  // customer's language (WhatsApp status updates are sent in it): starts as the screen's language
  form.lang.querySelector('option[value="' + (I18n.lang === 'ar' ? 'ar' : 'en') + '"]').defaultSelected = true;
  form.lang.value = I18n.lang === 'ar' ? 'ar' : 'en';
  const err = $('#no-error');
  const state = { source: '', lines: [], req: 0 };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  }
  const pickName = (l) => I18n.pick(l, 'name');
  const pickLabel = (l) => (l.label_en ? I18n.pick(l, 'label') : '');

  // ---------- delivery zones ----------
  const { data: zones, error: zErr } = await DB.client.from('delivery_zones')
    .select('id,governorate,governorate_ar,district,district_ar,fee,eta_days').eq('active', true).order('sort');
  if (zErr) { err.textContent = t('common.error_generic'); err.hidden = false; return; }
  const govs = [...new Map(zones.map((z) => [z.governorate, z])).values()];
  const govSel = form.governorate;
  const disSel = form.district;
  const zoneLabel = (z, f) => (I18n.lang === 'ar' && z[f + '_ar'] ? z[f + '_ar'] : z[f]);
  govSel.innerHTML = `<option value="">${esc(t('co.choose'))}</option>` + govs.map((z) => `<option value="${esc(z.governorate)}">${esc(zoneLabel(z, 'governorate'))}</option>`).join('');
  function fillDistricts() {
    const list = zones.filter((z) => z.governorate === govSel.value);
    disSel.innerHTML = `<option value="">${esc(t('co.choose'))}</option>` + list.map((z) => `<option value="${z.id}">${esc(zoneLabel(z, 'district'))}${z.fee == null ? ' — ' + esc(t('no.no_fee')) : ''}</option>`).join('');
    disSel.disabled = !list.length;
    if (list.length === 1) disSel.value = list[0].id;
  }
  function setZone(id) {
    const z = zones.find((x) => x.id === Number(id));
    if (!z) return false;
    govSel.value = z.governorate; fillDistricts(); disSel.value = z.id;
    return true;
  }
  const zone = () => zones.find((z) => z.id === Number(disSel.value));
  govSel.addEventListener('change', () => { fillDistricts(); changed(); });
  disSel.addEventListener('change', changed);
  disSel.disabled = true;

  // ---------- payment methods (same rule as the shop: Whish / OMT once their details are set) ----------
  const methods = ['COD'];
  if ((S.whish_number || '').trim()) methods.push('WHISH');
  if ((S.omt_details || '').trim()) methods.push('OMT');
  $('#no-payments').innerHTML = methods.map((m, i) => `
    <label class="check"><input type="radio" name="payment" value="${m}" ${i === 0 ? 'checked' : ''}> ${esc(t('prep.method_' + m))}</label>`).join('')
    + (methods.length < 3 ? `<p class="hint">${esc(t('no.pay_missing'))}</p>` : '');
  form.querySelectorAll('[name=payment]').forEach((r) => r.addEventListener('change', changed));

  // ---------- source ----------
  const sourceBtns = [...document.querySelectorAll('[data-source]')];
  function setSource(s) {
    state.source = s || '';
    sourceBtns.forEach((b) => { const on = b.dataset.source === state.source; b.setAttribute('aria-pressed', String(on)); b.setAttribute('aria-checked', String(on)); });
  }
  sourceBtns.forEach((b) => b.addEventListener('click', () => { setSource(b.dataset.source); changed(); }));

  // ---------- product search ----------
  const results = $('#no-results');
  let st;
  $('#no-search').addEventListener('input', (e) => { clearTimeout(st); st = setTimeout(() => search(e.target.value), 300); });
  $('#no-search').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); clearTimeout(st); search(e.target.value); } });

  async function search(raw) {
    const reqId = ++state.req;
    const s = String(raw || '').replace(/[",()\\*%]/g, ' ').trim();
    if (s.length < 2) { results.innerHTML = ''; return; }
    const { data, error } = await DB.client.from('products')
      .select('sku,name_en,name_ar,price,stock,has_variants,photos,variants(id,label_en,label_ar,price,stock,active,sort)')
      .eq('active', true)
      .or(`name_en.ilike."*${s}*",name_ar.ilike."*${s}*",sku.ilike."*${s}*",search_keywords.ilike."*${s}*"`)
      .order('name_en').limit(12);
    if (reqId !== state.req) return;
    if (error) { results.innerHTML = `<div class="alert alert-error">${esc(t('common.error_generic'))}</div>`; return; }
    if (!data.length) { results.innerHTML = `<p class="hint">${esc(t('no.no_results'))}</p>`; return; }
    results.innerHTML = '';
    data.forEach((p) => results.appendChild(resultRow(p)));
  }

  function resultRow(p) {
    const wrap = document.createElement('div');
    wrap.className = 'no-result';
    const variants = (p.variants || []).filter((v) => v.active).sort((a, b) => a.sort - b.sort || a.id - b.id);
    const stock = p.has_variants ? variants.reduce((n, v) => n + v.stock, 0) : p.stock;
    const thumb = p.photos && p.photos[0] ? `<img class="thumb" src="${esc(DB.thumbUrl(p.photos[0]))}" alt="" loading="lazy">` : '<div class="thumb"></div>';
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'row-item';
    b.disabled = stock <= 0;
    b.innerHTML = `${thumb}<div class="body"><div class="title">${esc(pickName(p))}</div>
      <div class="meta"><span dir="ltr">${esc(p.sku)}</span> · ${stock > 0 ? esc(t('no.in_stock', { n: stock })) : `<span class="bad">${esc(t('no.sold_out'))}</span>`}</div></div>
      <div class="end"><strong>${money(p.price)}</strong><div class="meta">${p.has_variants ? esc(t('no.options')) : '＋'}</div></div>`;
    wrap.appendChild(b);
    if (p.has_variants) {
      const opts = document.createElement('div');
      opts.className = 'no-opts';
      opts.hidden = true;
      opts.innerHTML = variants.length ? variants.map((v) => `<button type="button" class="chip-btn" data-v="${v.id}" ${v.stock > 0 ? '' : 'disabled'}>
          ${esc(I18n.pick(v, 'label'))} · ${money(v.price != null ? v.price : p.price)}${v.stock > 0 ? '' : ' · ' + esc(t('no.sold_out'))}</button>`).join('')
        : `<p class="hint">${esc(t('no.sold_out'))}</p>`;
      opts.querySelectorAll('[data-v]').forEach((ob) => ob.addEventListener('click', () => {
        const v = variants.find((x) => x.id === Number(ob.dataset.v));
        addLine(p, v);
      }));
      wrap.appendChild(opts);
      b.addEventListener('click', () => { opts.hidden = !opts.hidden; });
    } else {
      b.addEventListener('click', () => addLine(p, null));
    }
    return wrap;
  }

  // ---------- order lines ----------
  function addLine(p, v) {
    const variantId = v ? v.id : null;
    const max = Math.min(99, v ? v.stock : p.stock);
    const found = state.lines.find((l) => l.sku === p.sku && l.variant_id === variantId);
    if (found) {
      found.qty = Math.min(found.qty + 1, max);
      found.max = max;
    } else {
      if (state.lines.length >= 50) { toast(t('no.err_TOO_MANY_ITEMS'), true); return; }
      state.lines.push({
        sku: p.sku, variant_id: variantId, qty: 1, max,
        name_en: p.name_en, name_ar: p.name_ar,
        label_en: v ? v.label_en : '', label_ar: v ? v.label_ar : '',
        price: Number(v && v.price != null ? v.price : p.price),
      });
    }
    toast(t('no.added', { name: pickName(p) }));
    renderLines();
    changed();
  }

  function renderLines() {
    const box = $('#no-lines');
    if (!state.lines.length) { box.innerHTML = `<p class="hint">${esc(t('no.no_items'))}</p>`; return; }
    box.innerHTML = state.lines.map((l, i) => `
      <div class="no-line" data-i="${i}">
        <div class="body"><div class="title">${esc(pickName(l))}</div>
          <div class="meta">${pickLabel(l) ? esc(pickLabel(l)) + ' · ' : ''}${money(l.price)}</div></div>
        <div class="qty-box">
          <button type="button" class="btn btn-small" data-act="minus" aria-label="−">−</button>
          <input type="number" inputmode="numeric" min="1" max="${l.max}" value="${l.qty}" aria-label="${esc(t('shop.qty'))}">
          <button type="button" class="btn btn-small" data-act="plus" aria-label="+">+</button>
        </div>
        <button type="button" class="btn btn-ghost btn-small" data-act="remove" aria-label="${esc(t('admin.remove'))}">✕</button>
      </div>`).join('');
    box.querySelectorAll('.no-line').forEach((row) => {
      const l = state.lines[Number(row.dataset.i)];
      const set = (q) => { l.qty = Math.max(1, Math.min(l.max || 1, q || 1)); renderLines(); changed(); };
      row.querySelector('[data-act=minus]').addEventListener('click', () => set(l.qty - 1));
      row.querySelector('[data-act=plus]').addEventListener('click', () => set(l.qty + 1));
      row.querySelector('input').addEventListener('change', (e) => set(parseInt(e.target.value, 10)));
      row.querySelector('[data-act=remove]').addEventListener('click', () => { state.lines.splice(Number(row.dataset.i), 1); renderLines(); changed(); });
    });
  }

  // ---------- customer: phone + saved details ----------
  const phoneHint = $('#no-phone-hint');
  const known = $('#no-known');
  let lookupTimer;
  let lookupReq = 0;
  function checkPhone() {
    const raw = form.phone.value.trim();
    const n = DB.normalizePhone(raw);
    if (!raw) { phoneHint.textContent = t('co.phone_hint'); phoneHint.className = 'hint'; }
    else if (n) { phoneHint.textContent = '✓ ' + n; phoneHint.className = 'hint ok'; }
    else { phoneHint.textContent = t('co.phone_bad'); phoneHint.className = 'hint bad'; }
    return n;
  }
  form.phone.addEventListener('input', () => {
    const n = checkPhone();
    known.hidden = true;
    clearTimeout(lookupTimer);
    if (n) lookupTimer = setTimeout(() => lookup(n), 300);
  });

  // "Bldg: X · Floor: Y · street" (how orders save the address) back into the three fields.
  function splitAddress(a) {
    const out = { building: '', floor: '', street: [] };
    String(a || '').split(' · ').forEach((part) => {
      if (/^Bldg: /.test(part)) out.building = part.slice(6);
      else if (/^Floor: /.test(part)) out.floor = part.slice(7);
      else if (part.trim()) out.street.push(part);
    });
    return { building: out.building, floor: out.floor, street: out.street.join(' · ') };
  }

  async function lookup(phone) {
    const reqId = ++lookupReq;
    const { data: c } = await DB.client.from('customers')
      .select('phone,name,governorate,district,town,address,landmark,location_url,orders_count').eq('phone', phone).maybeSingle();
    if (reqId !== lookupReq || !c) return;
    known.innerHTML = `<div>${esc(t('no.known', { name: c.name, n: c.orders_count }))}</div>
      <button type="button" class="btn btn-small" id="no-use-saved">${esc(t('no.use_saved'))}</button>`;
    known.hidden = false;
    $('#no-use-saved').addEventListener('click', () => {
      const z = zones.find((x) => x.governorate === c.governorate && x.district === c.district);
      const a = splitAddress(c.address);
      form.name.value = c.name || '';
      form.town.value = c.town || '';
      form.building.value = a.building;
      form.floor.value = a.floor;
      form.street.value = a.street;
      form.landmark.value = c.landmark || '';
      form.location_url.value = c.location_url || '';
      if (z) setZone(z.id); else { govSel.value = ''; fillDistricts(); }
      known.hidden = true;
      changed();
    });
  }

  // ---------- totals ----------
  function updateTotals() {
    const subtotal = state.lines.reduce((s, l) => s + l.qty * l.price, 0);
    const z = zone();
    let fee = null;
    const feeRow = $('#no-fee');
    if (!z) feeRow.innerHTML = `<span>${esc(t('co.delivery'))}</span><span class="hint" style="margin:0">${esc(t('co.choose_area'))}</span>`;
    else if (z.fee == null) feeRow.innerHTML = `<span>${esc(t('co.delivery'))}</span><span class="bad">${esc(t('no.no_fee'))}</span>`;
    else {
      fee = Number(z.fee);
      feeRow.innerHTML = `<span>${esc(t('co.delivery'))}${z.eta_days ? ` <span class="hint">(${esc(t('co.eta', { days: z.eta_days }))})</span>` : ''}</span><span>${fee === 0 ? esc(t('co.free')) : money(fee)}</span>`;
    }
    $('#no-subtotal').innerHTML = money(subtotal);
    $('#no-total').innerHTML = fee == null ? '—' : money(subtotal + fee);
  }

  // ---------- draft (kept on this phone until the order is created or "Start over") ----------
  function readForm() {
    const d = { source: state.source, lines: state.lines, zone_id: zone() ? zone().id : null, payment: (form.payment && form.payment.value) || 'COD' };
    FIELDS.forEach((k) => { d[k] = form[k].value; });
    return d;
  }
  function saveDraft() { try { localStorage.setItem(DRAFT_KEY, JSON.stringify(readForm())); } catch { /* storage blocked */ } }
  function clearDraft() { try { localStorage.removeItem(DRAFT_KEY); } catch { /* ignore */ } }
  function loadDraft() {
    let d = null;
    try { d = JSON.parse(localStorage.getItem(DRAFT_KEY)); } catch { d = null; }
    if (!d) return;
    setSource(d.source);
    state.lines = Array.isArray(d.lines) ? d.lines : [];
    FIELDS.forEach((k) => { if (d[k] != null) form[k].value = d[k]; });
    if (d.zone_id) setZone(d.zone_id);
    const r = form.querySelector(`[name=payment][value="${d.payment}"]`);
    if (r) r.checked = true;
  }
  function changed() { updateTotals(); saveDraft(); }
  FIELDS.forEach((k) => form[k].addEventListener('input', saveDraft));

  function resetAll() {
    clearDraft();
    form.reset();
    setSource('');
    state.lines = [];
    govSel.value = ''; fillDistricts(); disSel.disabled = true;
    results.innerHTML = '';
    known.hidden = true;
    err.hidden = true;
    form.querySelectorAll('[aria-invalid]').forEach((el) => el.removeAttribute('aria-invalid'));
    renderLines(); checkPhone(); updateTotals();
  }
  $('#no-reset').addEventListener('click', () => {
    if ((state.lines.length || form.phone.value || form.name.value) && !confirm(t('no.start_over_q'))) return;
    resetAll();
    window.scrollTo(0, 0);
  });

  // ---------- create the order ----------
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    err.hidden = true;
    form.querySelectorAll('[aria-invalid]').forEach((el) => el.removeAttribute('aria-invalid'));
    const phone = checkPhone();
    const z = zone();
    const need = [];
    if (!state.source) need.push('source');
    if (!state.lines.length) need.push('items');
    if (!phone) need.push('phone');
    if (!form.name.value.trim()) need.push('name');
    if (!z) need.push(govSel.value ? 'district' : 'governorate');
    if (!form.town.value.trim()) need.push('town');
    if (!form.building.value.trim()) need.push('building');
    const loc = form.location_url.value.trim();
    if (loc && !/^https?:\/\/\S+$/i.test(loc)) need.push('location_url');
    if (need.length) {
      need.forEach((n) => form[n] && form[n].setAttribute && form[n].setAttribute('aria-invalid', 'true'));
      err.textContent = t('co.fix_fields', { fields: need.map((n) => t(n === 'source' ? 'no.source' : n === 'items' ? 'no.items' : 'co.f_' + n)).join(I18n.lang === 'ar' ? '، ' : ', ') });
      err.hidden = false;
      err.scrollIntoView({ block: 'center' });
      return;
    }
    if (z.fee == null) { err.textContent = t('no.err_ZONE_FEE_NOT_SET'); err.hidden = false; return; }

    const address = [
      form.building.value.trim() && 'Bldg: ' + form.building.value.trim(),
      form.floor.value.trim() && 'Floor: ' + form.floor.value.trim(),
      form.street.value.trim(),
    ].filter(Boolean).join(' · ');
    const payload = {
      p_customer: {
        name: form.name.value.trim(), phone, zone_id: z.id, town: form.town.value.trim(), address,
        landmark: form.landmark.value.trim(), location_url: loc, lang: form.lang.value,
      },
      p_items: state.lines.map((l) => ({ sku: l.sku, variant_id: l.variant_id || null, qty: l.qty })),
      p_payment: form.payment.value,
      p_source: state.source,
      p_notes: form.notes.value.trim(),
    };
    const btn = $('#no-submit');
    btn.disabled = true;
    btn.textContent = t('no.creating');
    const { data, error } = await DB.client.rpc('staff_place_order', payload);
    btn.disabled = false;
    btn.textContent = t('no.create');
    if (error) {
      const code = (/[A-Z_]{6,}/.exec(error.message || '') || [''])[0];
      const k = 'no.err_' + code;
      if (error.code === '42501') err.textContent = t('admin.err_permission');
      else if (t(k) !== k) err.textContent = t(k, { sku: error.details || '' });
      else err.textContent = t('common.error_generic') + ' (' + (error.message || '') + ')';
      err.hidden = false;
      err.scrollIntoView({ block: 'center' });
      return;
    }
    clearDraft();
    showDone(data);
  });

  function showDone(o) {
    const done = $('#no-done');
    form.hidden = true;
    done.innerHTML = `
      <div class="ord-check" aria-hidden="true">✓</div>
      <h1>${esc(t('no.done_title'))}</h1>
      <p class="no-done-no" dir="ltr">${esc(o.order_no)}</p>
      <p>${esc(t('co.total'))}: <strong>${money(o.total)}</strong> · ${esc(t('prep.method_' + o.payment_method))}</p>
      <p class="hint">${esc(t('no.done_hint'))}</p>
      <div class="od-actions">
        <a class="btn btn-primary" href="prep.html?open=${encodeURIComponent(o.order_id)}">${esc(t('no.open_order'))}</a>
        <button type="button" class="btn" id="no-another">${esc(t('no.another'))}</button>
      </div>`;
    done.hidden = false;
    window.scrollTo(0, 0);
    $('#no-another').addEventListener('click', () => {
      done.hidden = true;
      form.hidden = false;
      resetAll();
      window.scrollTo(0, 0);
    });
  }

  let toastTimer;
  function toast(msg, isError) {
    let el = $('.toast');
    if (!el) { el = document.createElement('div'); el.className = 'toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg;
    el.classList.toggle('error', !!isError);
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, isError ? 6000 : 2000);
  }

  // ---------- start ----------
  loadDraft();
  renderLines();
  checkPhone();
  updateTotals();
  window.NewOrder = { state, search, splitAddress };
})();
