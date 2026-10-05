// Edge Function: new-order-alert
// Called by the database (trigger orders_notify_new, via pg_net) with { "order_id": 123 }.
// Reads the order itself with the service key (the request carries only the id, so nobody
// can make it send made-up content), claims it (orders.alert_sent_at) so every order is
// alerted at most once, and sends a Telegram message to each chat in TELEGRAM_CHAT_ID.
//
// Secrets (Supabase → Edge Functions → Secrets), set by Charbel, never in Git:
//   TELEGRAM_BOT_TOKEN   token from @BotFather
//   TELEGRAM_CHAT_ID     one chat id, or several separated by commas
// Provided automatically by Supabase: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
//
// Deployed with --no-verify-jwt (the database calls it without a user token).

import { buildMessage } from './message.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const BOT_TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const CHAT_IDS = (Deno.env.get('TELEGRAM_CHAT_ID') ?? '').split(',').map((s) => s.trim()).filter(Boolean);

const db = (path: string, init: RequestInit = {}) =>
  fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      ...(init.headers ?? {}),
    },
  });

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return reply(405, { error: 'POST only' });

  let orderId: number;
  try {
    const body = await req.json();
    orderId = Number(body?.order_id ?? body?.record?.id);
  } catch {
    return reply(400, { error: 'bad json' });
  }
  if (!Number.isInteger(orderId) || orderId <= 0) return reply(400, { error: 'order_id required' });

  if (!BOT_TOKEN || !CHAT_IDS.length) {
    // Not configured yet: do nothing and leave the order unclaimed.
    return reply(200, { skipped: 'telegram not configured' });
  }

  // Claim the order: only one call can switch alert_sent_at from empty to now.
  const claim = await db(`orders?id=eq.${orderId}&alert_sent_at=is.null&select=id`, {
    method: 'PATCH',
    headers: { Prefer: 'return=representation' },
    body: JSON.stringify({ alert_sent_at: new Date().toISOString() }),
  });
  if (!claim.ok) return reply(500, { error: 'claim failed', status: claim.status });
  const claimed = await claim.json();
  if (!claimed.length) return reply(200, { skipped: 'already sent or no such order' });

  const unclaim = () => db(`orders?id=eq.${orderId}`, { method: 'PATCH', body: JSON.stringify({ alert_sent_at: null }) });

  try {
    const [oRes, sRes] = await Promise.all([
      db(`orders?id=eq.${orderId}&select=*,order_items(qty,name_en,label,line_total)`),
      db(`settings?key=eq.currency&select=value`),
    ]);
    const [order] = await oRes.json();
    const [cur] = await sRes.json();
    if (!order) throw new Error('order not found');
    const text = buildMessage(order, order.order_items ?? [], cur?.value ?? '');

    let sent = 0;
    for (const chat of CHAT_IDS) {
      const t = await fetch(`https://api.telegram.org/bot${BOT_TOKEN}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
      });
      if (t.ok) sent++;
      else console.error('telegram error', chat, t.status, await t.text());
    }
    if (!sent) {
      await unclaim();
      return reply(502, { error: 'telegram send failed' });
    }
    return reply(200, { sent, order_no: order.order_no });
  } catch (e) {
    console.error(e);
    await unclaim();
    return reply(500, { error: 'alert failed' });
  }
});
