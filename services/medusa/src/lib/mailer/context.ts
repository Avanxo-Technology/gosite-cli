// What a template sees. Pure (no Medusa imports): the subscriber loads the
// records, these helpers shape them.

// Medusa 2 amounts are in the currency's major unit (12000 COP is 12000), as
// numbers or BigNumber-like objects.
export function amount(value: unknown): number | undefined {
  if (typeof value === "number") {
    return value
  }
  if (typeof value === "string" && value.trim() !== "" && !Number.isNaN(Number(value))) {
    return Number(value)
  }
  if (value && typeof value === "object") {
    const numeric = (value as { numeric?: unknown; value?: unknown }).numeric ?? (value as { value?: unknown }).value
    return amount(numeric)
  }
  return undefined
}

export function formatMoney(value: unknown, currency: string | undefined, locale: string): string {
  const n = amount(value)
  if (n === undefined) {
    return ""
  }
  if (!currency) {
    return new Intl.NumberFormat(locale).format(n)
  }
  try {
    return new Intl.NumberFormat(locale, { style: "currency", currency: currency.toUpperCase() }).format(n)
  } catch {
    return `${new Intl.NumberFormat(locale).format(n)} ${currency.toUpperCase()}`
  }
}

const ORDER_AMOUNTS = ["total", "subtotal", "item_total", "shipping_total", "tax_total", "discount_total"]
const ITEM_AMOUNTS = ["unit_price", "total", "subtotal"]

type Rec = Record<string, unknown>

// shapeOrder adds the *_display amounts ("$ 120.000") next to each raw one and
// a full_name to the addresses, so templates need no formatting logic.
export function shapeOrder(order: Rec, locale: string): Rec {
  const currency = typeof order.currency_code === "string" ? order.currency_code : undefined
  const shaped: Rec = { ...order }
  for (const key of ORDER_AMOUNTS) {
    if (key in order) {
      shaped[key] = amount(order[key])
      shaped[`${key}_display`] = formatMoney(order[key], currency, locale)
    }
  }
  if (Array.isArray(order.items)) {
    shaped.items = (order.items as Rec[]).map((item) => {
      const out: Rec = { ...item }
      // variant_label is the variant's name only when it says something: a
      // single-variant product repeats its title or says "Default variant".
      const variant = typeof item.variant_title === "string" ? item.variant_title.trim() : ""
      out.variant_label =
        variant && variant !== item.product_title && variant !== item.title && !/^default/i.test(variant) ? variant : ""
      for (const key of ITEM_AMOUNTS) {
        if (key in item) {
          out[key] = amount(item[key])
          out[`${key}_display`] = formatMoney(item[key], currency, locale)
        }
      }
      return out
    })
  }
  for (const key of ["shipping_address", "billing_address"]) {
    const address = order[key] as Rec | null | undefined
    if (address && typeof address === "object") {
      shaped[key] = { ...address, full_name: [address.first_name, address.last_name].filter(Boolean).join(" ") }
    }
  }
  if (order.created_at) {
    shaped.created_at_display = formatDate(order.created_at, locale)
  }
  return shaped
}

export function formatDate(value: unknown, locale: string): string {
  const date = value instanceof Date ? value : new Date(String(value))
  if (Number.isNaN(date.getTime())) {
    return ""
  }
  return new Intl.DateTimeFormat(locale, { dateStyle: "long", timeZone: "America/Bogota" }).format(date)
}

export interface StoreInfo {
  name: string
  url: string
  logo_url: string
}

export function storeInfo(env: Record<string, string | undefined>): StoreInfo {
  return {
    name: env.MAILER_STORE_NAME || env.SMTP_FROM_NAME || "",
    url: (env.MAILER_STORE_URL || "").replace(/\/$/, ""),
    logo_url: env.MAILER_LOGO_URL || "",
  }
}

export function mailerLocale(env: Record<string, string | undefined>): string {
  return env.MAILER_LOCALE || "es-CO"
}

// The variables every template can use, shown in the Admin next to the editor.
export const VARIABLES: Array<{ name: string; description: string }> = [
  { name: "$.store.name / $.store.url / $.store.logo_url", description: "MAILER_STORE_NAME, MAILER_STORE_URL, MAILER_LOGO_URL" },
  { name: "$.event", description: "the event's name" },
  { name: "$.data", description: "the event's payload as Medusa or your code emitted it" },
  { name: "$.order.display_id / .email / .created_at_display", description: "order events (order.*, gosite.order.*, shipment.created, delivery.created)" },
  { name: "$.order.total_display / .subtotal_display / .shipping_total_display / .tax_total_display / .discount_total_display", description: "formatted amounts; without _display, the number" },
  { name: "range $.order.items → .title .product_title .variant_label .variant_title .quantity .thumbnail .unit_price_display .total_display", description: "the order's lines" },
  { name: "$.order.shipping_address.full_name / .address_1 / .city / .province / .phone", description: "the shipping address" },
  { name: "range $.order.shipping_methods → .name", description: "the shipping method" },
  { name: "$.order.customer.first_name / .email", description: "the order's customer" },
  { name: "$.fulfillment.labels → .tracking_number .tracking_url", description: "shipment.created and delivery.created" },
  { name: "$.customer.first_name / .email", description: "customer.* events" },
  { name: "$.data.code / .expires_in_minutes / .new_account / .email", description: "gosite.customer.login_code: the sign-in code, its minutes, whether it creates the account" },
]
