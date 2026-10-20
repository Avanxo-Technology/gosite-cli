import { model } from "@medusajs/framework/utils"

// One e-mail a store sends: on which event, to whom, with which template.
// Inactive rules are kept for later; only active ones send.
export const MailerRule = model.define("mailer_rule", {
  id: model.id({ prefix: "mrule" }).primaryKey(),
  name: model.text(),
  event: model.text().index(),
  active: model.boolean().default(false),
  recipient: model.enum(["order_email", "customer_email", "event_email", "custom"]).default("order_email"),
  recipient_address: model.text().nullable(),
  bcc: model.text().nullable(),
  subject: model.text(),
  html: model.text(),
  // Send at most once per record (order, customer...), whatever repeats.
  once: model.boolean().default(true),
})
