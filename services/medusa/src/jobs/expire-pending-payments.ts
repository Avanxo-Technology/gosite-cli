import type { MedusaContainer } from "@medusajs/framework/types"
import { ContainerRegistrationKeys, MedusaError, Modules } from "@medusajs/framework/utils"
import { cancelOrderWorkflow } from "@medusajs/medusa/core-flows"

import {
  allPages,
  awaitingPayment,
  PAID_AFTER_CANCEL,
  paidAfterCancel,
  pendingWindow,
  settlePendingOrders,
  type AwaitingOrder,
  type PaymentCheck,
} from "../lib/pending-payments"

// Settles orders placed before their payment was confirmed (see
// lib/pending-payments): authorizes the ones the provider now reports paid,
// cancels the ones whose payment failed or never came, which releases their
// reserved stock, and reports a payment that arrived after its order was
// cancelled.
export const config = {
  name: "expire-pending-payments",
  schedule: "*/5 * * * *",
}

// Only recent orders can still be awaiting payment: the longest wait is
// maxHours, and a day more covers a job that was down for a while.
const LOOKBACK_EXTRA_HOURS = 24
const BATCH = 200

export default async function expirePendingPayments(container: MedusaContainer) {
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)
  const query = container.resolve(ContainerRegistrationKeys.QUERY)
  const paymentModule = container.resolve(Modules.PAYMENT)
  const orderModule = container.resolve(Modules.ORDER)

  const window = pendingWindow(process.env)
  const now = new Date()
  const since = new Date(now.getTime() - (window.maxHours + LOOKBACK_EXTRA_HOURS) * 3_600_000)

  // Cancelling does not change created_at, so the pages stay stable while the
  // job reads them.
  const orders = await allPages(async (skip, take) => {
    const { data } = await query.graph({
      entity: "order",
      fields: [
        "id",
        "created_at",
        "status",
        "metadata",
        "payment_collections.status",
        "payment_collections.payment_sessions.id",
        "payment_collections.payment_sessions.status",
        "payment_collections.payment_sessions.provider_id",
      ],
      filters: { created_at: { $gte: since } },
      pagination: { skip, take, order: { created_at: "ASC" } },
    })
    return data as unknown as AwaitingOrder[]
  }, BATCH)

  const result = await settlePendingOrders(
    awaitingPayment(orders),
    {
      // Authorizing the session asks the provider: a payment record means it
      // was paid (the webhook may never have arrived); null means it is still
      // deferred; NOT_ALLOWED means the provider reported it failed. Any other
      // error (the provider unreachable) is left for the next run.
      async checkPayment(sessionID: string): Promise<PaymentCheck> {
        try {
          const payment = await paymentModule.authorizePaymentSession(sessionID, {})
          if (payment) {
            return "paid"
          }
        } catch (error) {
          if (MedusaError.isMedusaError(error) && (error as MedusaError).type === MedusaError.Types.NOT_ALLOWED) {
            return "failed"
          }
          throw error
        }
        const session = await paymentModule.retrievePaymentSession(sessionID, { select: ["data"] })
        return session.data?.transaction_status && session.data.transaction_status !== "none"
          ? "started"
          : "pending"
      },
      async cancelOrder(orderID: string) {
        await cancelOrderWorkflow(container).run({ input: { order_id: orderID, no_notification: true } })
      },
    },
    now,
    window
  )

  for (const id of paidAfterCancel(orders)) {
    logger.error(
      `expire-pending-payments: order ${id} was paid after it was cancelled; refund the payment or place the order again`
    )
    const order = orders.find((o) => o.id === id)
    await orderModule.updateOrders(id, { metadata: { ...(order?.metadata ?? {}), [PAID_AFTER_CANCEL]: now.toISOString() } })
  }
  for (const { id, error } of result.failed) {
    logger.warn(`expire-pending-payments: could not settle order ${id}: ${error}`)
  }
  if (result.paid.length || result.canceled.length) {
    logger.info(
      `expire-pending-payments: ${result.paid.length} paid, ${result.canceled.length} cancelled, ${result.waiting.length} still awaiting payment`
    )
  }
}
