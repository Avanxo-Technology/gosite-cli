// The mailer's rules: which events send an e-mail, to whom, with which
// template. Pure (no Medusa imports) so it is unit-tested with node --test.

import { checkTemplate } from "./template"

// gosite's own events. Medusa emits no event when a deferred payment is
// confirmed (the provider reports it captured while authorizing), so gosite
// emits these itself: see jobs/notify-paid-orders and
// jobs/expire-pending-payments.
export const GOSITE_ORDER_PAID = "gosite.order.paid"
export const GOSITE_ORDER_EXPIRED = "gosite.order.expired"
export const GOSITE_EVENTS = [GOSITE_ORDER_PAID, GOSITE_ORDER_EXPIRED] as const

// The Medusa events a store may want to e-mail about. The subscriber listens
// to these plus GOSITE_EVENTS and MAILER_EXTRA_EVENTS; an event nobody listens
// to costs nothing, while a wildcard would queue every internal event.
export const MEDUSA_EVENTS = [
  "order.placed",
  "order.updated",
  "order.canceled",
  "order.completed",
  "order.archived",
  "order.fulfillment_created",
  "order.fulfillment_canceled",
  "order.return_requested",
  "order.return_received",
  "order.claim_created",
  "order.exchange_created",
  "order.transfer_requested",
  "order-edit.requested",
  "order-edit.confirmed",
  "order-edit.canceled",
  "shipment.created",
  "delivery.created",
  "payment.captured",
  "payment.refunded",
  "customer.created",
  "customer.updated",
  "auth.password_reset",
  "auth.verification_requested",
  "invite.created",
  "invite.resent",
] as const

const EVENT_NAME = /^[a-z0-9][a-z0-9_.-]*$/

// mailerEvents is the subscriber's event list: Medusa's, gosite's and the
// comma-separated MAILER_EXTRA_EVENTS (custom events a site's code emits).
// Adding an extra event needs a restart: Medusa reads a subscriber's events
// when it starts.
export function mailerEvents(env: Record<string, string | undefined>): string[] {
  const extra = (env.MAILER_EXTRA_EVENTS ?? "")
    .split(",")
    .map((name) => name.trim())
    .filter((name) => EVENT_NAME.test(name))
  return [...new Set<string>([...GOSITE_EVENTS, ...MEDUSA_EVENTS, ...extra])]
}

export const RECIPIENTS = ["order_email", "customer_email", "event_email", "custom"] as const
export type Recipient = (typeof RECIPIENTS)[number]

export interface RuleInput {
  name: string
  event: string
  active: boolean
  recipient: Recipient
  recipient_address: string | null
  bcc: string | null
  subject: string
  html: string
  once: boolean
}

const EMAIL = /^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/

function emailList(value: string): string[] {
  return value
    .split(/[,;]/)
    .map((address) => address.trim())
    .filter(Boolean)
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : ""
}

// parseRule validates what the Admin sends. It returns the rule or the
// errors, keyed by field, in the words the Admin shows.
export function parseRule(
  body: Record<string, unknown>,
  events: string[]
): { rule: RuleInput } | { errors: Record<string, string> } {
  const errors: Record<string, string> = {}
  const name = text(body.name)
  const event = text(body.event)
  const recipient = text(body.recipient) as Recipient
  const address = text(body.recipient_address)
  const bcc = text(body.bcc)
  const subject = text(body.subject)
  const html = typeof body.html === "string" ? body.html : ""

  if (!name) {
    errors.name = "Give the rule a name."
  }
  if (!events.includes(event)) {
    errors.event = "Pick one of the events the mailer listens to."
  }
  if (!RECIPIENTS.includes(recipient)) {
    errors.recipient = "Pick who receives the e-mail."
  }
  if (recipient === "custom" && !(emailList(address).length && emailList(address).every((a) => EMAIL.test(a)))) {
    errors.recipient_address = "Write one or more e-mail addresses, separated by commas."
  }
  if (bcc && !emailList(bcc).every((a) => EMAIL.test(a))) {
    errors.bcc = "Write e-mail addresses separated by commas, or leave it empty."
  }
  if (!subject) {
    errors.subject = "Write a subject."
  } else {
    const problem = checkTemplate(subject)
    if (problem) {
      errors.subject = problem
    }
  }
  if (!html.trim()) {
    errors.html = "Write the e-mail's HTML."
  } else {
    const problem = checkTemplate(html)
    if (problem) {
      errors.html = problem
    }
  }
  if (Object.keys(errors).length) {
    return { errors }
  }
  return {
    rule: {
      name,
      event,
      active: body.active === true,
      recipient,
      recipient_address: recipient === "custom" ? emailList(address).join(", ") : null,
      bcc: bcc ? emailList(bcc).join(", ") : null,
      subject,
      html,
      once: body.once !== false,
    },
  }
}

// resolveRecipients says where a rule's e-mail goes for one event, or [] when
// the event carries no address of that kind (the e-mail is then skipped).
export function resolveRecipients(
  rule: Pick<RuleInput, "recipient" | "recipient_address">,
  context: { order?: { email?: string | null; customer?: { email?: string | null } | null } | null; customer?: { email?: string | null } | null; data?: Record<string, unknown> }
): string[] {
  switch (rule.recipient) {
    case "order_email": {
      const email = context.order?.email || context.order?.customer?.email
      return email ? [email] : []
    }
    case "customer_email": {
      const email = context.customer?.email || context.order?.customer?.email || context.order?.email
      return email ? [email] : []
    }
    case "event_email": {
      const email = context.data?.email
      return typeof email === "string" && EMAIL.test(email) ? [email] : []
    }
    case "custom":
      return emailList(rule.recipient_address ?? "")
    default:
      return []
  }
}

// dedupeKey identifies one e-mail of a rule that sends once per record: the
// same order never gets the same e-mail twice, even when Medusa repeats an
// event or a job emits it again. Rules that send on every event get none.
export function dedupeKey(ruleID: string, event: string, resourceID: string | undefined, once: boolean): string | null {
  if (!once || !resourceID) {
    return null
  }
  return `${ruleID}:${event}:${resourceID}`
}

// skipEvent honours Medusa's no_notification flag: a workflow run with it
// (an order cancelled by the expire-pending-payments job) asks not to notify.
export function skipEvent(data: Record<string, unknown> | undefined): boolean {
  return data?.no_notification === true
}

// resourceOf names the record an event is about: an order for order and
// gosite order events, otherwise the event's id.
export function resourceOf(event: string, data: Record<string, unknown> | undefined): { type: string; id?: string } {
  const id = typeof data?.id === "string" ? data.id : undefined
  const orderID = typeof data?.order_id === "string" ? data.order_id : undefined
  if (event.startsWith("order.") || event.startsWith("gosite.order.")) {
    return { type: "order", id: orderID ?? id }
  }
  if (event === "shipment.created" || event === "delivery.created") {
    return { type: "fulfillment", id }
  }
  if (event.startsWith("customer.")) {
    return { type: "customer", id }
  }
  if (event.startsWith("order-edit.")) {
    return { type: "order", id: orderID }
  }
  if (event.startsWith("payment.")) {
    return { type: "payment", id }
  }
  return { type: "event", id: id ?? (typeof data?.entity_id === "string" ? data.entity_id : undefined) }
}

export const MAX_ATTEMPTS = 5
