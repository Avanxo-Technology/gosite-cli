import type { MedusaContainer } from "@medusajs/framework/types"
import { ContainerRegistrationKeys, Modules } from "@medusajs/framework/utils"

import { GOSITE_ORDER_PAID } from "../lib/mailer/rules"
import { allPages, pendingWindow } from "../lib/pending-payments"
import { newlyPaid, PAID_ANNOUNCED, type PaidOrderRow } from "../lib/paid-orders"

// Emits gosite.order.paid once per order whose payment was confirmed: by
// Wompi's webhook, by expire-pending-payments catching a lost webhook, or by
// any other provider. Medusa itself emits nothing in the first two cases, so
// this is the event to send the "payment received" e-mail on. Runs every
// minute: the e-mail follows the payment within about a minute.
export const config = {
  name: "notify-paid-orders",
  schedule: "* * * * *",
}

const BATCH = 200

export default async function notifyPaidOrders(container: MedusaContainer) {
  const query = container.resolve(ContainerRegistrationKeys.QUERY)
  const eventBus = container.resolve(Modules.EVENT_BUS)
  const orderModule = container.resolve(Modules.ORDER)
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)

  const now = new Date()
  // A deferred payment can be confirmed up to maxHours after its order.
  const since = new Date(now.getTime() - (pendingWindow(process.env).maxHours + 24) * 3_600_000)
  const orders = await allPages(async (skip, take) => {
    const { data } = await query.graph({
      entity: "order",
      fields: ["id", "status", "metadata", "payment_collections.status", "payment_collections.payments.created_at"],
      filters: { created_at: { $gte: since } },
      pagination: { skip, take, order: { created_at: "ASC" } },
    })
    return data as unknown as PaidOrderRow[]
  }, BATCH)

  for (const id of newlyPaid(orders, now)) {
    const order = orders.find((o) => o.id === id)
    try {
      // Emitted before the flag: a crash in between repeats the event, and
      // the mailer's once-per-order rule keeps the e-mail single.
      await eventBus.emit({ name: GOSITE_ORDER_PAID, data: { id } })
      await orderModule.updateOrders(id, { metadata: { ...(order?.metadata ?? {}), [PAID_ANNOUNCED]: now.toISOString() } })
    } catch (error) {
      logger.warn(`notify-paid-orders: order ${id}: ${(error as Error).message}`)
    }
  }
}
