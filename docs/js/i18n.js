// English / Arabic text for every page. All visible text lives in docs/i18n/en.json and ar.json.
// In HTML:  <span data-i18n="staff.sign_in"></span>   <input data-i18n-placeholder="...">
// In JS:    I18n.t('staff.hello', { name })   I18n.pick(product, 'name')   I18n.money(12.5, 'USD')
(function () {
  const SUPPORTED = ['en', 'ar'];
  const base = new URL('../i18n/', document.currentScript.src); // docs/js/ -> docs/i18n/

  function storedLang() {
    try { return localStorage.getItem('lang'); } catch { return null; }
  }

  let lang = storedLang();
  if (!SUPPORTED.includes(lang)) {
    lang = (navigator.language || '').toLowerCase().startsWith('ar') ? 'ar' : 'en';
  }
  const html = document.documentElement;
  html.lang = lang;
  html.dir = lang === 'ar' ? 'rtl' : 'ltr';

  let dict = {};

  function t(key, vars) {
    let s = key.split('.').reduce((o, k) => (o == null ? o : o[k]), dict);
    if (typeof s !== 'string') return key;
    if (vars) s = s.replace(/\{(\w+)\}/g, (m, k) => (vars[k] != null ? vars[k] : m));
    return s;
  }

  function apply(root) {
    (root || document).querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
    (root || document).querySelectorAll('[data-i18n-placeholder]').forEach((el) => { el.placeholder = t(el.dataset.i18nPlaceholder); });
    (root || document).querySelectorAll('[data-i18n-aria-label]').forEach((el) => { el.setAttribute('aria-label', t(el.dataset.i18nAriaLabel)); });
    (root || document).querySelectorAll('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); });
  }

  const ready = fetch(new URL(lang + '.json', base))
    .then((r) => r.json())
    .then((d) => {
      dict = d;
      const go = () => {
        apply(document);
        document.querySelectorAll('[data-lang-toggle]').forEach((b) => {
          b.addEventListener('click', () => window.I18n.toggle());
        });
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go);
      else go();
      return dict;
    });

  function setLang(l) {
    try { localStorage.setItem('lang', l); } catch { /* private mode: language just won't be remembered */ }
    location.reload();
  }

  // Bilingual field with fallback to English: pick(row, 'name') -> row.name_ar or row.name_en.
  function pick(row, field) {
    if (!row) return '';
    const v = row[field + '_' + lang];
    return v != null && String(v).trim() !== '' ? v : (row[field + '_en'] || '');
  }

  // Money in the shop currency (from settings). Western digits in both languages.
  // If the currency isn't set yet, a "¤" placeholder is shown.
  function money(amount, currency) {
    const n = Number(amount || 0);
    const num = n.toLocaleString('en-US', { minimumFractionDigits: n % 1 ? 2 : 0, maximumFractionDigits: 2 });
    const cur = (currency || '').trim() || '¤';
    return lang === 'ar' ? `${num} ${cur}` : `${cur} ${num}`;
  }

  window.I18n = {
    get lang() { return lang; },
    ready, t, apply, pick, money, setLang,
    toggle() { setLang(lang === 'ar' ? 'en' : 'ar'); },
  };
})();
