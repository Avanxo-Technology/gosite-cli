// Orders placed before their payment is confirmed. A redirect provider (Wompi)
// answers pending_authorization while the buyer has not paid: Medusa then
// creates the order and reserves its stock, and the payment is authorized when
// the provider confirms it. settlePendingOrders is the safety net the
// expire-pending-payments job runs: it asks the provider again (catching a
// webhook that never arrived), cancels an order whose payment failed, and
// cancels one nobody paid in time, which releases its reservations.

// PaymentCheck is what the provider says about an order's payment now.
// "started" means the buyer began paying and the provider has not decided yet
// (a PSE transfer can take a while); "pending" means nothing was started.
export type PaymentCheck = "paid" | "pending" | "started" | "failed"

export interface PendingWindow {
  // An order nobody started paying is cancelled after this.
  ttlMinutes: number
  // An order whose payment is in progress is cancelled after this.
  maxHours: number
}

export const DEFAULT_WINDOW: PendingWindow = { ttlMinutes: 60, maxHours: 24 }

// pendingWindow reads the window from the environment. An unset, zero or
// invalid value keeps the default, so a typo never cancels orders early.
export function pendingWindow(env: Record<string, string | undefined>): PendingWindow {
  const positive = (value: string | undefined, fallback: number) => {
    const n = Number(value)
    return value && Number.isFinite(n) && n > 0 ? n : fallback
  }
  return {
    ttlMinutes: positive(env.COMMERCE_PENDING_PAYMENT_TTL_MINUTES, DEFAULT_WINDOW.ttlMinutes),
    maxHours: positive(env.COMMERCE_PENDING_PAYMENT_MAX_HOURS, DEFAULT_WINDOW.maxHours),
  }
}

// shouldCancel decides, for an unpaid order of the given age, whether its
// stock goes back.
export function shouldCancel(check: PaymentCheck, ageMs: number, window: PendingWindow): boolean {
  switch (check) {
    case "failed":
      return true
    case "pending":
      return ageMs >= window.ttlMinutes * 60_000
    case "started":
      return ageMs >= window.maxHours * 3_600_000
    default:
      return false
  }
}

export interface PendingOrder {
  id: string
  createdAt: Date
  // The payment session awaiting authorization.
  sessionID: string
}

export interface PendingStore {
  checkPayment(sessionID: string): Promise<PaymentCheck>
  cancelOrder(orderID: string): Promise<void>
}

export interface SettleResult {
  paid: string[]
  canceled: string[]
  waiting: string[]
  // Orders whose check or cancellation threw; they are retried on the next run.
  failed: Array<{ id: string; error: string }>
}

// settlePendingOrders checks each order once. One order's failure never stops
// the others.
export async function settlePendingOrders(
  orders: PendingOrder[],
  store: PendingStore,
  now: Date,
  window: PendingWindow
): Promise<SettleResult> {
  const result: SettleResult = { paid: [], canceled: [], waiting: [], failed: [] }
  for (const order of orders) {
    try {
      const check = await store.checkPayment(order.sessionID)
      if (check === "paid") {
        result.paid.push(order.id)
      } else if (shouldCancel(check, now.getTime() - order.createdAt.getTime(), window)) {
        await store.cancelOrder(order.id)
        result.canceled.push(order.id)
      } else {
        result.waiting.push(order.id)
      }
    } catch (error) {
      result.failed.push({ id: order.id, error: String((error as Error)?.message ?? error) })
    }
  }
  return result
}

// AwaitingOrder is the slice of an order the job reads from Medusa's query.
export interface AwaitingOrder {
  id: string
  created_at: string | Date
  status?: string
  metadata?: Record<string, unknown> | null
  payment_collections?: Array<{
    status?: string
    payment_sessions?: Array<{ id: string; status?: string; provider_id?: string }>
  } | null> | null
}

// WOMPI_PROVIDER is the payment provider whose deferred sessions the job
// settles. Other providers (Stripe) keep their own lifecycle: a session of
// theirs awaiting authorization is never cancelled here.
export const WOMPI_PROVIDER = "pp_wompi_wompi"

// awaitingPayment picks the orders whose payment is still awaited, with the
// session to check: an open order, an awaiting collection and a Wompi session
// in pending_authorization. Paid, cancelled, manual-payment and other
// providers' orders are left alone.
export function awaitingPayment(orders: AwaitingOrder[]): PendingOrder[] {
  const pending: PendingOrder[] = []
  for (const order of orders) {
    if (order.status === "canceled" || order.status === "archived" || order.status === "draft") {
      continue
    }
    for (const collection of order.payment_collections ?? []) {
      if (collection?.status !== "awaiting") {
        continue
      }
      const session = collection.payment_sessions?.find(
        (s) => s.status === "pending_authorization" && s.provider_id === WOMPI_PROVIDER
      )
      if (session) {
        pending.push({ id: order.id, createdAt: new Date(order.created_at), sessionID: session.id })
        break
      }
    }
  }
  return pending
}

// allPages reads every page of a listing, take rows at a time, until a short
// page. The job reads all recent orders this way: one page would leave the
// newest ones unchecked on a shop with more orders than a page holds.
export async function allPages<T>(fetchPage: (skip: number, take: number) => Promise<T[]>, take: number): Promise<T[]> {
  const rows: T[] = []
  for (let skip = 0; ; skip += take) {
    const page = await fetchPage(skip, take)
    rows.push(...page)
    if (page.length < take) {
      return rows
    }
  }
}

// PAID_AFTER_CANCEL is the order metadata key set once a payment was found on
// a cancelled order, so it is reported once and not on every run.
export const PAID_AFTER_CANCEL = "gosite_paid_after_cancel"

// paidAfterCancel finds cancelled orders that hold an authorized or captured
// payment not reported yet: the buyer paid after the order expired (the
// checkout URL's expiry makes this rare). The money has to be refunded, or the
// order placed again, by a person.
export function paidAfterCancel(orders: AwaitingOrder[]): string[] {
  const paidStatuses = new Set(["authorized", "partially_authorized", "completed", "partially_captured"])
  return orders
    .filter(
      (order) =>
        order.status === "canceled" &&
        !order.metadata?.[PAID_AFTER_CANCEL] &&
        (order.payment_collections ?? []).some((c) => paidStatuses.has(String(c?.status)))
    )
    .map((order) => order.id)
}
