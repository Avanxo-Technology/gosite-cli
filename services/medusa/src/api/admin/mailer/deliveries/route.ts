import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"

import { MAILER_MODULE } from "../../../../modules/mailer"
import type MailerModuleService from "../../../../modules/mailer/service"

// GET /admin/mailer/deliveries: the latest 100 e-mails, without their HTML.
export async function GET(req: MedusaRequest, res: MedusaResponse) {
  const mailer: MailerModuleService = req.scope.resolve(MAILER_MODULE)
  const deliveries = await mailer.listMailerDeliveries(
    {},
    {
      select: ["id", "rule_id", "event", "resource_id", "to", "subject", "status", "attempts", "last_error", "sent_at", "created_at"],
      order: { created_at: "DESC" },
      take: 100,
    }
  )
  res.json({ deliveries })
}
