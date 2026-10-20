import type { SubscriberArgs, SubscriberConfig } from "@medusajs/framework"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"

import { deliver, loadContext } from "../lib/mailer/send"
import { mailerEvents, skipEvent, type RuleInput } from "../lib/mailer/rules"
import { MAILER_MODULE } from "../modules/mailer"
import type MailerModuleService from "../modules/mailer/service"

// Sends the e-mails of the active rules for each event the mailer listens to.
// Which events send what is decided in the Admin (Mailer), per store: a site
// that places orders before payment e-mails on gosite.order.paid, another on
// order.placed.
export default async function mailerSubscriber({ event, container }: SubscriberArgs<Record<string, unknown>>) {
  const data = (event.data ?? {}) as Record<string, unknown>
  if (skipEvent(data)) {
    return
  }
  const mailer: MailerModuleService = container.resolve(MAILER_MODULE)
  const rules = (await mailer.listMailerRules({ event: event.name, active: true })) as unknown as Array<RuleInput & { id: string }>
  if (!rules.length) {
    return
  }
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)
  const context = await loadContext(container, event.name, data)
  for (const rule of rules) {
    try {
      const outcome = await deliver(container, rule, context)
      if (outcome === "sent") {
        logger.info(`mailer: ${rule.name} sent on ${event.name}`)
      }
    } catch (error) {
      // One rule's failure never stops the others; its delivery, when
      // recorded, is retried by jobs/mailer-retry.
      logger.error(`mailer: ${rule.name} on ${event.name}: ${(error as Error).message}`)
    }
  }
}

export const config: SubscriberConfig = {
  event: mailerEvents(process.env),
  context: { subscriberId: "gosite-mailer" },
}
