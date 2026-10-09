// Bulk import (admin "Import" tab): CSV of products + photos matched by SKU.
// 1. CSV (from the Google Sheet template) -> preview with errors highlighted -> one-transaction
//    import through admin_import_products. Empty cells never erase existing data.
// 2. Photos named SKU.jpg, SKU_2.jpg, ... -> resized, uploaded as <SKU>/import-<n>.jpg
//    (re-uploading replaces) -> added to the product with admin_add_photos.
(function () {
  const t = (k, v) => I18n.t(k, v);
  const SKU_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/;
  const COLUMNS = ['sku', 'name_en', 'name_ar', 'desc_en', 'desc_ar', 'category', 'price', 'compare_price',
    'stock', 'featured', 'active', 'search_keywords', 'measurements_en', 'measurements_ar',
    'variant_en', 'variant_ar', 'variant_price', 'variant_stock'];
  const PRODUCT_FIELDS = ['name_en', 'name_ar', 'desc_en', 'desc_ar', 'category', 'price', 'compare_price', 'stock', 'featured', 'active',
    'search_keywords', 'measurements_en', 'measurements_ar'];

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  }
  function normHeader(h) { return String(h || '').trim().toLowerCase().replace(/[\s-]+/g, '_'); }
  function money(v) {
    const s = String(v).trim().replace(/,(?=\d{3}(\D|$))/g, ''); // 1,234.50 -> 1234.50
    return /^\d+(\.\d{1,2})?$/.test(s) ? s : null;
  }
  function int(v) { const s = String(v).trim(); return /^\d+$/.test(s) ? String(parseInt(s, 10)) : null; }
  function bool(v) {
    const s = String(v).trim().toLowerCase();
    if (['yes', 'y', 'true', '1', 'نعم'].includes(s)) return true;
    if (['no', 'n', 'false', '0', 'لا'].includes(s)) return false;
    return null;
  }

  // Pure: CSV text -> rows with errors + payload for admin_import_products.
  // existing: Map SKU -> { stock, has_variants, variants: Map(lower-case option name -> stock) }
  // for the products already in the database (a plain Set of SKUs also works, without the
  // stock comparison).
  function analyse(csvText, existing) {
    const parsed = Papa.parse(csvText, { header: true, skipEmptyLines: 'greedy', transformHeader: normHeader });
    const headers = parsed.meta.fields || [];
    const fileErrors = [];
    if (!headers.includes('sku')) fileErrors.push(t('imp.err_no_sku_column'));
    const unknown = headers.filter((h) => h && !COLUMNS.includes(h));
    const rows = [];
    const bySku = new Map();

    parsed.data.forEach((raw, i) => {
      const line = i + 2; // +1 header, +1 human counting
      const d = {};
      COLUMNS.forEach((c) => { d[c] = raw[c] == null ? '' : String(raw[c]).trim(); });
      const errors = {};
      const sku = d.sku;
      if (!SKU_RE.test(sku)) errors.sku = t('imp.err_sku');
      const isNew = !existing.has(sku) && !bySku.has(sku);
      const p = bySku.get(sku) || { sku, variants: [], _new: !existing.has(sku), _lines: [] };

      // product fields: first non-empty value wins
      if (d.price && money(d.price) == null) errors.price = t('imp.err_number');
      if (d.compare_price && money(d.compare_price) == null) errors.compare_price = t('imp.err_number');
      if (d.stock && int(d.stock) == null) errors.stock = t('imp.err_whole');
      if (d.featured && bool(d.featured) == null) errors.featured = t('imp.err_yesno');
      if (d.active && bool(d.active) == null) errors.active = t('imp.err_yesno');
      if (d.variant_price && money(d.variant_price) == null) errors.variant_price = t('imp.err_number');
      if (d.variant_stock && int(d.variant_stock) == null) errors.variant_stock = t('imp.err_whole');
      if (!d.variant_en && (d.variant_ar || d.variant_price || d.variant_stock)) errors.variant_en = t('imp.err_variant_name');

      PRODUCT_FIELDS.forEach((f) => {
        if (!d[f] || errors[f] || f in p) return;
        if (f === 'price' || f === 'compare_price') p[f] = money(d[f]);
        else if (f === 'stock') p[f] = int(d[f]);
        else if (f === 'featured' || f === 'active') p[f] = bool(d[f]);
        else p[f] = d[f];
      });
      if (d.variant_en && !errors.variant_en) {
        if (p.variants.some((v) => v.label_en.toLowerCase() === d.variant_en.toLowerCase())) {
          errors.variant_en = t('imp.err_variant_dup');
        } else {
          const v = { label_en: d.variant_en };
          if (d.variant_ar) v.label_ar = d.variant_ar;
          if (d.variant_price && !errors.variant_price) v.price = money(d.variant_price);
          if (d.variant_stock && !errors.variant_stock) v.stock = int(d.variant_stock);
          p.variants.push(v);
        }
      }
      p._lines.push(line);
      if (SKU_RE.test(sku)) bySku.set(sku, p);
      rows.push({ line, d, errors, isNew });
    });

    // product-level checks (need all rows of the SKU)
    for (const p of bySku.values()) {
      if (p._new && !p.name_en) markFirst(rows, p, 'name_en', t('imp.err_required_new'));
      if (p._new && p.price == null) markFirst(rows, p, 'price', t('imp.err_required_new'));
    }

    const products = [...bySku.values()].map((p) => {
      const out = { sku: p.sku };
      PRODUCT_FIELDS.forEach((f) => { if (f in p && p[f] != null) out[f] = p[f]; });
      if (p.variants.length) out.variants = p.variants;
      return out;
    });
    // Stock in the file that differs from the shop's stock now (products / options that already
    // exist). A re-imported sheet usually still has last week's numbers: orders since then would
    // be undone, so this stock is only written when Mika ticks "also change the stock".
    const stockChanges = [];
    if (existing instanceof Map) products.forEach((p) => {
      const cur = existing.get(p.sku);
      if (!cur) return;
      if (p.stock != null && !p.variants && !cur.has_variants && Number(p.stock) !== cur.stock) {
        stockChanges.push({ sku: p.sku, label: '', from: cur.stock, to: Number(p.stock) });
      }
      (p.variants || []).forEach((v) => {
        const vs = cur.variants.get(v.label_en.toLowerCase());
        if (v.stock != null && vs != null && Number(v.stock) !== vs) {
          stockChanges.push({ sku: p.sku, label: v.label_en, from: vs, to: Number(v.stock) });
        }
      });
    });

    const badRows = rows.filter((r) => Object.keys(r.errors).length).length;
    return {
      rows, products, fileErrors, unknown, badRows, stockChanges, existing,
      newCount: [...bySku.values()].filter((p) => p._new).length,
      updateCount: [...bySku.values()].filter((p) => !p._new).length,
    };
  }

  // What is sent to the database. Without "also change the stock": no stock for products and
  // options that already exist (new products and new options always get theirs).
  function payloadFor(a, withStock) {
    if (withStock || !(a.existing instanceof Map)) return a.products;
    return a.products.map((p) => {
      const cur = a.existing.get(p.sku);
      if (!cur) return p;
      const out = { ...p };
      delete out.stock;
      if (out.variants) {
        out.variants = out.variants.map((v) => {
          if (!cur.variants.has(v.label_en.toLowerCase())) return v;
          const rest = { ...v };
          delete rest.stock;
          return rest;
        });
      }
      return out;
    });
  }
  function markFirst(rows, p, field, msg) {
    const r = rows.find((x) => x.line === p._lines[0]);
    if (r && !r.errors[field]) r.errors[field] = msg;
  }

  // Pure: file names -> { sku, n } using the real SKUs (case-insensitive). SKU.jpg = 1, SKU_2.jpg = 2.
  function matchPhoto(fileName, skuLookup) {
    const m = /^(.+)\.(jpe?g|png|webp|heic|heif)$/i.exec(fileName);
    if (!m) return { error: 'imp.photo_err_type' };
    const base = m[1];
    const whole = skuLookup.get(base.toLowerCase());
    if (whole) return { sku: whole, n: 1 };
    const s = /^(.+)_(\d{1,2})$/.exec(base);
    if (s) {
      const sku = skuLookup.get(s[1].toLowerCase());
      if (sku) return { sku, n: parseInt(s[2], 10) || 1 };
    }
    return { error: 'imp.photo_err_nosku' };
  }

  // Every product already in the database with its stock: Map SKU -> { stock, has_variants, variants }
  async function fetchExisting() {
    const out = new Map();
    for (let from = 0; ; from += 1000) {
      const { data, error } = await DB.client.from('products').select('sku,stock,has_variants,variants(label_en,stock)')
        .order('sku').range(from, from + 999);
      if (error) throw error;
      data.forEach((r) => out.set(r.sku, {
        stock: r.stock,
        has_variants: r.has_variants,
        variants: new Map((r.variants || []).map((v) => [String(v.label_en).toLowerCase(), v.stock])),
      }));
      if (data.length < 1000) break;
    }
    return out;
  }

  // ---------- UI ----------
  let ctx = null;
  let rendered = false;
  let current = null;

  function show(c) {
    ctx = c;
    if (rendered) return;
    rendered = true;
    const root = document.getElementById('import-root');
    root.innerHTML = `
      <div class="card">
        <h2>1. ${esc(t('imp.csv_title'))}</h2>
        <p>${esc(t('imp.csv_help'))}</p>
        <ul class="hint">
          <li>${esc(t('imp.help_columns'))}</li>
          <li>${esc(t('imp.help_translate'))} <code dir="ltr">=GOOGLETRANSLATE(B2,"en","ar")</code></li>
          <li>${esc(t('imp.help_variants'))}</li>
          <li>${esc(t('imp.help_extra'))}</li>
          <li>${esc(t('imp.help_empty'))}</li>
        </ul>
        <p><a class="btn btn-small" href="../templates/import-template.csv" download>${esc(t('imp.download_template'))}</a></p>
        <label class="btn btn-primary" for="imp-file">${esc(t('imp.choose_csv'))}</label>
        <input type="file" id="imp-file" accept=".csv,text/csv" hidden>
        <div id="imp-preview"></div>
      </div>
      <div class="card">
        <h2>2. ${esc(t('imp.photos_title'))}</h2>
        <p>${esc(t('imp.photos_help'))}</p>
        <label class="btn btn-primary" for="imp-photos">${esc(t('imp.choose_photos'))}</label>
        <input type="file" id="imp-photos" accept="image/*" multiple hidden>
        <div id="imp-photo-report"></div>
      </div>`;
    root.querySelector('#imp-file').addEventListener('change', onCsv);
    root.querySelector('#imp-photos').addEventListener('change', onPhotos);
  }

  async function onCsv(e) {
    const file = e.target.files[0];
    e.target.value = '';
    if (!file) return;
    const box = document.getElementById('imp-preview');
    box.innerHTML = `<p class="hint">${esc(t('common.loading'))}</p>`;
    try {
      const [text, existing] = await Promise.all([file.text(), fetchExisting()]);
      current = analyse(text, existing);
      renderPreview(box, file.name);
    } catch (ex) {
      console.error(ex);
      box.innerHTML = `<div class="alert alert-error">${esc(t('common.error_generic'))} ${esc(ex.message || '')}</div>`;
    }
  }

  function renderPreview(box, fileName) {
    const a = current;
    const cols = ['sku', 'name_en', 'name_ar', 'category', 'price', 'compare_price', 'stock', 'variant_en', 'variant_stock', 'featured', 'active', 'search_keywords', 'measurements_en'];
    const ok = !a.fileErrors.length && !a.badRows && a.products.length;
    box.innerHTML = `
      <h3 style="margin-top:1rem">${esc(fileName)}</h3>
      ${a.fileErrors.map((m) => `<div class="alert alert-error">${esc(m)}</div>`).join('')}
      ${a.unknown.length ? `<div class="alert alert-warn">${esc(t('imp.unknown_columns', { cols: a.unknown.join(', ') }))}</div>` : ''}
      <p><strong>${esc(t('imp.summary', { products: a.products.length, new: a.newCount, update: a.updateCount, rows: a.rows.length }))}</strong></p>
      ${a.badRows ? `<div class="alert alert-error">${esc(t('imp.bad_rows', { n: a.badRows }))}</div>` : ''}
      ${a.stockChanges.length ? `<div class="alert alert-warn" id="imp-stock-box">
        <p>${esc(t('imp.stock_changes', { n: a.stockChanges.length }))}</p>
        <ul class="hint">${a.stockChanges.slice(0, 8).map((c) => `<li><span dir="ltr">${esc(c.sku)}${c.label ? ' · ' + esc(c.label) : ''}</span>: <span dir="ltr">${c.from} → ${c.to}</span></li>`).join('')}${a.stockChanges.length > 8 ? '<li>…</li>' : ''}</ul>
        <label class="check"><input type="checkbox" id="imp-stock-too"> ${esc(t('imp.stock_too'))}</label>
        <p class="hint">${esc(t('imp.stock_too_help'))}</p>
      </div>` : ''}
      <div class="table-wrap"><table class="data">
        <thead><tr><th>#</th><th></th>${cols.map((c) => `<th>${esc(c)}</th>`).join('')}<th>${esc(t('imp.problems'))}</th></tr></thead>
        <tbody>${a.rows.map((r) => {
          const bad = Object.keys(r.errors).length;
          return `<tr class="${bad ? 'bad' : ''}"><td>${r.line}</td>
            <td>${r.isNew ? `<span class="pill pill-ok">${esc(t('imp.new'))}</span>` : `<span class="pill">${esc(t('imp.update'))}</span>`}</td>
            ${cols.map((c) => `<td class="${r.errors[c] ? 'bad' : ''}" dir="auto">${esc(String(r.d[c]).slice(0, 40))}</td>`).join('')}
            <td>${esc(Object.entries(r.errors).map(([c, m]) => c + ': ' + m).join(' · '))}</td></tr>`;
        }).join('')}</tbody>
      </table></div>
      <p class="hint">${esc(t('imp.review_note'))}</p>
      <button type="button" class="btn btn-primary btn-block" id="imp-go" ${ok ? '' : 'disabled'}>${esc(t('imp.import_n', { n: a.products.length }))}</button>
      <div id="imp-result"></div>`;
    box.querySelector('#imp-go').addEventListener('click', runImport);
  }

  async function runImport(e) {
    const btn = e.currentTarget;
    const out = document.getElementById('imp-result');
    btn.disabled = true;
    btn.textContent = t('imp.importing');
    const withStock = !!(document.getElementById('imp-stock-too') || {}).checked;
    const { data, error } = await DB.client.rpc('admin_import_products', { p_rows: payloadFor(current, withStock) });
    if (error) {
      btn.disabled = false;
      btn.textContent = t('imp.import_n', { n: current.products.length });
      out.innerHTML = `<div class="alert alert-error">${esc(t('imp.failed'))}<br><small dir="ltr">${esc(error.message)}</small></div>`;
      return;
    }
    btn.textContent = t('imp.done');
    out.innerHTML = `<div class="alert alert-ok">${esc(t('imp.result', {
      created: data.created, updated: data.updated, vc: data.variants_created, vu: data.variants_updated, cats: data.categories_created }))}</div>`;
    if (window.AdminApp) { await window.AdminApp.loadCategories(); }
    if (ctx && ctx.toast) ctx.toast(t('imp.done'));
  }

  async function onPhotos(e) {
    const files = [...e.target.files];
    e.target.value = '';
    if (!files.length) return;
    const box = document.getElementById('imp-photo-report');
    box.innerHTML = `<p class="hint">${esc(t('common.loading'))}</p>`;
    let skus;
    try { skus = [...(await fetchExisting()).keys()]; } catch (ex) {
      box.innerHTML = `<div class="alert alert-error">${esc(t('common.error_generic'))}</div>`; return;
    }
    const lookup = new Map(skus.map((s) => [s.toLowerCase(), s]));
    const report = files.map((f) => ({ file: f, name: f.name, ...matchPhoto(f.name, lookup) }));
    const render = () => {
      const done = report.filter((r) => r.status === 'ok').length;
      const failed = report.filter((r) => r.error).length;
      box.innerHTML = `<p><strong>${esc(t('imp.photo_summary', { ok: done, failed, total: report.length }))}</strong></p>
        <div class="table-wrap"><table class="data"><tbody>${report.map((r) => `<tr class="${r.error ? 'bad' : ''}">
          <td dir="ltr">${esc(r.name)}</td><td dir="ltr">${esc(r.sku ? r.sku + ' #' + r.n : '')}</td>
          <td>${esc(r.error ? t(r.error) : r.status === 'ok' ? '✓' : t('admin.uploading'))}</td></tr>`).join('')}</tbody></table></div>`;
    };
    render();

    // upload 3 at a time
    const todo = report.filter((r) => !r.error);
    let i = 0;
    const worker = async () => {
      while (i < todo.length) {
        const r = todo[i++];
        try { r.path = await Photos.uploadAs(r.sku, r.file, r.n); r.status = 'uploaded'; } catch (ex) {
          console.error(ex); r.error = 'imp.photo_err_upload';
        }
        render();
      }
    };
    await Promise.all([worker(), worker(), worker()]);

    // attach to products, one call per SKU, in photo-number order
    const bySku = new Map();
    todo.filter((r) => r.path).forEach((r) => { if (!bySku.has(r.sku)) bySku.set(r.sku, []); bySku.get(r.sku).push(r); });
    for (const [sku, list] of bySku) {
      list.sort((a, b) => a.n - b.n);
      const { error } = await DB.client.rpc('admin_add_photos', { p_sku: sku, p_paths: list.map((r) => r.path) });
      list.forEach((r) => { if (error) { r.error = 'imp.photo_err_upload'; } else { r.status = 'ok'; } });
    }
    render();
  }

  window.ImportTab = { show, analyse, matchPhoto, payloadFor };
})();
