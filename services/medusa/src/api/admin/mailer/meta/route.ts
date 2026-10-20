import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"

import { VARIABLES } from "../../../../lib/mailer/context"
import { GOSITE_EVENTS, mailerEvents, RECIPIENTS } from "../../../../lib/mailer/rules"
import { smtpSettings } from "../../../../lib/mailer/smtp"
import { STARTERS } from "../../../../lib/mailer/starters"

// GET /admin/mailer/meta: what the editor offers: the events the mailer
// listens to, the starting templates, the variables and whether SMTP is set.
export async function GET(_req: MedusaRequest, res: MedusaResponse) {
  const smtp = smtpSettings(process.env)
  res.json({
    events: mailerEvents(process.env),
    gosite_events: GOSITE_EVENTS,
    recipients: RECIPIENTS,
    starters: STARTERS,
    variables: VARIABLES,
    smtp: { configured: Boolean(smtp), from: smtp?.from ?? null, host: smtp?.host ?? null },
  })
}
