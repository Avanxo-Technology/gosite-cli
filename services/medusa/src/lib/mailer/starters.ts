// Starting points the Admin offers when a rule is created. They are copied
// into the rule, so a store edits its own HTML and a gosite release never
// changes an e-mail a store already sends. Plain tables and inline styles:
// what e-mail clients render.

export interface Starter {
  key: string
  label: string
  event: string
  recipient: "order_email" | "customer_email" | "event_email" | "custom"
  subject: string
  html: string
}

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="es">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${title}</title></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:Arial,Helvetica,sans-serif;color:#18181b">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;padding:24px 0">
<tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border-radius:8px">
<tr><td style="padding:24px 32px;border-bottom:1px solid #e4e4e7">
{{ if $.store.logo_url }}<img src="{{ $.store.logo_url }}" alt="{{ $.store.name }}" height="40" style="display:block;height:40px">{{ else }}<strong style="font-size:18px">{{ $.store.name }}</strong>{{ end }}
</td></tr>
<tr><td style="padding:32px">
${body}
</td></tr>
<tr><td style="padding:16px 32px;border-top:1px solid #e4e4e7;font-size:12px;color:#71717a">
{{ $.store.name }}{{ if $.store.url }} · <a href="{{ $.store.url }}" style="color:#71717a">{{ $.store.url }}</a>{{ end }}
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>
`
}

const orderLines = `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:24px 0;border-collapse:collapse;font-size:14px">
{{ range $.order.items }}<tr>
<td style="padding:8px 0;border-bottom:1px solid #e4e4e7">{{ .product_title }}{{ if .variant_label }} · {{ .variant_label }}{{ end }} × {{ .quantity }}</td>
<td align="right" style="padding:8px 0;border-bottom:1px solid #e4e4e7;white-space:nowrap">{{ .total_display }}</td>
</tr>{{ end }}
<tr><td style="padding:8px 0">Envío</td><td align="right" style="padding:8px 0">{{ $.order.shipping_total_display }}</td></tr>
<tr><td style="padding:8px 0"><strong>Total</strong></td><td align="right" style="padding:8px 0"><strong>{{ $.order.total_display }}</strong></td></tr>
</table>`

const shippingTo = `{{ if $.order.shipping_address }}<p style="font-size:14px;line-height:1.5;margin:0">
<strong>Enviamos a</strong><br>
{{ $.order.shipping_address.full_name }}<br>
{{ $.order.shipping_address.address_1 }}{{ if $.order.shipping_address.address_2 }}, {{ $.order.shipping_address.address_2 }}{{ end }}<br>
{{ $.order.shipping_address.city }}, {{ $.order.shipping_address.province }}
</p>{{ end }}`

export const STARTERS: Starter[] = [
  {
    key: "order_paid",
    label: "Pago confirmado",
    event: "gosite.order.paid",
    recipient: "order_email",
    subject: "Recibimos tu pago · pedido #{{ $.order.display_id }}",
    html: layout(
      "Pago confirmado",
      `<h1 style="font-size:22px;margin:0 0 12px">¡Gracias por tu compra{{ if $.order.shipping_address.first_name }}, {{ $.order.shipping_address.first_name }}{{ end }}!</h1>
<p style="font-size:15px;line-height:1.5;margin:0">Confirmamos el pago de tu pedido <strong>#{{ $.order.display_id }}</strong> del {{ $.order.created_at_display }}. Te avisaremos cuando salga hacia tu dirección.</p>
${orderLines}
${shippingTo}`
    ),
  },
  {
    key: "order_expired",
    label: "Pedido cancelado sin pago",
    event: "gosite.order.expired",
    recipient: "order_email",
    subject: "Tu pedido #{{ $.order.display_id }} fue cancelado",
    html: layout(
      "Pedido cancelado",
      `<h1 style="font-size:22px;margin:0 0 12px">Tu pedido #{{ $.order.display_id }} fue cancelado</h1>
<p style="font-size:15px;line-height:1.5;margin:0">No recibimos el pago a tiempo, así que liberamos los productos que habíamos reservado para ti. No se hizo ningún cobro.</p>
${orderLines}
{{ if $.store.url }}<p style="margin:24px 0 0"><a href="{{ $.store.url }}" style="display:inline-block;background:#18181b;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:6px">Volver a la tienda</a></p>{{ end }}`
    ),
  },
  {
    key: "order_placed",
    label: "Pedido recibido",
    event: "order.placed",
    recipient: "order_email",
    subject: "Recibimos tu pedido #{{ $.order.display_id }}",
    html: layout(
      "Pedido recibido",
      `<h1 style="font-size:22px;margin:0 0 12px">Recibimos tu pedido #{{ $.order.display_id }}</h1>
<p style="font-size:15px;line-height:1.5;margin:0">Gracias por tu compra. Este es el resumen.</p>
${orderLines}
${shippingTo}`
    ),
  },
  {
    key: "order_shipped",
    label: "Pedido enviado",
    event: "shipment.created",
    recipient: "order_email",
    subject: "Tu pedido #{{ $.order.display_id }} va en camino",
    html: layout(
      "Pedido enviado",
      `<h1 style="font-size:22px;margin:0 0 12px">Tu pedido #{{ $.order.display_id }} va en camino</h1>
<p style="font-size:15px;line-height:1.5;margin:0">Ya entregamos tu pedido a la transportadora.</p>
{{ range $.fulfillment.labels }}<p style="font-size:14px;margin:16px 0 0">Guía: <strong>{{ .tracking_number }}</strong>{{ if .tracking_url }} · <a href="{{ .tracking_url }}">Seguir el envío</a>{{ end }}</p>{{ end }}
${shippingTo}`
    ),
  },
  {
    key: "order_canceled",
    label: "Pedido cancelado por la tienda",
    event: "order.canceled",
    recipient: "order_email",
    subject: "Cancelamos tu pedido #{{ $.order.display_id }}",
    html: layout(
      "Pedido cancelado",
      `<h1 style="font-size:22px;margin:0 0 12px">Cancelamos tu pedido #{{ $.order.display_id }}</h1>
<p style="font-size:15px;line-height:1.5;margin:0">Si ya pagaste, te devolveremos el dinero por el mismo medio. Escríbenos si tienes preguntas.</p>
${orderLines}`
    ),
  },
  {
    key: "blank",
    label: "En blanco",
    event: "gosite.order.paid",
    recipient: "order_email",
    subject: "",
    html: layout("", `<p style="font-size:15px;line-height:1.5;margin:0"></p>`),
  },
]
