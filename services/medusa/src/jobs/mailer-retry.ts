import type { MedusaContainer } from "@medusajs/framework/types"

import { MAX_ATTEMPTS } from "../lib/mailer/rules"
import { attempt } from "../lib/mailer/send"
import { MAILER_MODULE } from "../modules/mailer"
import type MailerModuleService from "../modules/mailer/service"

// Retries e-mails the SMTP server refused or could not be reached for, up to
// MAX_ATTEMPTS, for a day. Skipped ones (no recipient, no SMTP) are not
// retried: nothing would change.
export const config = {
  name: "mailer-retry",
  schedule: "*/5 * * * *",
}

const RETRY_FOR_MS = 24 * 3_600_000

export default async function mailerRetry(container: MedusaContainer) {
  const mailer: MailerModuleService = container.resolve(MAILER_MODULE)
  const failed = await mailer.listMailerDeliveries(
    { status: "failed", attempts: { $lt: MAX_ATTEMPTS }, created_at: { $gte: new Date(Date.now() - RETRY_FOR_MS) } },
    { take: 50, order: { created_at: "ASC" } }
  )
  for (const delivery of failed) {
    await attempt(container, delivery)
  }
}
