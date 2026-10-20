import test from "node:test"
import assert from "node:assert/strict"

import {
  dedupeKey,
  mailerEvents,
  parseRule,
  resolveRecipients,
  resourceOf,
  skipEvent,
} from "../../src/lib/mailer/rules.ts"

const events = mailerEvents({})

test("the mailer listens to gosite's and Medusa's events, plus valid extra ones", () => {
  assert.ok(events.includes("gosite.order.paid"))
  assert.ok(events.includes("gosite.order.expired"))
  assert.ok(events.includes("order.placed"))
  assert.ok(events.includes("shipment.created"))
  const extra = mailerEvents({ MAILER_EXTRA_EVENTS: " loyalty.points_credited, Bad Name ,order.placed" })
  assert.ok(extra.includes("loyalty.points_credited"))
  assert.ok(!extra.includes("Bad Name"))
  assert.equal(extra.filter((e) => e === "order.placed").length, 1)
})

const valid = {
  name: "Pago confirmado",
  event: "gosite.order.paid",
  active: true,
  recipient: "order_email",
  subject: "Pedido #{{ $.order.display_id }}",
  html: "<p>{{ $.order.total_display }}</p>",
}

test("a valid rule is normalized", () => {
  const parsed = parseRule({ ...valid, bcc: " ventas@a.co ; bodega@a.co ", recipient_address: "x@y.co" }, events)
  assert.ok("rule" in parsed)
  if ("rule" in parsed) {
    assert.equal(parsed.rule.bcc, "ventas@a.co, bodega@a.co")
    assert.equal(parsed.rule.recipient_address, null)
    assert.equal(parsed.rule.once, true)
    assert.equal(parsed.rule.active, true)
  }
})

test("an invalid rule reports each field", () => {
  const parsed = parseRule(
    { name: " ", event: "nope", recipient: "custom", recipient_address: "not-an-email", subject: "", html: "{{ if .a }}" },
    events
  )
  assert.ok("errors" in parsed)
  if ("errors" in parsed) {
    assert.deepEqual(Object.keys(parsed.errors).sort(), ["event", "html", "name", "recipient_address", "subject"])
  }
  assert.ok("errors" in parseRule({ ...valid, active: "yes", once: false, bcc: "bad" }, events))
})

test("recipients come from the order, the customer, the event or the rule", () => {
  const order = { email: "ana@a.co", customer: { email: "cuenta@a.co" } }
  assert.deepEqual(resolveRecipients({ recipient: "order_email", recipient_address: null }, { order }), ["ana@a.co"])
  assert.deepEqual(resolveRecipients({ recipient: "customer_email", recipient_address: null }, { order }), ["cuenta@a.co"])
  assert.deepEqual(resolveRecipients({ recipient: "event_email", recipient_address: null }, { data: { email: "e@a.co" } }), ["e@a.co"])
  assert.deepEqual(resolveRecipients({ recipient: "event_email", recipient_address: null }, { data: {} }), [])
  assert.deepEqual(resolveRecipients({ recipient: "custom", recipient_address: "a@a.co, b@a.co" }, {}), ["a@a.co", "b@a.co"])
  assert.deepEqual(resolveRecipients({ recipient: "order_email", recipient_address: null }, {}), [])
})

test("once-per-record rules get a dedupe key, others none", () => {
  assert.equal(dedupeKey("mrule_1", "gosite.order.paid", "order_1", true), "mrule_1:gosite.order.paid:order_1")
  assert.equal(dedupeKey("mrule_1", "order.updated", "order_1", false), null)
  assert.equal(dedupeKey("mrule_1", "custom.thing", undefined, true), null)
})

test("events name their record, and no_notification skips them", () => {
  assert.deepEqual(resourceOf("gosite.order.paid", { id: "order_1" }), { type: "order", id: "order_1" })
  assert.deepEqual(resourceOf("order.fulfillment_created", { order_id: "order_2", fulfillment_id: "ful_1" }), { type: "order", id: "order_2" })
  assert.deepEqual(resourceOf("shipment.created", { id: "ful_1" }), { type: "fulfillment", id: "ful_1" })
  assert.deepEqual(resourceOf("customer.created", { id: "cus_1" }), { type: "customer", id: "cus_1" })
  assert.deepEqual(resourceOf("auth.password_reset", { entity_id: "a@a.co" }), { type: "event", id: "a@a.co" })
  assert.equal(skipEvent({ id: "order_1", no_notification: true }), true)
  assert.equal(skipEvent({ id: "order_1" }), false)
})
