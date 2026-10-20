import type { MedusaRequest, MedusaResponse } from "@medusajs/framework/http"

import { render } from "../../../../lib/mailer/send"
import { RECIPIENTS, type Recipient } from "../../../../lib/mailer/rules"
import { sampleContext } from "../helpers"

type Body = {
  event?: string
  subject?: string
  html?: string
  recipient?: string
  recipient_address?: string
  order_id?: string
}

// POST /admin/mailer/preview: the editor's current subject and HTML rendered
// with a real order (order_id, else the latest), without saving or sending.
export async function POST(req: MedusaRequest, res: MedusaResponse) {
  const body = (req.body ?? {}) as Body
  const recipient = (RECIPIENTS as readonly string[]).includes(body.recipient ?? "") ? (body.recipient as Recipient) : "order_email"
  const { context, sample } = await sampleContext(req.scope, body.event || "gosite.order.paid", body.order_id || undefined)
  try {
    const rendered = render(
      { recipient, recipient_address: body.recipient_address ?? null, subject: body.subject ?? "", html: body.html ?? "" },
      context
    )
    res.json({ ...rendered, sample })
  } catch (error) {
    res.status(400).json({ error: (error as Error).message, sample })
  }
}
