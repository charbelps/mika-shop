// Customer shop: header, product cards, home / category+search / product pages.
// The shop reads as a logged-out visitor (see db.js), so only active items are ever visible.
// Every query also filters active = true explicitly.
(function () {
  const t = (k, v) => I18n.t(k, v);
  const PAGE = 24;
  const LIST_COLS = 'sku,name_en,name_ar,price,compare_price,stock,has_variants,photos,created_at,variants(price,stock,active)';
  const $ = (s, r = document) => r.querySelector(s);

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  }

  // ---------- small cache: show the last result instantly, then refresh ----------
  const CACHE_PREFIX = 'shopcache:v1:';
  function cacheGet(key) {
    try {
      const v = JSON.parse(localStorage.getItem(CACHE_PREFIX + key));
      return v && Date.now() - v.t < 24 * 3600 * 1000 ? v.d : null;
    } catch { return null; }
  }
  function cacheSet(key, data) {
    try {
      localStorage.setItem(CACHE_PREFIX + key, JSON.stringify({ t: Date.now(), d: data }));
      const keys = Object.keys(localStorage).filter((k) => k.startsWith(CACHE_PREFIX));
      if (keys.length > 30) {
        keys.map((k) => [k, (JSON.parse(localStorage.getItem(k)) || {}).t || 0])
          .sort((a, b) => a[1] - b[1]).slice(0, keys.length - 30).forEach(([k]) => localStorage.removeItem(k));
      }
    } catch { /* storage full or blocked: just skip caching */ }
  }
  // Calls render(data) with cached data first (if any), then again with fresh data if it changed.
  async function cached(key, fetcher, render) {
    const old = cacheGet(key);
    if (old) render(old, true);
    try {
      const fresh = await fetcher();
      if (!old || JSON.stringify(old) !== JSON.stringify(fresh)) render(fresh, false);
      cacheSet(key, fresh);
    } catch (ex) {
      console.error(ex);
      if (!old) throw ex;
    }
  }

  // ---------- settings & product helpers ----------
  let S = {};
  const shopName = () => (I18n.lang === 'ar' ? (S.shop_name_ar || S.shop_name_en) : (S.shop_name_en || S.shop_name_ar)) || t('shop.default_name');
  const money = (n) => I18n.money(n, S.currency);
  // <bdi> keeps each amount in one piece inside Arabic (right-to-left) text.
  const moneyHtml = (n) => `<bdi>${esc(money(n))}</bdi>`;

  function activeVariants(p) { return (p.variants || []).filter((v) => v.active); }
  function inStock(p) {
    return p.has_variants ? activeVariants(p).some((v) => v.stock > 0) : p.stock > 0;
  }
  function priceRange(p) {
    if (!p.has_variants) return { min: Number(p.price), max: Number(p.price) };
    const prices = activeVariants(p).map((v) => Number(v.price != null ? v.price : p.price));
    if (!prices.length) return { min: Number(p.price), max: Number(p.price) };
    return { min: Math.min(...prices), max: Math.max(...prices) };
  }
  function priceHtml(p) {
    const r = priceRange(p);
    const was = p.compare_price != null && Number(p.compare_price) > r.min ? `<span class="was">${moneyHtml((p.compare_price))}</span>` : '';
    const from = r.min !== r.max ? `<span class="from">${esc(t('shop.from'))} </span>` : '';
    return `<div class="price">${from}${moneyHtml((r.min))}${was}</div>`;
  }
  function photoImg(path, alt, thumb, eager) {
    if (!path) return `<div class="no-photo" aria-hidden="true">🛍️</div>`;
    const src = thumb ? DB.thumbUrl(path) : DB.photoUrl(path);
    return `<img src="${esc(src)}" alt="${esc(alt)}" ${eager ? '' : 'loading="lazy"'} decoding="async">`;
  }
  function cardHtml(p) {
    const name = I18n.pick(p, 'name');
    const out = !inStock(p);
    const sale = !out && p.compare_price != null && Number(p.compare_price) > priceRange(p).min;
    return `<a class="card${out ? ' out' : ''}" href="product.html?sku=${encodeURIComponent(p.sku)}">
      <div class="img">${photoImg(p.photos && p.photos[0], name, true)}
        ${out ? `<span class="badge badge-out">${esc(t('shop.out_of_stock'))}</span>` : sale ? `<span class="badge badge-sale">${esc(t('shop.sale'))}</span>` : ''}
      </div>
      <div class="body"><div class="name">${esc(name)}</div>${priceHtml(p)}</div>
    </a>`;
  }
  function skeletonGrid(n) {
    return Array.from({ length: n }, () => '<div class="skeleton" style="aspect-ratio:3/4"></div>').join('');
  }
  function waLink(text) {
    const digits = String(S.whatsapp_number || '').replace(/\D/g, '');
    return digits ? `https://wa.me/${digits}?text=${encodeURIComponent(text)}` : '';
  }

  // ---------- header & footer ----------
  function renderChrome() {
    const h = document.getElementById('site-header');
    if (h) {
      h.className = 'site-header';
      const q = new URLSearchParams(location.search).get('q') || '';
      h.innerHTML = `<div class="wrap">
        <div class="bar">
          <a class="brand" href="index.html" data-shop-name></a>
          <button type="button" class="icon-btn" data-lang-toggle data-i18n="common.lang_toggle"></button>
          <a class="icon-btn" href="cart.html" data-i18n-aria-label="shop.cart">🛒<span class="cart-count" hidden></span></a>
        </div>
        <div class="search-row">
          <form action="category.html" role="search">
            <input type="search" name="q" value="${esc(q)}" data-i18n-placeholder="shop.search_placeholder" data-i18n-aria-label="common.search" enterkeyhint="search">
            <button class="btn btn-small" data-i18n="common.search"></button>
          </form>
        </div>
      </div>`;
    }
    const f = document.getElementById('site-footer');
    if (f) {
      f.className = 'site-footer';
      f.innerHTML = `<div class="wrap"><p data-shop-name></p><p><a href="track.html" data-i18n="trk.footer_link"></a></p><p id="footer-wa"></p></div>`;
    }
  }
  function updateCartCount() {
    const el = $('.cart-count');
    if (!el || !window.Cart) return;
    const n = window.Cart.count();
    el.textContent = n > 99 ? '99+' : n;
    el.hidden = n === 0;
  }

  async function boot() {
    renderChrome();
    await I18n.ready;
    I18n.apply(document);
    try { S = await DB.settings(); } catch (ex) { console.error(ex); S = {}; }
    document.querySelectorAll('[data-shop-name]').forEach((el) => { el.textContent = shopName(); });
    const wa = waLink(t('shop.wa_hello'));
    if (wa && $('#footer-wa')) $('#footer-wa').innerHTML = `<a href="${esc(wa)}" target="_blank" rel="noopener">${esc(t('shop.contact_whatsapp'))}</a>`;
    updateCartCount();
    window.addEventListener('cart:change', updateCartCount);
    window.addEventListener('storage', updateCartCount); // other tabs
  }

  function setTitle(part) {
    document.title = part ? `${part} · ${shopName()}` : shopName();
  }

  // ---------- categories ----------
  let catsPromise = null;
  function allCategories() {
    catsPromise ||= DB.client.from('categories').select('id,name_en,name_ar,parent_id,sort')
      .eq('active', true).order('sort').order('name_en')
      .then(({ data, error }) => { if (error) throw error; return data; });
    return catsPromise;
  }
  function descendants(cats, id) {
    const ids = new Set([id]);
    let grew = true;
    while (grew) {
      grew = false;
      cats.forEach((c) => { if (c.parent_id && ids.has(c.parent_id) && !ids.has(c.id)) { ids.add(c.id); grew = true; } });
    }
    return [...ids];
  }

  // ---------- pages ----------
  async function initHome() {
    await boot();
    setTitle('');
    const catBox = $('#home-categories');
    const grid = $('#home-featured');
    grid.innerHTML = skeletonGrid(4);

    allCategories().then((cats) => {
      const top = cats.filter((c) => !c.parent_id);
      catBox.innerHTML = top.length
        ? top.map((c) => `<a class="cat-tile" href="category.html?id=${c.id}">${esc(I18n.pick(c, 'name'))}</a>`).join('')
        : `<p class="empty">${esc(t('shop.no_categories'))}</p>`;
    }).catch(() => { catBox.innerHTML = `<p class="empty">${esc(t('common.error_generic'))}</p>`; });

    await cached('home-featured', async () => {
      const f = await DB.client.from('products').select(LIST_COLS).eq('active', true).eq('featured', true)
        .order('created_at', { ascending: false }).limit(12);
      if (f.error) throw f.error;
      if (f.data.length) return { title: 'featured', items: f.data };
      const n = await DB.client.from('products').select(LIST_COLS).eq('active', true)
        .order('created_at', { ascending: false }).limit(12);
      if (n.error) throw n.error;
      return { title: 'newest', items: n.data };
    }, (d) => {
      $('#home-featured-title').textContent = t(d.title === 'featured' ? 'shop.featured' : 'shop.newest');
      grid.innerHTML = d.items.length ? d.items.map(cardHtml).join('') : `<p class="empty">${esc(t('shop.no_products'))}</p>`;
    }).catch(() => { grid.innerHTML = `<p class="empty">${esc(t('common.error_generic'))}</p>`; });
  }

  async function initCategory() {
    await boot();
    const params = new URLSearchParams(location.search);
    const id = parseInt(params.get('id'), 10);
    const q = (params.get('q') || '').trim();
    const page = Math.max(0, (parseInt(params.get('p'), 10) || 1) - 1);
    const grid = $('#cat-grid');
    grid.innerHTML = skeletonGrid(6);
    let cats = [];
    try { cats = await allCategories(); } catch (ex) { console.error(ex); }

    let ids = null;
    if (q) {
      $('#cat-title').textContent = t('shop.search_results', { q });
      setTitle(t('shop.search_results', { q }));
    } else if (id) {
      const cat = cats.find((c) => c.id === id);
      if (!cat) {
        $('#cat-title').textContent = t('shop.not_found_category');
        grid.innerHTML = `<p class="empty"><a href="index.html">${esc(t('shop.back_home'))}</a></p>`;
        return;
      }
      $('#cat-title').textContent = I18n.pick(cat, 'name');
      setTitle(I18n.pick(cat, 'name'));
      const parent = cat.parent_id && cats.find((c) => c.id === cat.parent_id);
      $('#crumbs').innerHTML = `<a href="index.html">${esc(t('shop.home'))}</a>`
        + (parent ? ` › <a href="category.html?id=${parent.id}">${esc(I18n.pick(parent, 'name'))}</a>` : '');
      const kids = cats.filter((c) => c.parent_id === id);
      const siblings = parent ? cats.filter((c) => c.parent_id === parent.id) : [];
      const chips = kids.length ? [cat, ...kids] : siblings.length ? [parent, ...siblings] : [];
      $('#cat-chips').innerHTML = chips.map((c, i) => `<a class="chip" href="category.html?id=${c.id}" ${c.id === id ? 'aria-current="page"' : ''}>${esc(i === 0 ? t('common.all') : I18n.pick(c, 'name'))}</a>`).join('');
      ids = descendants(cats, id);
    } else {
      $('#cat-title').textContent = t('shop.all_products');
      setTitle(t('shop.all_products'));
    }

    const key = `list:${q ? 'q=' + q.toLowerCase() : 'c=' + (id || 'all')}:p${page}`;
    await cached(key, async () => {
      let query = DB.client.from('products').select(LIST_COLS, { count: 'exact' }).eq('active', true)
        .order('created_at', { ascending: false }).range(page * PAGE, page * PAGE + PAGE - 1);
      if (ids) query = query.in('category_id', ids);
      if (q) {
        const s = q.replace(/[",()\\*%]/g, ' ').trim();
        query = query.or(`name_en.ilike."*${s}*",name_ar.ilike."*${s}*",search_keywords.ilike."*${s}*"`);
      }
      const { data, error, count } = await query;
      if (error) throw error;
      return { items: data, count: count || 0 };
    }, (d) => {
      grid.innerHTML = d.items.length ? d.items.map(cardHtml).join('')
        : `<p class="empty" style="grid-column:1/-1">${esc(t(q ? 'shop.no_results' : 'shop.no_products'))}</p>`;
      $('#cat-count').textContent = d.count ? t('shop.items_count', { n: d.count }) : '';
      const pages = Math.ceil(d.count / PAGE);
      const pager = $('#cat-pager');
      pager.hidden = pages <= 1;
      if (pages > 1) {
        const link = (n) => { const u = new URLSearchParams(location.search); u.set('p', n); return '?' + u.toString(); };
        pager.innerHTML = `${page > 0 ? `<a class="btn btn-small" href="${link(page)}">${esc(t('shop.prev'))}</a>` : ''}
          <span>${esc(t('shop.page', { n: page + 1, total: pages }))}</span>
          ${page < pages - 1 ? `<a class="btn btn-small" href="${link(page + 2)}">${esc(t('shop.next'))}</a>` : ''}`;
      }
    }).catch(() => { grid.innerHTML = `<p class="empty">${esc(t('common.error_generic'))}</p>`; });
  }

  async function initProduct() {
    await boot();
    const sku = new URLSearchParams(location.search).get('sku') || '';
    const box = $('#product');
    const { data: p, error } = await DB.client.from('products')
      .select('sku,name_en,name_ar,desc_en,desc_ar,measurements_en,measurements_ar,price,compare_price,stock,has_variants,photos,category_id,variants(id,label_en,label_ar,price,stock,active,sort)')
      .eq('sku', sku).eq('active', true).maybeSingle();
    if (error || !p) {
      setTitle(t('shop.not_found_product'));
      box.innerHTML = `<div class="empty"><h1>${esc(t('shop.not_found_product'))}</h1><a class="btn" href="index.html">${esc(t('shop.back_home'))}</a></div>`;
      return;
    }
    const name = I18n.pick(p, 'name');
    setTitle(name);
    const variants = activeVariants(p).sort((a, b) => a.sort - b.sort || a.id - b.id);
    const photos = p.photos || [];
    const cats = await allCategories().catch(() => []);
    const cat = cats.find((c) => c.id === p.category_id);

    $('#crumbs').innerHTML = `<a href="index.html">${esc(t('shop.home'))}</a>`
      + (cat ? ` › <a href="category.html?id=${cat.id}">${esc(I18n.pick(cat, 'name'))}</a>` : '');

    box.innerHTML = `<div class="product">
      <div class="gallery">
        <div class="main" id="g-main" tabindex="0" aria-label="${esc(t('shop.photos'))}">
          ${photos.length ? photos.map((ph, i) => photoImg(ph, name, false, i === 0)).join('') : photoImg(null)}
        </div>
        ${photos.length > 1 ? `<div class="dots" aria-hidden="true">${photos.map((_, i) => `<span class="${i ? '' : 'on'}"></span>`).join('')}</div>
        <div class="thumbs">${photos.map((ph, i) => `<button type="button" data-i="${i}" aria-current="${i === 0}" aria-label="${esc(t('shop.photo_n', { n: i + 1 }))}"><img src="${esc(DB.thumbUrl(ph))}" alt="" loading="lazy"></button>`).join('')}</div>` : ''}
      </div>
      <div class="info">
        <h1>${esc(name)}</h1>
        <div id="pp-price"></div>
        ${variants.length ? `<span class="label">${esc(t('shop.choose_option'))}</span>
          <div class="options" id="pp-options">${variants.map((v) => `<button type="button" class="opt" data-id="${v.id}" aria-pressed="false" ${v.stock > 0 ? '' : 'disabled'}>${esc(I18n.pick(v, 'label'))}</button>`).join('')}</div>` : ''}
        <div class="stock-line" id="pp-stock"></div>
        <div class="buy">
          <div class="buy-row">
            <div class="qty"><button type="button" id="q-minus" aria-label="−">−</button><input id="q" type="number" inputmode="numeric" min="1" value="1" aria-label="${esc(t('shop.qty'))}"><button type="button" id="q-plus" aria-label="+">+</button></div>
            <button type="button" class="btn btn-primary" id="pp-add">${esc(t('shop.add_to_cart'))}</button>
          </div>
          <a class="btn btn-wa btn-block" id="pp-wa" target="_blank" rel="noopener" hidden>${esc(t('shop.ask_whatsapp'))}</a>
          <div class="share-row">
            <a class="btn" id="pp-share-wa" target="_blank" rel="noopener">${esc(t('shop.share_whatsapp'))}</a>
            <button type="button" class="btn" id="pp-share" hidden>↗ ${esc(t('shop.share'))}</button>
          </div>
        </div>
        ${I18n.pick(p, 'measurements') ? `<div class="measure"><span class="label">📏 ${esc(t('shop.measurements'))}</span><span dir="auto">${esc(I18n.pick(p, 'measurements'))}</span></div>` : ''}
        <div class="desc">${esc(I18n.pick(p, 'desc'))}</div>
        <p class="muted" style="font-size:.8rem" dir="ltr">SKU: ${esc(p.sku)}</p>
      </div>
    </div>`;

    // gallery: swipe (scroll-snap) + dots + thumbnails
    const main = $('#g-main');
    const setActive = (i) => {
      document.querySelectorAll('.dots span').forEach((d, j) => d.classList.toggle('on', i === j));
      document.querySelectorAll('.thumbs button').forEach((b, j) => b.setAttribute('aria-current', String(i === j)));
    };
    main.addEventListener('scroll', () => {
      const i = Math.round(Math.abs(main.scrollLeft) / main.clientWidth);
      setActive(i);
    }, { passive: true });
    document.querySelectorAll('.thumbs button').forEach((b) => b.addEventListener('click', () => {
      const i = Number(b.dataset.i);
      main.children[i].scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' });
      setActive(i);
    }));

    // options, price, stock, quantity
    let selected = variants.filter((v) => v.stock > 0).length === 1 ? variants.find((v) => v.stock > 0) : null;
    const qty = $('#q');
    function maxQty() { return p.has_variants ? (selected ? selected.stock : 0) : p.stock; }
    function update() {
      document.querySelectorAll('.opt').forEach((b) => b.setAttribute('aria-pressed', String(!!selected && Number(b.dataset.id) === selected.id)));
      $('#pp-price').innerHTML = selected
        ? `<div class="price">${moneyHtml((selected.price != null ? selected.price : p.price))}${p.compare_price != null && Number(p.compare_price) > Number(selected.price != null ? selected.price : p.price) ? `<span class="was">${moneyHtml((p.compare_price))}</span>` : ''}</div>`
        : priceHtml(p);
      const available = inStock(p);
      const stockEl = $('#pp-stock');
      const add = $('#pp-add');
      if (!available) {
        stockEl.textContent = t('shop.out_of_stock');
        stockEl.className = 'stock-line out';
        add.disabled = true;
      } else if (p.has_variants && !selected) {
        stockEl.textContent = t('shop.pick_option');
        stockEl.className = 'stock-line';
        add.disabled = true;
      } else {
        stockEl.textContent = t('shop.in_stock');
        stockEl.className = 'stock-line';
        add.disabled = !window.Cart;
      }
      const m = Math.max(1, maxQty());
      qty.max = m;
      if (Number(qty.value) > m) qty.value = m;
    }
    document.querySelectorAll('.opt').forEach((b) => b.addEventListener('click', () => {
      selected = variants.find((v) => v.id === Number(b.dataset.id));
      update();
    }));
    $('#q-minus').addEventListener('click', () => { qty.value = Math.max(1, Number(qty.value) - 1); });
    $('#q-plus').addEventListener('click', () => { qty.value = Math.min(Math.max(1, maxQty()), Number(qty.value) + 1); });
    qty.addEventListener('change', () => { qty.value = Math.min(Math.max(1, maxQty()), Math.max(1, parseInt(qty.value, 10) || 1)); });
    update();

    $('#pp-add').addEventListener('click', () => {
      if (!window.Cart) return;
      window.Cart.add({
        sku: p.sku, variant_id: selected ? selected.id : null, qty: Number(qty.value) || 1,
        name_en: p.name_en, name_ar: p.name_ar,
        label_en: selected ? selected.label_en : '', label_ar: selected ? selected.label_ar : '',
        price: Number(selected && selected.price != null ? selected.price : p.price),
        photo: photos[0] || '', max: maxQty(),
      });
      toast(t('shop.added_to_cart'), 'cart.html', t('shop.view_cart'));
    });

    const wa = waLink(t('shop.wa_ask', { name, sku: p.sku, url: location.href }));
    if (wa) { const a = $('#pp-wa'); a.href = wa; a.hidden = false; }

    // Share: WhatsApp link (customer picks the contact) + the phone's own share menu when it has one.
    const shareUrl = `${location.origin}${location.pathname}?sku=${encodeURIComponent(p.sku)}`;
    const shareText = t('shop.share_text', { name });
    $('#pp-share-wa').href = `https://wa.me/?text=${encodeURIComponent(shareText + '\n' + shareUrl)}`;
    if (navigator.share) {
      const btn = $('#pp-share');
      btn.hidden = false;
      btn.addEventListener('click', async () => {
        try {
          await navigator.share({ title: name, text: shareText, url: shareUrl });
        } catch (ex) {
          if (ex && ex.name !== 'AbortError') window.open($('#pp-share-wa').href, '_blank', 'noopener');
        }
      });
    }
  }

  let toastTimer;
  function toast(msg, href, linkText, isError) {
    let el = $('.toast');
    if (!el) { el = document.createElement('div'); el.className = 'toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.innerHTML = `<span>${esc(msg)}</span>${href ? `<a href="${esc(href)}">${esc(linkText)}</a>` : ''}`;
    el.classList.toggle('error', !!isError);
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 3500);
  }

  window.Shop = {
    boot, initHome, initCategory, initProduct, toast, esc, money,
    settings: () => S, shopName, setTitle, photoImg, waLink, allCategories,
  };
})();
