import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"

import { mailerEvents, parseRule } from "../../../../lib/mailer/rules"
import { MAILER_MODULE } from "../../../../modules/mailer"
import type MailerModuleService from "../../../../modules/mailer/service"

// GET /admin/mailer/rules: every rule, newest first.
export async function GET(req: MedusaRequest, res: MedusaResponse) {
  const mailer: MailerModuleService = req.scope.resolve(MAILER_MODULE)
  const rules = await mailer.listMailerRules({}, { order: { created_at: "DESC" } })
  res.json({ rules })
}

// POST /admin/mailer/rules: create a rule; 400 with the errors by field.
export async function POST(req: MedusaRequest, res: MedusaResponse) {
  const parsed = parseRule((req.body ?? {}) as Record<string, unknown>, mailerEvents(process.env))
  if ("errors" in parsed) {
    res.status(400).json({ errors: parsed.errors })
    return
  }
  const mailer: MailerModuleService = req.scope.resolve(MAILER_MODULE)
  const rule = await mailer.createMailerRules(parsed.rule)
  res.json({ rule })
}
