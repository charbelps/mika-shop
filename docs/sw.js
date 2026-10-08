const DEFAULT_LANG = 'en';

self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    if (!event.data) {
      console.error('Order notification had no payload');
      return;
    }
    let push;
    try {
      push = event.data.json();
    } catch {
      console.error('Order notification payload was not valid JSON');
      return;
    }
    if (!push || typeof push !== 'object' || !push.en || !push.ar) {
      console.error('Order notification payload is missing its translations');
      return;
    }

    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (windows.some((client) =>
      client.visibilityState === 'visible' && new URL(client.url).pathname.endsWith('/staff/prep.html')
    )) return;

    const lang = push.lang === 'ar' ? 'ar' : DEFAULT_LANG;
    const message = push[lang] || push.en || {};
    if (typeof message.title !== 'string' || typeof message.body !== 'string') {
      console.error('Order notification payload has no displayable message');
      return;
    }
    await self.registration.showNotification(message.title, {
      body: message.body,
      tag: push.tag || 'mika-shop-order',
      data: { url: push.url || 'staff/prep.html' },
      requireInteraction: true,
    });
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(openFromNotification(event.notification.data?.url));
});

async function openFromNotification(url) {
  const scope = self.registration.scope;
  let target = new URL(url || 'staff/prep.html', scope);
  if (target.origin !== self.location.origin || !target.href.startsWith(scope)) target = new URL('staff/prep.html', scope);
  const orderId = Number(target.searchParams.get('open')) || null;
  // An Orders screen of this shop is already open: bring it forward and let it show the order
  // (it never leaves the page, so nothing typed there is lost). Other tabs are never touched.
  const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  const orders = windows.find((client) => {
    const u = new URL(client.url);
    return u.href.startsWith(scope) && u.pathname.endsWith('/staff/prep.html');
  });
  if (orders) {
    if (orderId) orders.postMessage({ type: 'open-order', id: orderId });
    try { return await orders.focus(); } catch { /* some phones refuse focus: open a tab instead */ }
  }
  return self.clients.openWindow(target.href);
}
