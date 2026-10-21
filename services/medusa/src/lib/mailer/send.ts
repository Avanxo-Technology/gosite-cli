import type { MedusaContainer } from "@medusajs/framework/types"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"
import nodemailer, { type Transporter } from "nodemailer"

import { MAILER_MODULE } from "../../modules/mailer"
import type MailerModuleService from "../../modules/mailer/service"
import { redact } from "../login-code"
import { mailerLocale, shapeOrder, storeInfo } from "./context"
import { dedupeKey, MAX_ATTEMPTS, resolveRecipients, resourceOf, type RuleInput } from "./rules"
import { smtpSettings } from "./smtp"
import { renderHTML, renderText } from "./template"

// The Medusa side of the mailer: load what a template needs, render, record
// and send. Rendering and the rules themselves are pure (template.ts,
// rules.ts).

export const ORDER_FIELDS = [
  "id",
  "display_id",
  "email",
  "status",
  "currency_code",
  "created_at",
  "metadata",
  "total",
  "subtotal",
  "item_total",
  "shipping_total",
  "tax_total",
  "discount_total",
  "items.id",
  "items.title",
  "items.product_title",
  "items.variant_title",
  "items.quantity",
  "items.thumbnail",
  "items.unit_price",
  "items.total",
  "items.subtotal",
  "shipping_address.*",
  "billing_address.*",
  "shipping_methods.name",
  "customer.id",
  "customer.email",
  "customer.first_name",
  "customer.last_name",
]

type Rec = Record<string, unknown>

export interface MailContext {
  event: string
  data: Rec
  store: ReturnType<typeof storeInfo>
  order?: Rec | null
  customer?: Rec | null
  fulfillment?: Rec | null
}

async function graphOne(container: MedusaContainer, entity: string, id: string, fields: string[]): Promise<Rec | null> {
  const query = container.resolve(ContainerRegistrationKeys.QUERY)
  const { data } = await query.graph({ entity, fields, filters: { id } })
  return ((data as Rec[])[0] as Rec | undefined) ?? null
}

export async function loadOrder(container: MedusaContainer, id: string): Promise<Rec | null> {
  const order = await graphOne(container, "order", id, ORDER_FIELDS)
  return order ? shapeOrder(order, mailerLocale(process.env)) : null
}

// loadContext gathers the record an event is about. A record that no longer
// exists leaves its key null; the template renders what it can.
export async function loadContext(container: MedusaContainer, event: string, data: Rec): Promise<MailContext> {
  const context: MailContext = { event, data, store: storeInfo(process.env) }
  const resource = resourceOf(event, data)
  if (!resource.id) {
    return context
  }
  switch (resource.type) {
    case "order":
      context.order = await loadOrder(container, resource.id)
      context.customer = (context.order?.customer as Rec | undefined) ?? null
      break
    case "fulfillment": {
      context.fulfillment = await graphOne(container, "fulfillment", resource.id, ["id", "labels.*", "order.id"])
      const orderID = (context.fulfillment?.order as Rec | undefined)?.id
      if (typeof orderID === "string") {
        context.order = await loadOrder(container, orderID)
        context.customer = (context.order?.customer as Rec | undefined) ?? null
      }
      break
    }
    case "customer":
      context.customer = await graphOne(container, "customer", resource.id, ["id", "email", "first_name", "last_name", "has_account"])
      break
  }
  return context
}

export interface Rendered {
  to: string[]
  subject: string
  html: string
}

export function render(rule: Pick<RuleInput, "recipient" | "recipient_address" | "subject" | "html">, context: MailContext): Rendered {
  return {
    to: resolveRecipients(rule, context as never),
    subject: renderText(rule.subject, context),
    html: renderHTML(rule.html, context),
  }
}

let transport: { key: string; transporter: Transporter } | undefined

function transporter(): { transporter: Transporter; from: string } | undefined {
  const settings = smtpSettings(process.env)
  if (!settings) {
    return undefined
  }
  const key = JSON.stringify(settings)
  if (transport?.key !== key) {
    const { from, ...options } = settings
    // Short timeouts: a server that is down fails the send in seconds (and
    // jobs/mailer-retry tries again) instead of holding the event for
    // nodemailer's default two minutes.
    transport = {
      key,
      transporter: nodemailer.createTransport({ ...options, connectionTimeout: 10_000, greetingTimeout: 10_000, socketTimeout: 30_000 }),
    }
  }
  return { transporter: transport.transporter, from: settings.from }
}

