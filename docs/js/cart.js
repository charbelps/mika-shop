// Cart, kept in this browser's localStorage. Prices here are for DISPLAY only:
// place_order takes every price from the database and ignores what the browser sends.
// Line: { sku, variant_id, qty, name_en, name_ar, label_en, label_ar, price, photo, max }
(function () {
  const KEY = 'cart:v1';
  let memory = []; // fallback when localStorage is blocked (private mode)

  function read() {
    try {
      const v = JSON.parse(localStorage.getItem(KEY));
      return Array.isArray(v) ? v : [];
    } catch { return memory; }
  }
  function write(lines) {
    memory = lines;
    try { localStorage.setItem(KEY, JSON.stringify(lines)); } catch { /* memory only */ }
    window.dispatchEvent(new CustomEvent('cart:change'));
  }
  const same = (a, b) => a.sku === b.sku && (a.variant_id || null) === (b.variant_id || null);
  const cap = (qty, max) => Math.max(1, Math.min(Math.floor(qty) || 1, max > 0 ? max : 99, 99));

  const Cart = {
    items: read,
    count() { return read().reduce((s, l) => s + l.qty, 0); },
    subtotal() { return read().reduce((s, l) => s + l.qty * Number(l.price || 0), 0); },

    add(item) {
      const lines = read();
      const found = lines.find((l) => same(l, item));
      if (found) {
        Object.assign(found, item, { qty: cap(found.qty + (item.qty || 1), item.max) });
      } else {
        lines.push({ ...item, variant_id: item.variant_id || null, qty: cap(item.qty || 1, item.max) });
      }
      write(lines);
    },
    setQty(sku, variantId, qty) {
      const lines = read();
      const l = lines.find((x) => same(x, { sku, variant_id: variantId }));
      if (l) { l.qty = cap(qty, l.max); write(lines); }
    },
    remove(sku, variantId) {
      write(read().filter((x) => !same(x, { sku, variant_id: variantId })));
    },
    clear() { write([]); },

    // Re-reads current names, prices and stock from the database (as a logged-out visitor).
    // Returns { lines, changes: [{ line, kind: 'gone'|'out'|'price'|'qty' }] } and saves the
    // updated cart. Unavailable lines are kept but flagged (line.unavailable = true).
    async refresh() {
      const lines = read();
      if (!lines.length) return { lines, changes: [] };
      const skus = [...new Set(lines.map((l) => l.sku))];
      const { data, error } = await DB.client.from('products')
        .select('sku,name_en,name_ar,price,stock,has_variants,photos,active,variants(id,label_en,label_ar,price,stock,active)')
        .in('sku', skus).eq('active', true);
      if (error) throw error;
      const changes = [];
      lines.forEach((l) => {
        const p = data.find((x) => x.sku === l.sku);
        const v = p && l.variant_id ? (p.variants || []).find((x) => x.id === l.variant_id && x.active) : null;
        if (!p || (l.variant_id && !v) || (!l.variant_id && p.has_variants)) {
          l.unavailable = true; changes.push({ line: l, kind: 'gone' }); return;
        }
        const stock = v ? v.stock : p.stock;
        const price = Number(v && v.price != null ? v.price : p.price);
        Object.assign(l, { name_en: p.name_en, name_ar: p.name_ar, photo: (p.photos || [])[0] || '', max: stock });
        if (v) Object.assign(l, { label_en: v.label_en, label_ar: v.label_ar });
        if (stock <= 0) { l.unavailable = true; changes.push({ line: l, kind: 'out' }); return; }
        l.unavailable = false;
        if (Number(l.price) !== price) { changes.push({ line: l, kind: 'price', old: Number(l.price) }); l.price = price; }
        if (l.qty > stock) { l.qty = stock; changes.push({ line: l, kind: 'qty' }); }
      });
      write(lines);
      return { lines, changes };
    },
  };

  window.Cart = Cart;
})();
