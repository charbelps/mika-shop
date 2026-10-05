// Builds the Telegram text for a new order. Plain text (no Markdown), so names with
// special characters can never break the message.

export interface OrderItem {
  qty: number;
  name_en: string;
  label: string | null;
  line_total: number | string;
}

export interface Order {
  order_no: string;
  name: string;
  phone: string;
  governorate: string;
  district: string;
  town: string;
  address: string;
  landmark: string | null;
  location_url: string | null;
  subtotal: number | string;
  delivery_fee: number | string;
  total: number | string;
  payment_method: string;
  source?: string | null;
}

// Orders Mika entered herself (F7). Website orders get no extra line.
const SOURCE: Record<string, string> = {
  PHONE: '☎️ Taken by phone',
  INSTAGRAM: '📷 Taken on Instagram',
  WHATSAPP: '💬 Taken on WhatsApp',
};

const PAY: Record<string, string> = {
  COD: '💵 Cash on delivery',
  WHISH: '📲 Whish (waiting for payment)',
  OMT: '🏦 OMT (waiting for payment)',
};

function amount(n: number | string, currency: string): string {
  const v = Number(n);
  const s = v.toLocaleString('en-US', { minimumFractionDigits: v % 1 ? 2 : 0, maximumFractionDigits: 2 });
  return currency ? `${s} ${currency}` : s;
}

export function buildMessage(order: Order, items: OrderItem[], currency = ''): string {
  const lines: string[] = [];
  lines.push(`🛒 New order ${order.order_no}`);
  if (order.source && SOURCE[order.source]) lines.push(SOURCE[order.source]);
  lines.push('');
  lines.push(`👤 ${order.name}`);
  lines.push(`📞 ${order.phone}`);
  lines.push(`📍 ${order.town}, ${order.district} (${order.governorate})`);
  lines.push(`🏠 ${order.address}`);
  if (order.landmark) lines.push(`🔎 ${order.landmark}`);
  if (order.location_url) lines.push(`🗺️ ${order.location_url}`);
  lines.push('');
  for (const it of items) {
    const label = it.label ? ` (${it.label})` : '';
    lines.push(`• ${it.qty} × ${it.name_en}${label}: ${amount(it.line_total, currency)}`);
  }
  lines.push('');
  lines.push(`Subtotal: ${amount(order.subtotal, currency)}`);
  lines.push(`Delivery: ${amount(order.delivery_fee, currency)}`);
  lines.push(`TOTAL: ${amount(order.total, currency)}`);
  lines.push(PAY[order.payment_method] ?? order.payment_method);
  return lines.join('\n').slice(0, 4000); // Telegram limit is 4096
}
