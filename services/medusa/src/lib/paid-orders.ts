// Orders whose payment was confirmed and that have not been announced yet.
// Medusa emits no event when a deferred payment is confirmed (Wompi reports it
// captured while authorizing), so jobs/notify-paid-orders emits
// gosite.order.paid for these. Pure, unit-tested with node --test.

// PAID_ANNOUNCED is the order metadata key set once gosite.order.paid was
// emitted, so each order is announced once.
export const PAID_ANNOUNCED = "gosite_paid_announced_at"

// Only payments confirmed within this window are announced: turning the job
// on (a new release) never announces last week's orders.
export const ANNOUNCE_WINDOW_MS = 2 * 3_600_000

const PAID = new Set(["authorized", "partially_authorized", "completed", "partially_captured"])

export interface PaidOrderRow {
  id: string
  status?: string
  metadata?: Record<string, unknown> | null
  payment_collections?: Array<{
    status?: string
    payments?: Array<{ created_at?: string | Date | null } | null> | null
  } | null> | null
}

export function newlyPaid(orders: PaidOrderRow[], now: Date, windowMs = ANNOUNCE_WINDOW_MS): string[] {
  const since = now.getTime() - windowMs
  return orders
    .filter((order) => {
      if (order.status === "canceled" || order.status === "draft" || order.metadata?.[PAID_ANNOUNCED]) {
        return false
      }
      return (order.payment_collections ?? []).some(
        (collection) =>
          PAID.has(String(collection?.status)) &&
          (collection?.payments ?? []).some((payment) => {
            const at = payment?.created_at ? new Date(payment.created_at).getTime() : NaN
            return at >= since
          })
      )
    })
    .map((order) => order.id)
}
