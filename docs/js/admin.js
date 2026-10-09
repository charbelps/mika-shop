// Admin screen: products (with variants + photos) and categories. ADMIN only.
// Products are saved through the database function admin_save_product (one transaction);
// every stock change is logged by a database trigger, so nothing here writes stock_log.
(async function () {
  await StaffAuth.require(['ADMIN']);
  const t = I18n.t;
  const $ = (s, root = document) => root.querySelector(s);
  const settings = await DB.settings().catch(() => ({}));
  const currency = settings.currency;
  const lowStock = parseInt(settings.low_stock_threshold, 10); // NaN = not set yet
  const PAGE = 24;
  const SKU_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/;

  let categories = [];
  const list = { page: 0, q: '', cat: '', filter: '', total: 0, req: 0 };

  // ---------- small helpers ----------
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
    toastTimer = setTimeout(() => { el.hidden = true; }, isError ? 6000 : 2500);
  }
  function errorText(err) {
    const m = (err && (err.message || err.details)) || '';
    if (/SKU_EXISTS/.test(m)) return t('admin.err_sku_exists');
    if (/NEEDS_VARIANT/.test(m)) return t('admin.err_needs_variant');
    if (err && err.code === '23514') return t('admin.err_invalid_values');
    if (err && err.code === '42501') return t('admin.err_permission');
    return t('common.error_generic') + (m ? ' (' + m + ')' : '');
  }
  function num(v) { return v === '' || v == null ? null : Number(v); }
  function stockOf(p) {
    return p.has_variants
      ? (p.variants || []).filter((v) => v.active).reduce((s, v) => s + v.stock, 0)
      : p.stock;
  }
  function closeOnButtons(dialog) {
    dialog.querySelectorAll('[data-close]').forEach((b) => b.addEventListener('click', () => dialog.close()));
  }

  // ---------- tabs ----------
  function showTab() {
    const TABS = ['products', 'categories', 'import', 'waiting'];
    const tab = TABS.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'products';
    TABS.forEach((n) => { $('#tab-' + n).hidden = n !== tab; });
    const navTab = tab === 'waiting' ? 'products' : tab;   // "Back in stock" lives under Products
    document.querySelectorAll('.adm-tabs a[data-tab]').forEach((a) => {
      if (a.dataset.tab === navTab) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    });
    if (tab === 'products') loadProducts();
    if (tab === 'categories') renderCategories();
    if (tab === 'import' && window.ImportTab) window.ImportTab.show({ categories, toast });
    if (tab === 'waiting') loadWaiting();
  }
  window.addEventListener('hashchange', showTab);

  // ---------- categories ----------
  async function loadCategories() {
    const { data, error } = await DB.client.from('categories')
      .select('id,name_en,name_ar,parent_id,sort,active').order('sort').order('name_en');
    if (error) throw error;
    categories = data;
  }
  // Categories in display order with their depth (parents first, children under them).
  function catTree() {
    const out = [];
    const walk = (parentId, depth) => {
      categories.filter((c) => (c.parent_id || null) === parentId)
        .forEach((c) => { out.push({ c, depth }); if (depth < 5) walk(c.id, depth + 1); });
    };
    walk(null, 0);
    // orphans (parent hidden/missing) still listed
    categories.filter((c) => !out.some((o) => o.c.id === c.id)).forEach((c) => out.push({ c, depth: 0 }));
    return out;
  }
  function descendants(id) {
    const ids = new Set([id]);
    let grew = true;
    while (grew) {
      grew = false;
      categories.forEach((c) => { if (c.parent_id && ids.has(c.parent_id) && !ids.has(c.id)) { ids.add(c.id); grew = true; } });
    }
    return ids;
  }
  function catName(id) {
    const c = categories.find((x) => x.id === id);
    return c ? I18n.pick(c, 'name') : '';
  }
  function fillCategorySelect(sel, { first, exclude } = {}) {
    const keep = sel.value;
    sel.innerHTML = '';
    if (first) sel.append(new Option(first.label, first.value));
    catTree().forEach(({ c, depth }) => {
      if (exclude && exclude.has(c.id)) return;
      const label = ' '.repeat(depth) + I18n.pick(c, 'name') + (c.active ? '' : ' (' + t('admin.pill_hidden') + ')');
      sel.append(new Option(label, c.id));
    });
    sel.value = keep;
    if (sel.selectedIndex < 0) sel.selectedIndex = 0;
  }

  function renderCategories() {
    const box = $('#c-list');
    const tree = catTree();
    if (!tree.length) { box.innerHTML = `<p class="empty">${esc(t('admin.no_categories'))}</p>`; return; }
    box.innerHTML = '';
    tree.forEach(({ c, depth }) => {
      const other = I18n.lang === 'ar' ? c.name_en : c.name_ar;
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'row-item';
      b.style.paddingInlineStart = (0.75 + depth * 1.5) + 'rem';
      b.innerHTML = `<div class="body"><div class="title">${depth ? '↳ ' : ''}${esc(I18n.pick(c, 'name'))}</div>
        <div class="meta">${esc(other || '—')}</div></div>
        <div class="end">${c.active ? '' : `<span class="pill pill-off">${esc(t('admin.pill_hidden'))}</span>`}</div>`;
      b.addEventListener('click', () => openCategory(c));
      box.appendChild(b);
    });
  }

  const cDialog = $('#category-dialog');
  closeOnButtons(cDialog);
  let editingCat = null;
  function openCategory(c) {
    editingCat = c;
    $('#cd-title').textContent = t(c ? 'admin.edit_category' : 'admin.new_category');
    $('#cd-error').hidden = true;
    $('#cd-name-en').value = c ? c.name_en : '';
    $('#cd-name-ar').value = c ? c.name_ar : '';
    $('#cd-sort').value = c ? c.sort : 0;
    $('#cd-active').checked = c ? c.active : true;
    const parentSel = $('#cd-parent');
    parentSel.value = '';
    fillCategorySelect(parentSel, { first: { label: t('common.none'), value: '' }, exclude: c ? descendants(c.id) : null });
    parentSel.value = c && c.parent_id ? c.parent_id : '';
    cDialog.showModal();
  }
  $('#btn-new-category').addEventListener('click', () => openCategory(null));
  $('#category-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const err = $('#cd-error');
    const row = {
      name_en: $('#cd-name-en').value.trim(),
      name_ar: $('#cd-name-ar').value.trim(),
      parent_id: $('#cd-parent').value ? Number($('#cd-parent').value) : null,
      sort: parseInt($('#cd-sort').value, 10) || 0,
      active: $('#cd-active').checked,
    };
    if (!row.name_en) { err.textContent = t('admin.err_name'); err.hidden = false; return; }
    const btn = $('#cd-save');
    btn.disabled = true;
    const q = editingCat
      ? DB.client.from('categories').update(row).eq('id', editingCat.id)
      : DB.client.from('categories').insert(row);
    const { error } = await q;
    btn.disabled = false;
    if (error) { err.textContent = errorText(error); err.hidden = false; return; }
    cDialog.close();
    toast(t('admin.saved_category'));
    await loadCategories();
    refreshCategoryFilters();
    renderCategories();
  });

  function refreshCategoryFilters() {
    fillCategorySelect($('#p-category'), { first: { label: t('admin.all_categories'), value: '' } });
    fillCategorySelect($('#pd-category'), { first: { label: t('admin.no_category'), value: '' } });
  }

  // ---------- product list ----------
  async function loadProducts() {
    const box = $('#p-list');
    const reqId = ++list.req;
    box.setAttribute('aria-busy', 'true');
    let q = DB.client.from('products')
      .select('sku,name_en,name_ar,price,stock,has_variants,photos,active,featured,ar_needs_review,category_id,variants(stock,active)', { count: 'exact' })
      .order('updated_at', { ascending: false })
      .range(list.page * PAGE, list.page * PAGE + PAGE - 1);
    const s = list.q.replace(/[",()\\*%]/g, ' ').trim();
    if (s) q = q.or(`name_en.ilike."*${s}*",name_ar.ilike."*${s}*",sku.ilike."*${s}*",search_keywords.ilike."*${s}*"`);
    if (list.cat) q = q.in('category_id', [...descendants(Number(list.cat))]);
    if (list.filter === 'ar_review') q = q.eq('ar_needs_review', true);
    if (list.filter === 'hidden') q = q.eq('active', false);
    if (list.filter === 'featured') q = q.eq('featured', true);

    const { data, error, count } = await q;
    if (reqId !== list.req) return; // a newer search started meanwhile
    box.removeAttribute('aria-busy');
    if (error) { box.innerHTML = `<div class="alert alert-error">${esc(errorText(error))}</div>`; return; }
    list.total = count || 0;
    $('#p-count').textContent = t('admin.count', { n: list.total });
    const pages = Math.max(1, Math.ceil(list.total / PAGE));
    $('#p-pager').hidden = pages <= 1;
    $('#p-page').textContent = t('admin.page', { n: list.page + 1, total: pages });
    $('#p-prev').disabled = list.page === 0;
    $('#p-next').disabled = list.page >= pages - 1;

    if (!data.length) { box.innerHTML = `<p class="empty">${esc(t('admin.no_products'))}</p>`; return; }
    box.innerHTML = '';
    data.forEach((p) => {
      const stock = stockOf(p);
      const pills = [];
      if (!p.active) pills.push(['pill-off', 'admin.pill_hidden']);
      if (p.ar_needs_review) pills.push(['pill-warn', 'admin.pill_ar']);
      if (stock === 0) pills.push(['pill-danger', 'admin.pill_out']);
      else if (!isNaN(lowStock) && stock <= lowStock) pills.push(['pill-warn', 'admin.pill_low']);
      if (p.featured) pills.push(['pill-ok', 'admin.pill_featured']);
      const thumb = p.photos && p.photos[0]
        ? `<img class="thumb" src="${esc(Photos.thumbUrl(p.photos[0]))}" alt="" loading="lazy">`
        : `<div class="thumb" aria-hidden="true"></div>`;
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'row-item';
      b.dataset.sku = p.sku;
      b.innerHTML = `${thumb}
        <div class="body">
          <div class="title">${esc(I18n.pick(p, 'name'))}</div>
          <div class="meta" dir="auto">${esc(p.sku)}${p.category_id ? ' · ' + esc(catName(p.category_id)) : ''}</div>
          <div>${pills.map(([c, k]) => `<span class="pill ${c}">${esc(t(k))}</span>`).join(' ')}</div>
        </div>
        <div class="end"><div>${esc(I18n.money(p.price, currency))}</div>
          <div class="meta">${esc(t('admin.stock_n', { n: stock }))}</div></div>`;
      b.addEventListener('click', () => openProduct(p.sku));
      box.appendChild(b);
    });
  }

  let searchTimer;
  $('#p-search').addEventListener('input', (e) => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { list.q = e.target.value; list.page = 0; loadProducts(); }, 300);
  });
  $('#p-category').addEventListener('change', (e) => { list.cat = e.target.value; list.page = 0; loadProducts(); });
  $('#p-filter').addEventListener('change', (e) => { list.filter = e.target.value; list.page = 0; loadProducts(); });
  $('#p-prev').addEventListener('click', () => { list.page--; loadProducts(); window.scrollTo(0, 0); });
  $('#p-next').addEventListener('click', () => { list.page++; loadProducts(); window.scrollTo(0, 0); });

  // ---------- back in stock (F4): customers waiting for a sold-out item ----------
  // Requests come from the shop (request_stock_alert). Mika sends each person one WhatsApp
  // (ready message in the customer's language) and marks it Done (staff_stock_alerts_done).
  async function waitingCount() {
    const { count, error } = await DB.client.from('stock_alerts').select('id', { count: 'exact', head: true }).is('notified_at', null);
    const el = $('#w-count');
    el.textContent = count || '';
    el.hidden = !!error || !count;
  }

  function fillTemplate(template, values) {
    return template.replace(/\{(\w+)\}/g, (match, key) =>
      Object.prototype.hasOwnProperty.call(values, key) ? String(values[key]) : match);
  }
  // the WhatsApp message in the customer's language (custom text from Settings, or the standard one)
  async function backMessage(a) {
    let lang = a.lang === 'ar' ? 'ar' : 'en';
    let tc = t;
    try { tc = await I18n.translator(lang); } catch { lang = I18n.lang; }
    const p = a.products || {};
    const v = a.variants;
    const pick = (o, f) => (lang === 'ar' && o[f + '_ar'] ? o[f + '_ar'] : o[f + '_en']) || '';
    const product = pick(p, 'name') + (v ? ' (' + pick(v, 'label') + ')' : '');
    const url = new URL('../product.html?sku=' + encodeURIComponent(a.sku), location.href).href;
    const values = { name: a.name || '', product, url };
    const custom = String(settings['whatsapp_back_' + lang] || '').trim();
    const text = custom ? fillTemplate(custom, values) : tc('aw.msg', values);
    return 'https://wa.me/' + a.phone.replace(/\D/g, '') + '?text=' + encodeURIComponent(text);
  }

  let waitingReq = 0;
  async function loadWaiting() {
    const my = ++waitingReq;
    const box = $('#w-list');
    box.innerHTML = `<p class="hint">${esc(t('common.loading'))}</p>`;
    const { data, error } = await DB.client.from('stock_alerts')
      .select('id,sku,variant_id,phone,name,lang,created_at,products(name_en,name_ar,stock,has_variants,active,photos),variants(label_en,label_ar,stock,active)')
      .is('notified_at', null).order('created_at').limit(1000);
    if (my !== waitingReq) return;
    if (error) { box.innerHTML = `<div class="alert alert-error">${esc(errorText(error))}</div>`; return; }
    waitingCount();
    if (!data.length) { box.innerHTML = `<p class="empty">${esc(t('aw.none'))}</p>`; return; }
    // one group per product + option; items back in stock first, then the most wanted
    const groups = new Map();
    data.forEach((a) => {
      const key = a.sku + '|' + (a.variant_id || '');
      if (!groups.has(key)) groups.set(key, { key, sku: a.sku, p: a.products || {}, v: a.variants, people: [] });
      groups.get(key).people.push(a);
    });
    const stockOfGroup = (g) => (g.v ? g.v.stock : g.p.stock) || 0;
    const list = [...groups.values()].sort((x, y) => (stockOfGroup(y) > 0) - (stockOfGroup(x) > 0) || y.people.length - x.people.length);
    const links = await Promise.all(list.flatMap((g) => g.people.map(backMessage)));
    let li = 0;
    const when = (iso) => new Date(iso).toLocaleDateString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB', { day: 'numeric', month: 'short' });
    box.innerHTML = list.map((g) => {
      const stock = stockOfGroup(g);
      const back = stock > 0 && g.p.active !== false && (!g.v || g.v.active);
      const name = I18n.pick(g.p, 'name') + (g.v ? ' · ' + I18n.pick(g.v, 'label') : '');
      const thumb = g.p.photos && g.p.photos[0] ? `<img class="thumb" src="${esc(Photos.thumbUrl(g.p.photos[0]))}" alt="" loading="lazy">` : '<div class="thumb" aria-hidden="true"></div>';
      return `<div class="card w-group${back ? ' back' : ''}" data-key="${esc(g.key)}">
        <div class="row-item" style="padding:0;background:none">${thumb}
          <div class="body"><div class="title">${esc(name)}</div><div class="meta" dir="ltr">${esc(g.sku)}</div></div>
          <div class="end"><span class="pill ${back ? 'pill-ok' : 'pill-off'}">${esc(back ? t('aw.back_in_stock', { n: stock }) : t('aw.still_out'))}</span></div>
        </div>
        <p class="hint">${esc(t(g.people.length === 1 ? 'aw.one_waiting' : 'aw.n_waiting', { n: g.people.length }))}${back ? '' : ' · ' + esc(t('aw.wait_hint'))}</p>
        <ul class="w-people">${g.people.map((a) => `<li data-id="${a.id}">
            <div class="w-who"><strong>${esc(a.name || t('aw.no_name'))}</strong> <span dir="ltr">${esc(a.phone)}</span>
              <div class="meta">${esc(t('aw.asked', { date: when(a.created_at), lang: t('prep.lang_' + (a.lang === 'ar' ? 'ar' : 'en')) }))}</div></div>
            <div class="w-acts"><a class="btn btn-small" href="${esc(links[li++])}" target="_blank" rel="noopener">💬 ${esc(t('aw.send'))}</a>
              <button type="button" class="btn btn-small" data-done="${a.id}">✓ ${esc(t('aw.done'))}</button></div>
          </li>`).join('')}</ul>
        ${g.people.length > 1 ? `<button type="button" class="btn btn-small btn-ghost" data-done-all="${g.people.map((a) => a.id).join(',')}">${esc(t('aw.done_all', { n: g.people.length }))}</button>` : ''}
      </div>`;
    }).join('');
  }

  $('#w-list').addEventListener('click', async (e) => {
    const one = e.target.closest('[data-done]');
    const all = e.target.closest('[data-done-all]');
    if (!one && !all) return;
    const ids = (one ? one.dataset.done : all.dataset.doneAll).split(',').map(Number);
    if (all && !confirm(t('aw.done_all_q', { n: ids.length }))) return;
    (one || all).disabled = true;
    const { error } = await DB.client.rpc('staff_stock_alerts_done', { p_ids: ids, p_done: true });
    if (error) { (one || all).disabled = false; toast(errorText(error), true); return; }
    toast(t('aw.marked', { n: ids.length }));
    loadWaiting();
  });

  // ---------- product editor ----------
  const pDialog = $('#product-dialog');
  closeOnButtons(pDialog);
  // stockSeen / variant.stock_seen: the stock when the editor opened. The database keeps the
  // current stock if an order changed it meanwhile and Mika didn't touch the field (STOCK_CHANGED
  // if she did), so saving never brings sold items back.
  const ed = { isNew: true, originalPhotos: [], photos: [], uploaded: [], variants: [], saved: false, busy: 0, stockSeen: null, waiting: 0 };

  function showEdError(msg) { const el = $('#pd-error'); el.textContent = msg; el.hidden = false; el.scrollIntoView({ block: 'nearest' }); }

  async function openProduct(sku) {
    let p = null, history = [];
    if (sku) {
      const { data, error } = await DB.client.from('products')
        .select('*, variants(id,label_en,label_ar,price,stock,active,sort)').eq('sku', sku).single();
      if (error) { toast(errorText(error), true); return; }
      p = data;
      const h = await DB.client.from('stock_log').select('created_at,change,stock_after,reason,variant_id')
        .eq('sku', sku).order('created_at', { ascending: false }).limit(20);
      history = h.data || [];
    }
    // customers waiting for this item (F4): a reminder while Mika edits the stock
    let waiting = 0;
    if (sku) {
      const w = await DB.client.from('stock_alerts').select('id', { count: 'exact', head: true }).eq('sku', sku).is('notified_at', null);
      waiting = w.count || 0;
    }
    ed.waiting = waiting;
    $('#pd-waiting').textContent = t('aw.editor_note', { n: waiting });
    $('#pd-waiting').hidden = !waiting;
    Object.assign(ed, {
      isNew: !p,
      originalPhotos: p ? [...p.photos] : [],
      photos: p ? [...p.photos] : [],
      uploaded: [],
      variants: p ? [...p.variants].sort((a, b) => a.sort - b.sort || a.id - b.id).map((v) => ({ ...v, stock_seen: v.stock })) : [],
      saved: false,
      busy: 0,
      stockSeen: p ? p.stock : null,
    });
    $('#pd-title').textContent = t(p ? 'admin.edit_product' : 'admin.new_product');
    $('#pd-error').hidden = true;
    const sk = $('#pd-sku');
    sk.value = p ? p.sku : '';
    sk.readOnly = !!p;
    $('#pd-name-en').value = p ? p.name_en : '';
    $('#pd-name-ar').value = p ? p.name_ar : '';
    $('#pd-desc-en').value = p ? p.desc_en : '';
    $('#pd-desc-ar').value = p ? p.desc_ar : '';
    $('#pd-meas-en').value = p ? p.measurements_en : '';
    $('#pd-meas-ar').value = p ? p.measurements_ar : '';
    $('#pd-keywords').value = p ? p.search_keywords : '';
    $('#pd-category').value = p && p.category_id ? p.category_id : '';
    $('#pd-price').value = p ? p.price : '';
    $('#pd-compare').value = p && p.compare_price != null ? p.compare_price : '';
    $('#pd-stock').value = p ? p.stock : 0;
    $('#pd-has-variants').checked = p ? p.has_variants : false;
    $('#pd-active').checked = p ? p.active : true;
    $('#pd-featured').checked = p ? p.featured : false;
    $('#pd-ar-review').hidden = !(p && p.ar_needs_review);
    $('#pd-ar-ok').checked = false;
    toggleVariants();
    renderPhotos();
    renderVariants();
    renderHistory(history, p);
    pDialog.showModal();
    (p ? $('#pd-name-en') : sk).focus();
  }
  $('#btn-new-product').addEventListener('click', () => openProduct(null));

  function toggleVariants() {
    const on = $('#pd-has-variants').checked;
    $('#pd-stock-wrap').hidden = on;
    $('#pd-variants-wrap').hidden = !on;
    if (on && !ed.variants.length) { ed.variants.push(blankVariant()); renderVariants(); }
  }
  $('#pd-has-variants').addEventListener('change', toggleVariants);

  // photos
  function renderPhotos() {
    const box = $('#pd-photos');
    box.innerHTML = '';
    ed.photos.forEach((path, i) => {
      const d = document.createElement('div');
      d.className = 'photo';
      d.innerHTML = `<img src="${esc(Photos.thumbUrl(path))}" alt="">
        ${i === 0 ? `<span class="tag">${esc(t('admin.main'))}</span>` : ''}
        <div class="tools">
          ${i > 0 ? `<button type="button" data-main title="${esc(t('admin.make_main'))}" aria-label="${esc(t('admin.make_main'))}">★</button>` : '<span></span>'}
          <button type="button" data-remove title="${esc(t('admin.remove_photo'))}" aria-label="${esc(t('admin.remove_photo'))}">✕</button>
        </div>`;
      const mainBtn = d.querySelector('[data-main]');
      if (mainBtn) mainBtn.addEventListener('click', () => { ed.photos.unshift(ed.photos.splice(i, 1)[0]); renderPhotos(); });
      d.querySelector('[data-remove]').addEventListener('click', () => { ed.photos.splice(i, 1); renderPhotos(); });
      box.appendChild(d);
    });
    for (let i = 0; i < ed.busy; i++) {
      const d = document.createElement('div');
      d.className = 'photo-add';
      d.textContent = t('admin.uploading');
      box.appendChild(d);
    }
    const add = document.createElement('button');
    add.type = 'button';
    add.className = 'photo-add';
    add.textContent = '+ ' + t('admin.add_photos');
    add.addEventListener('click', () => {
      const sku = $('#pd-sku').value.trim();
      if (!SKU_RE.test(sku)) { showEdError(t('admin.err_sku_first')); return; }
      $('#pd-photo-input').click();
    });
    box.appendChild(add);
  }
  $('#pd-photo-input').addEventListener('change', async (e) => {
    const files = [...e.target.files];
    e.target.value = '';
    const sku = $('#pd-sku').value.trim();
    ed.busy += files.length;
    renderPhotos();
    for (const f of files) {
      try {
        const path = await Photos.upload(sku, f);
        ed.photos.push(path);
        ed.uploaded.push(path);
      } catch (ex) {
        console.error(ex);
        toast(t('admin.err_photo', { name: f.name }), true);
      }
      ed.busy--;
      renderPhotos();
    }
  });

  // variants
  function blankVariant() { return { id: null, label_en: '', label_ar: '', price: null, stock: 0, active: true, sort: ed.variants.length }; }
  function renderVariants() {
    const box = $('#pd-variants');
    box.innerHTML = '';
    ed.variants.forEach((v, i) => {
      const d = document.createElement('div');
      d.className = 'variant-row';
      d.innerHTML = `
        <div class="full"><label>${esc(t('admin.variant_label_en'))}</label><input type="text" dir="ltr" data-k="label_en" value="${esc(v.label_en)}"></div>
        <div class="full"><label>${esc(t('admin.variant_label_ar'))}</label><input type="text" dir="rtl" lang="ar" data-k="label_ar" value="${esc(v.label_ar)}"></div>
        <div><label>${esc(t('admin.variant_price'))}</label><input type="number" inputmode="decimal" min="0" step="0.01" dir="ltr" data-k="price" value="${v.price == null ? '' : esc(v.price)}"></div>
        <div><label>${esc(t('admin.variant_stock'))}</label><input type="number" inputmode="numeric" min="0" step="1" dir="ltr" data-k="stock" value="${esc(v.stock)}"></div>
        <div class="full" style="display:flex;justify-content:space-between;align-items:center">
          <label class="check"><input type="checkbox" data-k="active" ${v.active ? 'checked' : ''}> ${esc(t('admin.variant_active'))}</label>
          ${v.id ? '' : `<button type="button" class="btn btn-small btn-danger" data-remove>${esc(t('admin.remove'))}</button>`}
        </div>`;
      d.querySelectorAll('[data-k]').forEach((inp) => {
        inp.addEventListener('input', () => {
          const k = inp.dataset.k;
          v[k] = k === 'active' ? inp.checked : inp.value;
        });
        inp.addEventListener('change', () => { if (inp.dataset.k === 'active') v.active = inp.checked; });
      });
      const rm = d.querySelector('[data-remove]');
      if (rm) rm.addEventListener('click', () => { ed.variants.splice(i, 1); renderVariants(); });
      box.appendChild(d);
    });
  }
  $('#pd-add-variant').addEventListener('click', () => { ed.variants.push(blankVariant()); renderVariants(); });

  function renderHistory(rows, p) {
    $('#pd-history-wrap').hidden = !p;
    const box = $('#pd-history');
    if (!rows.length) { box.innerHTML = `<p class="hint">—</p>`; return; }
    const vName = (id) => { const v = ed.variants.find((x) => x.id === id); return v ? ' · ' + (I18n.lang === 'ar' && v.label_ar ? v.label_ar : v.label_en) : ''; };
    box.innerHTML = rows.map((r) => `<div class="row-item" style="min-height:auto">
        <div class="body"><div>${esc(t('admin.reason_' + r.reason))}${esc(vName(r.variant_id))}</div>
        <div class="meta">${esc(new Date(r.created_at).toLocaleString(I18n.lang === 'ar' ? 'ar-LB-u-nu-latn' : 'en-GB'))}</div></div>
        <div class="end"><strong dir="ltr">${r.change > 0 ? '+' : ''}${r.change}</strong><div class="meta">→ ${r.stock_after == null ? '' : r.stock_after}</div></div>
      </div>`).join('');
  }

  // save
  $('#product-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    $('#pd-error').hidden = true;
    if (ed.busy) return;
    const sku = $('#pd-sku').value.trim();
    const hasVariants = $('#pd-has-variants').checked;
    const price = num($('#pd-price').value);
    if (!SKU_RE.test(sku)) return showEdError(t('admin.err_sku'));
    if (!$('#pd-name-en').value.trim()) return showEdError(t('admin.err_name'));
    if (price == null || isNaN(price) || price < 0) return showEdError(t('admin.err_price'));
    if (hasVariants) {
      if (ed.variants.some((v) => !String(v.label_en).trim())) return showEdError(t('admin.err_variant_label'));
      if (!ed.variants.some((v) => v.active)) return showEdError(t('admin.err_needs_variant'));
    }
    const wasReview = !$('#pd-ar-review').hidden;
    const product = {
      sku,
      name_en: $('#pd-name-en').value.trim(),
      name_ar: $('#pd-name-ar').value.trim(),
      desc_en: $('#pd-desc-en').value,
      desc_ar: $('#pd-desc-ar').value,
      measurements_en: $('#pd-meas-en').value.trim(),
      measurements_ar: $('#pd-meas-ar').value.trim(),
      search_keywords: $('#pd-keywords').value.trim(),
      category_id: $('#pd-category').value || null,
      price,
      compare_price: num($('#pd-compare').value),
      stock: hasVariants ? 0 : Math.max(0, parseInt($('#pd-stock').value, 10) || 0),
      has_variants: hasVariants,
      photos: ed.photos,
      featured: $('#pd-featured').checked,
      active: $('#pd-active').checked,
      ar_needs_review: wasReview && !$('#pd-ar-ok').checked,
    };
    if (!ed.isNew) product.stock_seen = ed.stockSeen;
    // A product without variants keeps any old variants but turns them off in the shop
    // only if the admin unticks them; we always send them so nothing is lost.
    const variants = ed.variants.map((v, i) => ({
      id: v.id, label_en: String(v.label_en).trim(), label_ar: String(v.label_ar || '').trim(),
      price: num(v.price), stock: Math.max(0, parseInt(v.stock, 10) || 0), active: !!v.active, sort: i,
      ...(v.id ? { stock_seen: v.stock_seen } : {}),
    }));
    // When "has options" is off, unsaved blank options are dropped.
    const toSend = hasVariants ? variants : variants.filter((v) => v.id);

    const btn = $('#pd-save');
    btn.disabled = true;
    btn.textContent = t('common.saving');
    const { error } = await DB.client.rpc('admin_save_product', { p_product: product, p_variants: toSend, p_is_new: ed.isNew });
    btn.disabled = false;
    btn.textContent = t('common.save');
    if (error && /STOCK_CHANGED/.test(error.message || '')) return stockChanged(sku);
    if (error) return showEdError(errorText(error));

    ed.saved = true;
    const removed = ed.originalPhotos.filter((p) => !ed.photos.includes(p));
    Photos.remove(removed);
    pDialog.close();
    const restocked = hasVariants ? variants.some((v) => v.active && v.stock > 0) : product.stock > 0;
    toast(t('admin.saved_product') + (ed.waiting && restocked ? ' · ' + t('aw.saved_note', { n: ed.waiting }) : ''));
    loadProducts();
    if (ed.waiting) waitingCount();
  });

  // An order changed the stock while the editor was open AND Mika changed the stock field:
  // nothing was saved. Fields she changed keep her number; untouched fields take the stock as it
  // is now (else the next Save would write the old number back). The next Save then goes through.
  async function stockChanged(sku) {
    const { data } = await DB.client.from('products').select('stock, variants(id,label_en,label_ar,stock)').eq('sku', sku).single();
    const untouched = (value, seen) => (parseInt(value, 10) || 0) === seen;
    const now = [];
    if (data) {
      const field = $('#pd-stock');
      if (data.stock !== ed.stockSeen && !$('#pd-has-variants').checked) now.push(String(data.stock));
      if (untouched(field.value, ed.stockSeen)) field.value = data.stock;
      ed.stockSeen = data.stock;
      (data.variants || []).forEach((dv) => {
        const v = ed.variants.find((x) => x.id === dv.id);
        if (!v) return;
        if (dv.stock !== v.stock_seen) now.push(I18n.pick(dv, 'label') + ': ' + dv.stock);
        if (untouched(v.stock, v.stock_seen)) v.stock = dv.stock;
        v.stock_seen = dv.stock;
      });
      renderVariants();
    }
    showEdError(t('admin.err_stock_changed', { now: now.join(', ') || '?' }));
  }

  // Closing without saving: delete photos uploaded during this edit.
  pDialog.addEventListener('close', () => {
    if (!ed.saved && ed.uploaded.length) Photos.remove(ed.uploaded);
    ed.uploaded = [];
  });

  // ---------- start ----------
  try {
    await loadCategories();
  } catch (ex) {
    toast(errorText(ex), true);
  }
  refreshCategoryFilters();
  showTab();
  if (location.hash !== '#waiting') waitingCount();
  window.AdminApp = { loadCategories: async () => { await loadCategories(); refreshCategoryFilters(); }, loadProducts, toast, loadWaiting };
})();
