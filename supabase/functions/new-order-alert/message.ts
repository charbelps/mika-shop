// Builds the phone notification for a new order (web push; Telegram was dropped 6 Oct 2026).
// Short, because phones cut long notifications: the order number, what to collect, where.
// English and Arabic are both sent; the phone shows the one matching its language.

export interface OrderItem {
  qty: number;
}

export interface Order {
  id: number;
  order_no: string;
  name: string;
  district: string;
  total: number | string;
  payment_method: string;
  source?: string | null;
  is_first_order?: boolean | null;
  fee_tbc?: boolean | null;   // C1: delivery fee to be confirmed by Mika
  is_gift?: boolean | null;   // F6: delivered to someone else
}

export interface Push {
  tag: string;
  url: string;
  lang: 'en' | 'ar';
  en: { title: string; body: string };
  ar: { title: string; body: string };
}

const PAY_EN: Record<string, string> = { COD: 'Cash on delivery', WHISH: 'Whish (waiting)', OMT: 'OMT (waiting)' };
const PAY_AR: Record<string, string> = { COD: 'الدفع عند الاستلام', WHISH: 'Whish (بانتظار الدفع)', OMT: 'OMT (بانتظار الدفع)' };
const SRC_EN: Record<string, string> = { PHONE: ' · by phone', INSTAGRAM: ' · Instagram', WHATSAPP: ' · WhatsApp' };
const SRC_AR: Record<string, string> = { PHONE: ' · هاتفياً', INSTAGRAM: ' · إنستغرام', WHATSAPP: ' · واتساب' };

function amount(n: number | string, currency: string): string {
  const v = Number(n);
  const s = v.toLocaleString('en-US', { minimumFractionDigits: v % 1 ? 2 : 0, maximumFractionDigits: 2 });
  return currency ? `${s} ${currency}` : s;
}

export function buildPush(order: Order, items: OrderItem[], currency = '', lang: 'en' | 'ar' = 'en'): Push {
  const n = items.reduce((s, i) => s + Number(i.qty || 0), 0);
  const total = amount(order.total, currency);
  const src = order.source ?? '';
  const isNew = order.is_first_order === true;
  const feeTbc = order.fee_tbc === true;
  const gift = order.is_gift === true;
  return {
    tag: 'order-' + order.order_no,
    url: `staff/prep.html?open=${order.id}`,
    lang,
    en: {
      title: `🛒 New order ${order.order_no}${isNew ? ' · NEW CUSTOMER' : ''}`,
      body: `${order.name} · ${order.district}\n${n} ${n === 1 ? 'item' : 'items'} · ${total} · ${PAY_EN[order.payment_method] ?? order.payment_method}${SRC_EN[src] ?? ''}${gift ? ' · 🎁 GIFT' : ''}${feeTbc ? ' · FEE TO CONFIRM' : ''}`,
    },
    ar: {
      title: `🛒 طلب جديد ${order.order_no}${isNew ? ' · زبون جديد' : ''}`,
      body: `${order.name} · ${order.district}\n${n} قطعة · ${total} · ${PAY_AR[order.payment_method] ?? order.payment_method}${SRC_AR[src] ?? ''}${gift ? ' · 🎁 هدية' : ''}${feeTbc ? ' · رسم التوصيل للتأكيد' : ''}`,
    },
  };
}
