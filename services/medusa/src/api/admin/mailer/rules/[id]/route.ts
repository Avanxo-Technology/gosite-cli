import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"

import { mailerEvents, parseRule } from "../../../../../lib/mailer/rules"
import { MAILER_MODULE } from "../../../../../modules/mailer"
import type MailerModuleService from "../../../../../modules/mailer/service"

export async function GET(req: MedusaRequest, res: MedusaResponse) {
  const mailer: MailerModuleService = req.scope.resolve(MAILER_MODULE)
  const rule = await mailer.retrieveMailerRule(req.params.id)
  res.json({ rule })
}

// POST /admin/mailer/rules/:id: replace the rule with what the editor sends.
export async function POST(req: MedusaRequest, res: MedusaResponse) {
  const parsed = parseRule((req.body ?? {}) as Record<string, unknown>, mailerEvents(process.env))
  if ("errors" in parsed) {
    res.status(400).json({ errors: parsed.errors })
    return
  }
  const mailer: MailerModuleService = req.scope.resolve(MAILER_MODULE)
  await mailer.retrieveMailerRule(req.params.id)
  const rule = await mailer.updateMailerRules({ id: req.params.id, ...parsed.rule })
  res.json({ rule })
}

export async function DELETE(req: MedusaRequest, res: MedusaResponse) {
  const mailer: MailerModuleService = req.scope.resolve(MAILER_MODULE)
  await mailer.deleteMailerRules(req.params.id)
  res.json({ id: req.params.id, deleted: true })
}
