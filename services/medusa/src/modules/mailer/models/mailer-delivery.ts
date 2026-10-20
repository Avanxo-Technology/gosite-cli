import { model } from "@medusajs/framework/utils"

// One e-mail the mailer rendered: what was sent (or why not), kept so a
// repeated event never sends twice and a failed send is retried.
export const MailerDelivery = model.define("mailer_delivery", {
  id: model.id({ prefix: "mdel" }).primaryKey(),
  rule_id: model.text().index(),
  event: model.text(),
  resource_id: model.text().nullable(),
  // rule:event:record for rules that send once; unique, so a second insert of
  // the same e-mail fails instead of sending it again.
  dedupe_key: model.text().unique().nullable(),
  to: model.text(),
  bcc: model.text().nullable(),
  subject: model.text(),
  html: model.text(),
  status: model.enum(["pending", "sent", "failed", "skipped"]).default("pending"),
  attempts: model.number().default(0),
  last_error: model.text().nullable(),
  sent_at: model.dateTime().nullable(),
})
