import test from "node:test"
import assert from "node:assert/strict"

import { amount, formatMoney, shapeOrder, storeInfo } from "../../src/lib/mailer/context.ts"
import { smtpSettings } from "../../src/lib/mailer/smtp.ts"
import { STARTERS } from "../../src/lib/mailer/starters.ts"
import { checkTemplate, renderHTML } from "../../src/lib/mailer/template.ts"
import { mailerEvents } from "../../src/lib/mailer/rules.ts"
import { newlyPaid, PAID_ANNOUNCED } from "../../src/lib/paid-orders.ts"

test("SMTP follows the CMS's variables and defaults", () => {
  assert.equal(smtpSettings({}), undefined)
  assert.equal(smtpSettings({ SMTP_HOST: "smtp.a.co", SMTP_USER: "apikey" }), undefined, "no sender")
  assert.deepEqual(smtpSettings({ SMTP_HOST: "smtp.a.co", SMTP_USER: "ana@a.co", SMTP_PASSWORD: "p" }), {
    host: "smtp.a.co",
    port: 587,
    secure: false,
    requireTLS: true,
    ignoreTLS: false,
    auth: { user: "ana@a.co", pass: "p" },
    from: "ana@a.co",
  })
  const ssl = smtpSettings({ SMTP_HOST: "h", SMTP_PORT: "465", SMTP_FROM: "t@a.co", SMTP_FROM_NAME: 'Tienda "A"' })
  assert.equal(ssl?.secure, true)
  assert.equal(ssl?.auth, undefined)
  assert.equal(ssl?.from, `"Tienda 'A'" <t@a.co>`)
  assert.equal(smtpSettings({ SMTP_HOST: "h", SMTP_FROM: "t@a.co", SMTP_ENCRYPTION: "none" })?.ignoreTLS, true)
})

test("amounts are formatted for the store's locale", () => {
  assert.equal(amount({ numeric: 1200 }), 1200)
  assert.equal(amount("15.5"), 15.5)
  assert.equal(amount(null), undefined)
  assert.match(formatMoney(120000, "cop", "es-CO"), /120\.000/)
  const order = shapeOrder(
    {
      currency_code: "cop",
      total: 30485,
      shipping_total: { numeric: 0 },
      items: [
        { title: "Bota", product_title: "Bota", variant_title: "Bota", unit_price: 30485, total: 30485 },
        { title: "Casco", product_title: "Casco", variant_title: "Talla L" },
      ],
      shipping_address: { first_name: "Ana", last_name: "Prueba" },
      created_at: "2026-10-20T12:00:00Z",
    },
    "es-CO"
  )
  assert.match(String(order.total_display), /30\.485/)
  assert.equal(order.shipping_total, 0)
  assert.match(String((order.items as Array<Record<string, unknown>>)[0].unit_price_display), /30\.485/)
  const items = order.items as Array<Record<string, unknown>>
  assert.equal(items[0].variant_label, "", "a variant named like its product says nothing")
  assert.equal(items[1].variant_label, "Talla L")
  assert.equal((order.shipping_address as Record<string, unknown>).full_name, "Ana Prueba")
  assert.match(String(order.created_at_display), /octubre/)
  assert.deepEqual(storeInfo({ SMTP_FROM_NAME: "Aldu", MAILER_STORE_URL: "https://aldu.co/" }), { name: "Aldu", url: "https://aldu.co", logo_url: "" })
})

test("starting templates parse, render and use events the mailer listens to", () => {
  const events = mailerEvents({})
  const context = {
    store: { name: "Aldu", url: "https://aldu.co", logo_url: "" },
    order: shapeOrder({ display_id: 7, currency_code: "cop", total: 100, items: [{ product_title: "Bota", quantity: 1, total: 100 }] }, "es-CO"),
  }
  for (const starter of STARTERS) {
    assert.equal(checkTemplate(starter.html), undefined, starter.key)
    assert.equal(checkTemplate(starter.subject), undefined, starter.key)
    assert.ok(events.includes(starter.event), starter.key)
    assert.doesNotThrow(() => renderHTML(starter.html, context))
  }
  assert.match(renderHTML(STARTERS[0].html, context), /#7/)
})

test("newlyPaid announces each recently paid order once", () => {
  const now = new Date("2026-10-20T12:00:00Z")
  const paidAt = (ms: number) => [{ status: "completed", payments: [{ created_at: new Date(now.getTime() - ms) }] }]
  const ids = newlyPaid(
    [
      { id: "o_new", status: "pending", payment_collections: paidAt(60_000) },
      { id: "o_old", status: "pending", payment_collections: paidAt(3 * 3_600_000) },
      { id: "o_done", status: "pending", metadata: { [PAID_ANNOUNCED]: "x" }, payment_collections: paidAt(60_000) },
      { id: "o_cancel", status: "canceled", payment_collections: paidAt(60_000) },
      { id: "o_wait", status: "pending", payment_collections: [{ status: "awaiting", payments: [] }] },
      { id: "o_auth", status: "pending", payment_collections: [{ status: "authorized", payments: [{ created_at: now.toISOString() }] }] },
    ],
    now
  )
  assert.deepEqual(ids, ["o_new", "o_auth"])
})
