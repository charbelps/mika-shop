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
    $('#text-form').hidden = name !== 'texts';
    $('#zones').hidden = name !== 'delivery';
    $('#staff').hidden = name !== 'staff';
    if (name === 'staff' && canEdit && !staffLoaded) loadStaff();
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
    { id: 'orders', fields: [{ key: 'order_prefix', dir: 'ltr', max: 6 }, { key: 'low_stock_threshold', type: 'number' },
      { key: 'fee_tbc_enabled', options: ['', 'on'] }, { key: 'delivery_company_name', max: 80 }] },
    { id: 'policies', fields: [
      { key: 'return_policy_en', area: true }, { key: 'return_policy_ar', area: true, dir: 'rtl' },
      { key: 'privacy_en', area: true }, { key: 'privacy_ar', area: true, dir: 'rtl' }] },
  ];
  const ALL_KEYS = GROUPS.flatMap((g) => g.fields.map((f) => f.key));
  let saved = {};
  const TEXT_GROUPS = [
    { id: 'text_intro', fields: ['shop_intro_en', 'shop_intro_ar'] },
    { id: 'text_delivery', fields: ['delivery_payment_en', 'delivery_payment_ar', 'checkout_note_en', 'checkout_note_ar'] },
    { id: 'text_payment', fields: [
      'cod_checkout_en', 'cod_checkout_ar', 'cod_confirm_en', 'cod_confirm_ar',
      'whish_checkout_en', 'whish_checkout_ar', 'whish_confirm_en', 'whish_confirm_ar',
      'omt_checkout_en', 'omt_checkout_ar', 'omt_confirm_en', 'omt_confirm_ar',
      'pay_deadline_en', 'pay_deadline_ar',
    ] },
    { id: 'text_confirmation', fields: ['order_confirmation_en', 'order_confirmation_ar'] },
    { id: 'text_whatsapp', fields: [
      'whatsapp_ask_en', 'whatsapp_ask_ar', 'whatsapp_share_en', 'whatsapp_share_ar',
      'whatsapp_order_en', 'whatsapp_order_ar', 'whatsapp_status_en', 'whatsapp_status_ar',
      'whatsapp_back_en', 'whatsapp_back_ar',
    ] },
    { id: 'text_footer', fields: ['footer_note_en', 'footer_note_ar'] },
  ];
  const ALL_TEXT_KEYS = TEXT_GROUPS.flatMap((g) => g.fields);
  let textSaved = {};

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
          const input = f.options
            ? `<select ${attrs} ${canEdit ? '' : 'disabled'}>${f.options.map((o) => `<option value="${o}" ${(saved[f.key] || '') === o ? 'selected' : ''}>${esc(t('set.opt_' + f.key + '_' + (o || 'off')))}</option>`).join('')}</select>`
            : f.area
            ? `<textarea ${attrs} maxlength="5000">${esc(saved[f.key])}</textarea>`
            : `<input ${attrs} type="${f.type === 'number' ? 'text' : f.type || 'text'}" ${f.type === 'number' ? 'inputmode="numeric"' : ''} value="${esc(saved[f.key])}">`;
          const empty = !f.options && !(saved[f.key] || '').trim();
          return `<div class="field">
            <label for="${id}">${esc(t('set.f_' + f.key))} ${empty ? `<span class="pill pill-warn">${esc(t('set.empty'))}</span>` : ''}</label>
            ${input}
            <p class="hint">${esc(t('set.h_' + f.key))}</p></div>`;
        }).join('')}
      </fieldset>`).join('');
    $('#set-save').hidden = !canEdit;
    $('#set-groups').querySelectorAll('input, textarea, select').forEach((el) => el.addEventListener('input', markDirty));
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
  function textChanges() {
    const out = {};
    ALL_TEXT_KEYS.forEach((k) => {
      const el = $('#text-' + k);
      if (el && el.value.trim() !== (textSaved[k] || '').trim()) out[k] = el.value.trim();
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
    if (canEdit && (Object.keys(changes()).length || Object.keys(textChanges()).length)) { e.preventDefault(); e.returnValue = ''; }
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

  async function loadTexts() {
    const { data, error } = await DB.client.from('settings').select('key,value').in('key', ALL_TEXT_KEYS);
    if (error) {
      $('#text-groups').innerHTML = `<div class="alert alert-error">${esc(errText(error))}</div>`;
      return;
    }
    textSaved = Object.fromEntries(data.map((r) => [r.key, r.value || '']));
    renderTexts();
  }

  function renderTexts() {
    $('#text-groups').innerHTML = TEXT_GROUPS.map((g) => `
      <fieldset><legend>${esc(t('set.g_' + g.id))}</legend>
        ${g.fields.map((key) => {
          const id = 'text-' + key;
          const isArabic = key.endsWith('_ar');
          const empty = !(textSaved[key] || '').trim();
          return `<div class="field">
            <label for="${id}">${esc(t('set.f_' + key))} ${empty ? `<span class="pill pill-warn">${esc(t('set.empty'))}</span>` : ''}</label>
            <textarea id="${id}" name="${key}" maxlength="5000" ${isArabic ? 'dir="rtl" lang="ar"' : 'dir="auto"'} ${canEdit ? '' : 'readonly'}>${esc(textSaved[key])}</textarea>
            <p class="hint">${esc(t('set.h_' + key))}</p>
          </div>`;
        }).join('')}
      </fieldset>`).join('');
    $('#text-save').hidden = !canEdit;
    $('#text-groups').querySelectorAll('textarea').forEach((el) => el.addEventListener('input', markTextDirty));
    markTextDirty();
  }

  function markTextDirty() {
    const n = Object.keys(textChanges()).length;
    const btn = $('#text-save');
    btn.disabled = n === 0;
    btn.textContent = n ? t('set.save_n', { n }) : t('set.saved_all');
  }

  $('#text-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!canEdit) return;
    const err = $('#text-error');
    err.hidden = true;
    $('#text-groups').querySelectorAll('[aria-invalid]').forEach((el) => el.removeAttribute('aria-invalid'));
    const values = textChanges();
    if (!Object.keys(values).length) return;
    const btn = $('#text-save');
    btn.disabled = true;
    btn.textContent = t('common.saving');
    const { error } = await DB.client.rpc('admin_save_settings', { p_values: values });
    if (error) {
      const field = error.details && $('#text-' + error.details);
      err.textContent = errText(error) + (field ? ' (' + t('set.f_' + error.details) + ')' : '');
      err.hidden = false;
      if (field) { field.setAttribute('aria-invalid', 'true'); field.focus(); }
      markTextDirty();
      return;
    }
    toast(t('set.saved'));
    await loadTexts();
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

  // ================= STAFF (ADMIN only) =================
  // Logins can only be created / changed with Supabase's secret key, so every action goes
  // through the Edge Function staff-admin, which checks again that the caller is an ADMIN.
  let staffLoaded = false;
  let staffMe = null;
  const ROLES = ['ADMIN', 'OWNER', 'DRIVER'];

  async function staffCall(body) {
    const { data, error } = await DB.client.functions.invoke('staff-admin', { body });
    if (!error) return { data };
    let code = '';
    try { code = (await error.context.json()).error || ''; } catch { code = ''; }
    return { error: code || 'SERVER_ERROR' };
  }
  const stErr = (code) => (t('st.err_' + code) !== 'st.err_' + code ? t('st.err_' + code) : t('common.error_generic') + ' (' + code + ')');

  // 10 easy-to-read characters (no 0/O, 1/l/I), from the browser's secure random generator
  function newPassword() {
    const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    const a = new Uint32Array(10);
    crypto.getRandomValues(a);
    return [...a].map((n) => chars[n % chars.length]).join('');
  }

  async function loadStaff() {
    staffLoaded = true;
    const box = $('#st-list');
    box.innerHTML = `<p class="hint">${esc(t('common.loading'))}</p>`;
    const { data, error } = await staffCall({ action: 'list' });
    if (error) { box.innerHTML = `<div class="alert alert-error">${esc(stErr(error))}</div>`; staffLoaded = false; return; }
    staffMe = data.me;
    const when = (iso) => (iso ? new Date(iso).toLocaleString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }) : t('st.never'));
    box.innerHTML = data.staff.length ? '' : `<p class="empty">${esc(t('st.none'))}</p>`;
    data.staff.forEach((s) => {
      const isMe = s.user_id === staffMe;
      const row = document.createElement('div');
      row.className = 'card st-row' + (s.active ? '' : ' off');
      row.innerHTML = `
        <div class="st-head">
          <div class="st-who"><strong>${esc(s.name)}</strong> ${isMe ? `<span class="pill pill-ok">${esc(t('st.you'))}</span>` : ''}
            <span class="pill">${esc(t('staff.role_' + s.role))}</span>${s.active ? '' : ` <span class="pill pill-off">${esc(t('st.inactive'))}</span>`}
            <div class="hint" dir="ltr" style="text-align:start">${esc(s.email)}</div>
            <div class="hint">${esc(t('st.last_login', { when: when(s.last_sign_in_at) }))}</div></div>
        </div>
        <div class="od-actions">
          <button type="button" class="btn btn-small" data-act="edit">${esc(t('common.edit'))}</button>
          <button type="button" class="btn btn-small" data-act="reset">${esc(t('st.reset'))}</button>
          ${isMe ? '' : `<button type="button" class="btn btn-small ${s.active ? 'btn-danger' : ''}" data-act="active">${esc(t(s.active ? 'st.deactivate' : 'st.reactivate'))}</button>`}
        </div>
        <div class="st-edit" hidden>
          <div class="grid-2 stack-sm">
            <label>${esc(t('st.name'))}<input type="text" data-e="name" maxlength="60" value="${esc(s.name)}"></label>
            <label>${esc(t('st.role'))}<select data-e="role" ${isMe ? 'disabled' : ''}>${ROLES.map((r) => `<option value="${r}" ${r === s.role ? 'selected' : ''}>${esc(t('staff.role_' + r))}</option>`).join('')}</select></label>
          </div>
          ${isMe ? `<p class="hint">${esc(t('st.own_role'))}</p>` : ''}
          <button type="button" class="btn btn-primary btn-small" data-act="save">${esc(t('common.save'))}</button>
        </div>`;
      const act = async (body, okMsg) => {
        row.querySelectorAll('button').forEach((b) => { b.disabled = true; });
        const { error } = await staffCall(body);
        if (error) { toast(stErr(error), true); row.querySelectorAll('button').forEach((b) => { b.disabled = false; }); return false; }
        if (okMsg) toast(okMsg);
        await loadStaff();
        return true;
      };
      row.querySelector('[data-act=edit]').addEventListener('click', () => { const e = $('.st-edit', row); e.hidden = !e.hidden; });
      row.querySelector('[data-act=save]').addEventListener('click', () => {
        const name = $('[data-e=name]', row).value.trim();
        const role = $('[data-e=role]', row).value;
        const body = { action: 'update', user_id: s.user_id };
        if (name !== s.name) body.name = name;
        if (!isMe && role !== s.role) body.role = role;
        act(body, t('set.saved'));
      });
      row.querySelector('[data-act=reset]').addEventListener('click', async () => {
        const pw = newPassword();
        if (!confirm(t('st.reset_q', { name: s.name }))) return;
        const ok = await act({ action: 'reset_password', user_id: s.user_id, password: pw });
        if (ok) showCreds(t('st.reset_done', { name: s.name }), s.email, pw);
      });
      const a = row.querySelector('[data-act=active]');
      if (a) a.addEventListener('click', () => {
        if (s.active && !confirm(t('st.deactivate_q', { name: s.name }))) return;
        act({ action: 'update', user_id: s.user_id, active: !s.active }, t(s.active ? 'st.deactivated' : 'st.reactivated', { name: s.name }));
      });
      box.appendChild(row);
    });
  }

  $('#st-roles').innerHTML = ROLES.map((r, i) => `<label class="check st-role"><input type="radio" name="st-role" value="${r}" ${i === 1 ? 'checked' : ''}>
    <span><strong>${esc(t('staff.role_' + r))}</strong><br><span class="hint">${esc(t('st.role_' + r))}</span></span></label>`).join('');
  $('#st-password').value = newPassword();
  $('#st-gen').addEventListener('click', () => { $('#st-password').value = newPassword(); });
  $('#st-create').addEventListener('click', async () => {
    const err = $('#st-error');
    err.hidden = true;
    const name = $('#st-name').value.trim();
    const email = $('#st-email').value.trim();
    const password = $('#st-password').value;
    const role = (document.querySelector('[name=st-role]:checked') || {}).value;
    if (!name) { err.textContent = stErr('BAD_NAME'); err.hidden = false; return; }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { err.textContent = stErr('BAD_EMAIL'); err.hidden = false; return; }
    if (password.length < 8) { err.textContent = stErr('BAD_PASSWORD'); err.hidden = false; return; }
    const btn = $('#st-create');
    btn.disabled = true;
    const { error } = await staffCall({ action: 'create', name, email, role, password });
    btn.disabled = false;
    if (error) { err.textContent = stErr(error); err.hidden = false; return; }
    showCreds(t('st.created', { name }), email.toLowerCase(), password);
    $('#st-name').value = ''; $('#st-email').value = ''; $('#st-password').value = newPassword();
    await loadStaff();
  });

  // shows the login details ONCE so Mika can send them to the person
  const doneDlg = $('#st-done');
  doneDlg.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => { doneDlg.close(); $('#st-creds').textContent = ''; }));
  function showCreds(title, email, password) {
    const login = new URL('login.html', location.href).href;
    $('#st-done-title').textContent = title;
    $('#st-done-text').textContent = t('st.send_these');
    $('#st-creds').textContent = `${t('st.login_page')}: ${login}\n${t('st.email')}: ${email}\n${t('st.password')}: ${password}`;
    doneDlg.showModal();
  }
  $('#st-copy').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText($('#st-creds').textContent); toast(t('st.copied')); } catch { toast(t('common.error_generic'), true); }
  });

  // ---------- start ----------
  // pick the tab first, then load: a tab pressed while loading is never switched back
  if (startTab === 'staff' && !canEdit) startTab = 'shop';
  showTab(startTab);
  await Promise.all([loadSettings(), loadTexts(), loadZones()]);
  updateZoneSave();
  window.Settings = { changes, textChanges, zDirty, parseFee };
})();
