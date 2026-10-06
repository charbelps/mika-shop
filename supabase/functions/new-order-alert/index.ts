// Edge Function: new-order-alert (phone notifications; Telegram dropped 6 Oct 2026, 12b #21)
//
// 1) Called by the database (trigger orders_notify_new, via pg_net) with { "order_id": 123 }.
//    Reads the order itself with the service key (the request carries only the id, so nobody
//    can make it send made-up content), claims it (orders.alert_sent_at) so every order is
//    notified at most once, and sends a web push to every device in push_subscriptions that
//    belongs to an active ADMIN or OWNER. Devices the push service says are gone are removed.
// 2) { "action": "test" } with a staff login (Authorization: Bearer <their token>): sends a test
//    notification to that person's own devices ("Send a test" button on the Orders screen).
//
// Secrets (Edge Functions → Secrets), never in Git:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT  (the notification key pair)
// Provided automatically: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
// Deployed with --no-verify-jwt (the database calls it without a login); the test action
// checks the login itself.

import webpush from 'npm:web-push@3.6.7';
import { createClient } from 'npm:@supabase/supabase-js@2.117.2';
import { buildPush, type Push } from './message.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const VAPID_PUBLIC = Deno.env.get('VAPID_PUBLIC_KEY') ?? '';
const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY') ?? '';
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') ?? 'https://charbelps.github.io/mika-shop/';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

type Sub = { id: number; endpoint: string; p256dh: string; auth: string; lang: 'en' | 'ar' };

// sends one notification to each device; removes devices that no longer exist
async function sendAll(db: ReturnType<typeof createClient>, subs: Sub[], push: Push) {
  let sent = 0;
  for (const s of subs) {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify({ ...push, lang: s.lang }),
        { TTL: 24 * 3600, urgency: 'high' },
      );
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {
        const { error } = await db.from('push_subscriptions').delete().eq('id', s.id);
        if (error) console.error('could not remove expired push subscription', s.id, error.message);
      } else {
        console.error('push failed', code, (e as Error).message);
      }
    }
  }
  return sent;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return reply(405, { error: 'POST only' });
  if (!SUPABASE_URL || !SERVICE_KEY) {
    console.error('Supabase Edge Function environment is incomplete');
    return reply(500, { error: 'notification service unavailable' });
  }
  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply(400, { error: 'bad json' }); }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return reply(400, { error: 'bad json' });

  // ---------- test notification to the caller's own devices ----------
  if (body?.action === 'test') {
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: who, error: authError } = await db.auth.getUser(token);
    if (authError) return reply(401, { error: 'NOT_LOGGED_IN' });
    if (!who?.user) return reply(401, { error: 'NOT_LOGGED_IN' });
    const { data: me, error: staffError } = await db.from('staff')
      .select('active,role').eq('user_id', who.user.id).maybeSingle();
    if (staffError) {
      console.error('could not check staff access', staffError.message);
      return reply(500, { error: 'notification service unavailable' });
    }
    if (!me?.active || !['ADMIN', 'OWNER'].includes(me.role)) return reply(403, { error: 'ONLY_STAFF' });
    if (!VAPID_PUBLIC || !VAPID_PRIVATE) return reply(503, { error: 'NOTIFICATIONS_NOT_CONFIGURED' });
    webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
    const { data: subs, error: subError } = await db.from('push_subscriptions')
      .select('id,endpoint,p256dh,auth,lang').eq('user_id', who.user.id);
    if (subError) {
      console.error('could not read test push subscriptions', subError.message);
      return reply(500, { error: 'notification service unavailable' });
    }
    const push: Push = {
      tag: 'test', url: 'staff/prep.html', lang: 'en',
      en: { title: '🔔 Test notification', body: 'Order notifications work on this device.' },
      ar: { title: '🔔 إشعار تجريبي', body: 'إشعارات الطلبات تعمل على هذا الجهاز.' },
    };
    const sent = await sendAll(db, (subs ?? []) as Sub[], push);
    return reply(200, { sent });
  }

  // ---------- new order (from the database) ----------
  const orderId = Number(body?.order_id ?? (body?.record as { id?: number } | undefined)?.id);
  if (!Number.isInteger(orderId) || orderId <= 0) return reply(400, { error: 'order_id required' });
  if (!VAPID_PUBLIC || !VAPID_PRIVATE) return reply(200, { skipped: 'notifications not configured' });
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

  // who gets it: devices of active ADMIN / OWNER staff
  const { data: staff, error: staffError } = await db.from('staff').select('user_id').eq('active', true).in('role', ['ADMIN', 'OWNER']);
  if (staffError) {
    console.error('could not find notification recipients', staffError.message);
    return reply(500, { error: 'notification service unavailable' });
  }
  const ids = (staff ?? []).map((s: { user_id: string }) => s.user_id);
  const { data: subs, error: subsError } = ids.length
    ? await db.from('push_subscriptions').select('id,endpoint,p256dh,auth,lang').in('user_id', ids)
    : { data: [] };
  if (subsError) {
    console.error('could not load notification subscriptions', subsError.message);
    return reply(500, { error: 'notification service unavailable' });
  }
  if (!subs?.length) return reply(200, { skipped: 'no device has notifications on' });

  // claim the order: only one call can switch alert_sent_at from empty to now
  const { data: claimed, error: cErr } = await db.from('orders').update({ alert_sent_at: new Date().toISOString() })
    .eq('id', orderId).is('alert_sent_at', null).select('id');
  if (cErr) return reply(500, { error: 'claim failed' });
  if (!claimed?.length) return reply(200, { skipped: 'already sent or no such order' });
  const unclaim = async () => {
    const { error } = await db.from('orders').update({ alert_sent_at: null }).eq('id', orderId);
    if (error) console.error('could not release order alert claim', orderId, error.message);
  };

  try {
    const [{ data: order, error: orderError }, { data: cur, error: currencyError }] = await Promise.all([
      db.from('orders').select('id,order_no,name,district,total,payment_method,source,is_first_order,order_items(qty)').eq('id', orderId).single(),
      db.from('settings').select('value').eq('key', 'currency').maybeSingle(),
    ]);
    if (orderError) throw orderError;
    if (currencyError) throw currencyError;
    if (!order) throw new Error('order not found');
    const sent = await sendAll(db, subs as Sub[], buildPush(order, order.order_items ?? [], cur?.value ?? ''));
    if (!sent) { await unclaim(); return reply(502, { error: 'no notification delivered' }); }
    return reply(200, { sent, order_no: order.order_no });
  } catch (e) {
    console.error(e);
    await unclaim();
    return reply(500, { error: 'alert failed' });
  }
});