// sendMail sends one rendered e-mail. It throws when SMTP is not configured
// or the server refuses it.
export async function sendMail(message: { to: string; bcc?: string | null; subject: string; html: string }): Promise<void> {
  const smtp = transporter()
  if (!smtp) {
    throw new Error("SMTP is not configured: set SMTP_HOST and SMTP_FROM")
  }
  await smtp.transporter.sendMail({
    from: smtp.from,
    to: message.to,
    bcc: message.bcc || undefined,
    subject: message.subject,
    html: message.html,
  })
}

type Rule = RuleInput & { id: string }

function isDuplicate(error: unknown): boolean {
  const text = String((error as Error)?.message ?? error)
  return /duplicate|unique|already exists/i.test(text) || (error as { type?: string })?.type === "duplicate_error"
}

export interface DeliverOptions {
  // A secret in the e-mail (a sign-in code): sent, but never stored.
  secret?: string
  // false: a failed send is not retried later (a code would arrive expired).
  retry?: boolean
}

// deliver renders a rule for one event, records it and sends it. A rule that
// sends once per record and already sent for this one records nothing.
export async function deliver(
  container: MedusaContainer,
  rule: Rule,
  context: MailContext,
  options: DeliverOptions = {}
): Promise<"sent" | "failed" | "skipped" | "duplicate"> {
  const mailer: MailerModuleService = container.resolve(MAILER_MODULE)
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)
  const resource = resourceOf(context.event, context.data)

  let rendered: Rendered | undefined
  let problem: string | undefined
  try {
    rendered = render(rule, context)
    if (!rendered.to.length) {
      problem = `no recipient: the event has no ${rule.recipient.replace("_", " ")}`
    }
  } catch (error) {
    problem = `template error: ${(error as Error).message}`
  }
  if (!problem && !smtpSettings(process.env)) {
    problem = "SMTP is not configured: set SMTP_HOST and SMTP_FROM"
  }

  let delivery: { id: string }
  try {
    delivery = await mailer.createMailerDeliveries({
      rule_id: rule.id,
      event: context.event,
      resource_id: resource.id ?? null,
      dedupe_key: dedupeKey(rule.id, context.event, resource.id, rule.once),
      to: rendered?.to.join(", ") ?? "",
      bcc: rule.bcc,
      subject: redact(rendered?.subject ?? "", options.secret ?? ""),
      html: redact(rendered?.html ?? "", options.secret ?? ""),
      status: problem ? "skipped" : "pending",
      last_error: problem ?? null,
    })
  } catch (error) {
    if (isDuplicate(error)) {
      return "duplicate"
    }
    throw error
  }
  if (problem || !rendered) {
    logger.warn(`mailer: ${rule.name} on ${context.event} skipped: ${problem}`)
    return "skipped"
  }
  return attempt(
    container,
    { id: delivery.id, to: rendered.to.join(", "), bcc: rule.bcc, subject: rendered.subject, html: rendered.html, attempts: 0 },
    options.retry === false
  )
}

// attempt sends a recorded e-mail and stores the outcome; a failure is
// retried by jobs/mailer-retry until MAX_ATTEMPTS, unless final.
export async function attempt(
  container: MedusaContainer,
  delivery: { id: string; to: string; bcc?: string | null; subject: string; html: string; attempts: number },
  final = false
): Promise<"sent" | "failed"> {
  const mailer: MailerModuleService = container.resolve(MAILER_MODULE)
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)
  const attempts = delivery.attempts + 1
  try {
    await sendMail(delivery)
    await mailer.updateMailerDeliveries({ id: delivery.id, status: "sent", attempts, sent_at: new Date(), last_error: null })
    return "sent"
  } catch (error) {
    const message = String((error as Error)?.message ?? error).slice(0, 500)
    await mailer.updateMailerDeliveries({ id: delivery.id, status: "failed", attempts: final ? MAX_ATTEMPTS : attempts, last_error: message })
    logger.warn(`mailer: sending ${delivery.id} failed (attempt ${attempts} of ${MAX_ATTEMPTS}): ${message}`)
    return "failed"
  }
}
