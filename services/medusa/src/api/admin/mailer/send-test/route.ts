import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"

import { render, sendMail } from "../../../../lib/mailer/send"
import { sampleContext } from "../helpers"

const EMAIL = /^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/

// POST /admin/mailer/send-test { to, event, subject, html, order_id? }: sends the
// editor's e-mail, rendered with a real order, to the address given. Not
// recorded as a delivery and never sent to the order's buyer.
// (Not "test/": medusa build leaves out folders named test.)
export async function POST(req: MedusaRequest, res: MedusaResponse) {
  const body = (req.body ?? {}) as Record<string, string | undefined>
  const to = (body.to ?? "").trim()
  if (!EMAIL.test(to)) {
    res.status(400).json({ error: "Write the address to send the test to." })
    return
  }
  const { context, sample } = await sampleContext(req.scope, body.event || "gosite.order.paid", body.order_id || undefined)
  try {
    const rendered = render({ recipient: "custom", recipient_address: to, subject: body.subject ?? "", html: body.html ?? "" }, context)
    await sendMail({ to, subject: `[test] ${rendered.subject}`, html: rendered.html })
    res.json({ sent: true, to, sample })
  } catch (error) {
    res.status(400).json({ error: (error as Error).message, sample })
  }
}
