// Admin Settings (Phase 1c): every business setting + delivery areas, editable by ADMIN
// (Mika, Charbel); OWNER sees them read-only. Settings are saved through admin_save_settings
// (validates every value, one transaction). Delivery areas are edited directly in
// delivery_zones (RLS: ADMIN only; the database checks fees, carriers and names).
(async function () {
  const me = await StaffAuth.require(['ADMIN', 'OWNER']);
  const canEdit = me.role === 'ADMIN';
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);

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
    toastTimer = setTimeout(() => { el.hidden = true; }, isError ? 6000 : 3000);
  }
  function errText(error) {
    if (error && error.code === '42501') return t('admin.err_permission');
    const code = (/[A-Z_]{6,}/.exec((error && error.message) || '') || [''])[0];
    const k = 'set.err_' + code;
    return t(k) !== k ? t(k) : t('common.error_generic') + ' (' + ((error && error.message) || '') + ')';
  }
  if (!canEdit) $('#set-readonly').hidden = false;

  // ---------- tabs ----------
  const tabs = document.querySelectorAll('[data-stab]');
  function showTab(name) {
    tabs.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.stab === name)));
    $('#set-form').hidden = name !== 'shop';
    $('#zones').hidden = name !== 'delivery';
    try { sessionStorage.setItem('settings:tab', name); } catch { /* ignore */ }
  }
  tabs.forEach((b) => b.addEventListener('click', () => showTab(b.dataset.stab)));
  let startTab = 'shop';
  try { startTab = sessionStorage.getItem('settings:tab') || (location.hash === '#delivery' ? 'delivery' : 'shop'); } catch { /* ignore */ }

  // ================= SHOP SETTINGS =================
  // Every business setting the screen shows. Technical keys (order_alert_url) are left out.
  const GROUPS = [
    { id: 'shop', fields: [
      { key: 'shop_name_en' }, { key: 'shop_name_ar', dir: 'rtl' }, { key: 'currency', dir: 'ltr', max: 10 }] },
    { id: 'contact', fields: [{ key: 'whatsapp_number', type: 'tel', dir: 'ltr' }] },
    { id: 'pay', fields: [
      { key: 'whish_number', dir: 'ltr' }, { key: 'omt_details', area: true, dir: 'auto' },
      { key: 'unpaid_cancel_hours', type: 'number' }] },
    { id: 'orders', fields: [{ key: 'order_prefix', dir: 'ltr', max: 6 }, { key: 'low_stock_threshold', type: 'number' }] },
    { id: 'policies', fields: [
      { key: 'return_policy_en', area: true }, { key: 'return_policy_ar', area: true, dir: 'rtl' },
      { key: 'privacy_en', area: true }, { key: 'privacy_ar', area: true, dir: 'rtl' }] },
  ];
  const ALL_KEYS = GROUPS.flatMap((g) => g.fields.map((f) => f.key));
  let saved = {};

  async function loadSettings() {
    const { data, error } = await DB.client.from('settings').select('key,value').in('key', ALL_KEYS);
    if (error) { $('#set-groups').innerHTML = `<div class="alert alert-error">${esc(errText(error))}</div>`; return; }
    saved = Object.fromEntries(data.map((r) => [r.key, r.value || '']));
    renderSettings();
  }

  function renderSettings() {
    $('#set-groups').innerHTML = GROUPS.map((g) => `
      <fieldset><legend>${esc(t('set.g_' + g.id))}</legend>
        ${g.fields.map((f) => {
          const id = 'set-' + f.key;
          const attrs = `id="${id}" name="${f.key}" ${f.dir ? `dir="${f.dir}"` : ''} ${f.max ? `maxlength="${f.max}"` : ''} ${canEdit ? '' : 'readonly'}`;
          const input = f.area
            ? `<textarea ${attrs} maxlength="5000">${esc(saved[f.key])}</textarea>`
            : `<input ${attrs} type="${f.type === 'number' ? 'text' : f.type || 'text'}" ${f.type === 'number' ? 'inputmode="numeric"' : ''} value="${esc(saved[f.key])}">`;
          const empty = !(saved[f.key] || '').trim();
          return `<div class="field">
            <label for="${id}">${esc(t('set.f_' + f.key))} ${empty ? `<span class="pill pill-warn">${esc(t('set.empty'))}</span>` : ''}</label>
            ${input}
            <p class="hint">${esc(t('set.h_' + f.key))}</p></div>`;
        }).join('')}
      </fieldset>`).join('');
    $('#set-save').hidden = !canEdit;
    $('#set-groups').querySelectorAll('input, textarea').forEach((el) => el.addEventListener('input', markDirty));
    markDirty();
  }

  function changes() {
    const out = {};
    ALL_KEYS.forEach((k) => {
      const el = $('#set-' + k);
      if (el && el.value.trim() !== (saved[k] || '').trim()) out[k] = el.value.trim();
    });
    return out;
  }
  function markDirty() {
    const n = Object.keys(changes()).length;
    const btn = $('#set-save');
    btn.disabled = n === 0;
    btn.textContent = n ? t('set.save_n', { n }) : t('set.saved_all');
  }
  window.addEventListener('beforeunload', (e) => {
    if (canEdit && Object.keys(changes()).length) { e.preventDefault(); e.returnValue = ''; }
  });

  $('#set-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!canEdit) return;
    const err = $('#set-error');
    err.hidden = true;
    $('#set-groups').querySelectorAll('[aria-invalid]').forEach((el) => el.removeAttribute('aria-invalid'));
    const values = changes();
    if (!Object.keys(values).length) return;
    const btn = $('#set-save');
    btn.disabled = true;
    btn.textContent = t('common.saving');
    const { error } = await DB.client.rpc('admin_save_settings', { p_values: values });
    if (error) {
      const field = error.details && $('#set-' + error.details);
      err.textContent = errText(error) + (field ? ' (' + t('set.f_' + error.details) + ')' : '');
      err.hidden = false;
      if (field) { field.setAttribute('aria-invalid', 'true'); field.focus(); }
      markDirty();
      return;
    }
    toast(t('set.saved'));
    await loadSettings();
  });

  // ================= DELIVERY AREAS =================
  let zones = [];
  const zDirty = new Map(); // id -> changed fields
  async function loadZones() {
    const { data, error } = await DB.client.from('delivery_zones')
      .select('id,governorate,governorate_ar,district,district_ar,fee,eta_days,default_carrier,active,sort')
      .order('sort').order('district');
    if (error) { $('#z-list').innerHTML = `<div class="alert alert-error">${esc(errText(error))}</div>`; return; }
    zones = data;
    zDirty.clear();
    $('#za-govs').innerHTML = [...new Set(zones.map((z) => z.governorate))].map((g) => `<option value="${esc(g)}">`).join('');
    $('#z-add-box').hidden = !canEdit;
    renderZones();
  }

  const govName = (z) => (I18n.lang === 'ar' && z.governorate_ar ? z.governorate_ar : z.governorate);
  const disName = (z) => (I18n.lang === 'ar' && z.district_ar ? z.district_ar : z.district);

  function renderZones() {
    const q = $('#z-search').value.trim().toLowerCase();
    const filter = $('#z-filter').value;
    const list = zones.filter((z) => (!q || [z.governorate, z.governorate_ar, z.district, z.district_ar].join(' ').toLowerCase().includes(q))
      && (filter !== 'nofee' || z.fee == null) && (filter !== 'off' || !z.active));
    const noFee = zones.filter((z) => z.active && z.fee == null).length;
    $('#z-count').innerHTML = esc(t('set.zones_count', { n: zones.length })) + (noFee ? ` · <span class="bad">${esc(t('set.zones_nofee_n', { n: noFee }))}</span>` : '');
    const govs = [...new Map(list.map((z) => [z.governorate, z])).values()];
    $('#z-list').innerHTML = govs.length ? govs.map((g) => `
      <fieldset class="z-gov" data-gov="${esc(g.governorate)}"><legend>${esc(govName(g))}</legend>
        ${canEdit && list.filter((z) => z.governorate === g.governorate).length > 1 ? `<div class="z-bulk"><label class="hint" for="zb-${g.id}">${esc(t('set.zone_same_fee'))}</label>
          <div class="input-with-btn"><input id="zb-${g.id}" type="text" inputmode="decimal" dir="ltr" placeholder="0.00">
          <button type="button" class="btn btn-small" data-bulk="${g.id}">${esc(t('set.zone_apply'))}</button></div></div>` : ''}
        ${list.filter((z) => z.governorate === g.governorate).map(zoneRow).join('')}
      </fieldset>`).join('') : `<p class="empty">${esc(t('set.zones_none'))}</p>`;
    wireZones();
  }

  function zoneRow(z) {
    const d = { ...z, ...(zDirty.get(z.id) || {}) };
    const dis = canEdit ? '' : 'disabled';
    return `<div class="z-row${d.active ? '' : ' off'}${zDirty.has(z.id) ? ' dirty' : ''}" data-id="${z.id}">
      <div class="z-name"><strong>${esc(disName(d))}</strong>${d.district_ar && I18n.lang !== 'ar' ? ` <span class="hint" dir="rtl" lang="ar">${esc(d.district_ar)}</span>` : ''}
        ${d.fee == null ? `<span class="pill pill-danger">${esc(t('set.no_fee'))}</span>` : ''}${d.active ? '' : ` <span class="pill pill-off">${esc(t('set.zone_hidden'))}</span>`}</div>
      <div class="z-fields">
        <label>${esc(t('set.zone_fee'))}<input type="text" inputmode="decimal" dir="ltr" data-f="fee" value="${d.fee == null ? '' : esc(d.fee)}" placeholder="—" ${dis}></label>
        <label>${esc(t('set.zone_eta'))}<input type="text" dir="ltr" data-f="eta_days" maxlength="10" value="${esc(d.eta_days || '')}" placeholder="1-2" ${dis}></label>
        <label>${esc(t('set.zone_carrier'))}<select data-f="default_carrier" ${dis}>
          <option value="">—</option>
          <option value="DRIVER" ${d.default_carrier === 'DRIVER' ? 'selected' : ''}>${esc(t('set.carrier_DRIVER'))}</option>
          <option value="COMPANY" ${d.default_carrier === 'COMPANY' ? 'selected' : ''}>${esc(t('set.carrier_COMPANY'))}</option></select></label>
        <label class="check"><input type="checkbox" data-f="active" ${d.active ? 'checked' : ''} ${dis}> ${esc(t('set.zone_active'))}</label>
      </div>
      ${canEdit ? `<details class="z-names"><summary>${esc(t('set.zone_rename'))}</summary>
        <div class="grid-2 stack-sm">
          <label>${esc(t('set.zone_dis'))}<input type="text" data-f="district" maxlength="60" value="${esc(d.district)}"></label>
          <label>${esc(t('set.zone_dis_ar'))}<input type="text" data-f="district_ar" dir="rtl" lang="ar" maxlength="60" value="${esc(d.district_ar)}"></label>
        </div></details>` : ''}
    </div>`;
  }

  // parse "4.5" / "4,50" / "" -> number | null | NaN
  function parseFee(v) {
    const s = String(v).trim().replace(',', '.');
    if (s === '') return null;
    return /^\d{1,6}(\.\d{1,2})?$/.test(s) ? Number(s) : NaN;
  }

  function wireZones() {
    $('#z-list').querySelectorAll('.z-row').forEach((row) => {
      const id = Number(row.dataset.id);
      const orig = zones.find((z) => z.id === id);
      row.querySelectorAll('[data-f]').forEach((el) => el.addEventListener(el.type === 'checkbox' || el.tagName === 'SELECT' ? 'change' : 'input', () => {
        const f = el.dataset.f;
        let v = el.type === 'checkbox' ? el.checked : el.value;
        if (f === 'fee') v = parseFee(v);
        if (f === 'default_carrier') v = v || null;
        if (f === 'eta_days') v = v.trim() || null;
        if (f === 'district' || f === 'district_ar') v = v.trim();
        if (f === 'fee' && Number.isNaN(v)) el.setAttribute('aria-invalid', 'true'); else el.removeAttribute('aria-invalid');
        const ch = { ...(zDirty.get(id) || {}) };
        if (v === orig[f] || (f === 'fee' && v != null && orig.fee != null && Number(orig.fee) === v)) delete ch[f]; else ch[f] = v;
        if (Object.keys(ch).length) zDirty.set(id, ch); else zDirty.delete(id);
        row.classList.toggle('dirty', zDirty.has(id));
        updateZoneSave();
      }));
    });
    $('#z-list').querySelectorAll('[data-bulk]').forEach((b) => b.addEventListener('click', () => {
      const box = b.closest('.z-gov');
      const fee = parseFee($('input', b.parentElement).value);
      if (fee == null || Number.isNaN(fee)) { toast(t('set.err_fee'), true); return; }
      box.querySelectorAll('.z-row [data-f=fee]').forEach((inp) => { inp.value = fee; inp.dispatchEvent(new Event('input')); });
    }));
    updateZoneSave();
  }

  // floating "Save N changes" bar for the delivery tab
  const bar = document.createElement('div');
  bar.className = 'z-savebar';
  bar.hidden = true;
  bar.innerHTML = `<button type="button" class="btn btn-ghost" id="z-undo"></button><button type="button" class="btn btn-primary" id="z-save"></button>`;
  document.body.appendChild(bar);
  function updateZoneSave() {
    const n = zDirty.size;
    bar.hidden = !canEdit || n === 0 || $('#zones').hidden;
    $('#z-save').textContent = t('set.save_n', { n });
    $('#z-undo').textContent = t('set.undo');
  }
  tabs.forEach((b) => b.addEventListener('click', updateZoneSave));
  $('#z-undo').addEventListener('click', () => { zDirty.clear(); renderZones(); });
  $('#z-save').addEventListener('click', async () => {
    const bad = [...zDirty.values()].some((c) => Number.isNaN(c.fee) || c.district === '');
    if (bad) { toast(t('set.err_fee'), true); return; }
    $('#z-save').disabled = true;
    const results = await Promise.all([...zDirty.entries()].map(([id, ch]) =>
      DB.client.from('delivery_zones').update(ch).eq('id', id).select('id')));
    $('#z-save').disabled = false;
    const failed = results.filter((r) => r.error || !r.data || !r.data.length);
    if (failed.length) {
      const e = failed[0].error;
      toast(e && e.code === '23505' ? t('set.err_zone_exists') : e && e.code === '23514' ? t('set.err_zone_names') : errText(e || { code: '42501' }), true);
    } else {
      toast(t('set.saved'));
    }
    await loadZones();
  });
  window.addEventListener('beforeunload', (e) => { if (canEdit && zDirty.size) { e.preventDefault(); e.returnValue = ''; } });

  let zt;
  $('#z-search').addEventListener('input', () => { clearTimeout(zt); zt = setTimeout(renderZones, 200); });
  $('#z-filter').addEventListener('change', renderZones);

  // add an area
  $('#za-go').addEventListener('click', async () => {
    const err = $('#za-error');
    err.hidden = true;
    const gov = $('#za-gov').value.trim();
    const dis = $('#za-dis').value.trim();
    if (!gov || !dis) { err.textContent = t('set.err_zone_names'); err.hidden = false; return; }
    const same = zones.filter((z) => z.governorate === gov);
    const govAr = $('#za-gov-ar').value.trim() || (same[0] ? same[0].governorate_ar : '');
    const sort = same.length ? Math.max(...same.map((z) => z.sort)) + 1 : Math.max(0, ...zones.map((z) => z.sort)) + 100;
    const { error } = await DB.client.from('delivery_zones')
      .insert({ governorate: gov, governorate_ar: govAr, district: dis, district_ar: $('#za-dis-ar').value.trim(), sort }).select('id');
    if (error) { err.textContent = error.code === '23505' ? t('set.err_zone_exists') : error.code === '23514' ? t('set.err_zone_names') : errText(error); err.hidden = false; return; }
    ['#za-gov', '#za-gov-ar', '#za-dis', '#za-dis-ar'].forEach((s) => { $(s).value = ''; });
    toast(t('set.zone_added', { name: dis }));
    await loadZones();
  });
  $('#za-gov').addEventListener('change', () => {
    const z = zones.find((x) => x.governorate === $('#za-gov').value.trim());
    if (z && !$('#za-gov-ar').value) $('#za-gov-ar').value = z.governorate_ar;
  });

  // ---------- start ----------
  await Promise.all([loadSettings(), loadZones()]);
  showTab(startTab);
  updateZoneSave();
  window.Settings = { changes, zDirty, parseFee };
})();
