import test from "node:test"
import assert from "node:assert/strict"

import {
  allPages,
  awaitingPayment,
  DEFAULT_WINDOW,
  PAID_AFTER_CANCEL,
  paidAfterCancel,
  pendingWindow,
  settlePendingOrders,
  shouldCancel,
  type PaymentCheck,
} from "../src/lib/pending-payments.ts"

const MIN = 60_000
const HOUR = 60 * MIN

test("pendingWindow defaults to 60 minutes and 24 hours, and ignores bad values", () => {
  assert.deepEqual(pendingWindow({}), DEFAULT_WINDOW)
  assert.deepEqual(
    pendingWindow({ COMMERCE_PENDING_PAYMENT_TTL_MINUTES: "30", COMMERCE_PENDING_PAYMENT_MAX_HOURS: "48" }),
    { ttlMinutes: 30, maxHours: 48 }
  )
  for (const bad of ["0", "-5", "abc", ""]) {
    assert.deepEqual(pendingWindow({ COMMERCE_PENDING_PAYMENT_TTL_MINUTES: bad }), DEFAULT_WINDOW)
  }
})

test("an order nobody started paying is cancelled at the ttl", () => {
  assert.equal(shouldCancel("pending", 59 * MIN, DEFAULT_WINDOW), false)
  assert.equal(shouldCancel("pending", 60 * MIN, DEFAULT_WINDOW), true)
})

test("a payment in progress waits until the maximum, a failed one goes at once", () => {
  assert.equal(shouldCancel("started", 2 * HOUR, DEFAULT_WINDOW), false)
  assert.equal(shouldCancel("started", 24 * HOUR, DEFAULT_WINDOW), true)
  assert.equal(shouldCancel("failed", 1 * MIN, DEFAULT_WINDOW), true)
  assert.equal(shouldCancel("paid", 48 * HOUR, DEFAULT_WINDOW), false)
})

test("settlePendingOrders authorizes, cancels and waits, and survives a failing order", async () => {
  const now = new Date("2026-10-20T12:00:00Z")
  const ago = (ms: number) => new Date(now.getTime() - ms)
  const checks: Record<string, PaymentCheck | Error> = {
    s_paid: "paid",
    s_young: "pending",
    s_old: "pending",
    s_pse: "started",
    s_declined: "failed",
    s_down: new Error("wompi unreachable"),
  }
  const canceled: string[] = []
  const result = await settlePendingOrders(
    [
      { id: "o_paid", createdAt: ago(2 * HOUR), sessionID: "s_paid" },
      { id: "o_young", createdAt: ago(10 * MIN), sessionID: "s_young" },
      { id: "o_old", createdAt: ago(61 * MIN), sessionID: "s_old" },
      { id: "o_pse", createdAt: ago(3 * HOUR), sessionID: "s_pse" },
      { id: "o_declined", createdAt: ago(2 * MIN), sessionID: "s_declined" },
      { id: "o_down", createdAt: ago(5 * HOUR), sessionID: "s_down" },
    ],
    {
      async checkPayment(id) {
        const check = checks[id]
        if (check instanceof Error) throw check
        return check
      },
      async cancelOrder(id) {
        canceled.push(id)
      },
    },
    now,
    DEFAULT_WINDOW
  )
  assert.deepEqual(result.paid, ["o_paid"])
  assert.deepEqual(result.canceled, ["o_old", "o_declined"])
  assert.deepEqual(canceled, ["o_old", "o_declined"])
  assert.deepEqual(result.waiting, ["o_young", "o_pse"])
  assert.deepEqual(result.failed, [{ id: "o_down", error: "wompi unreachable" }])
})

test("awaitingPayment picks open orders with a session awaiting authorization", () => {
  const created_at = "2026-10-20T11:00:00Z"
  const pending = awaitingPayment([
    {
      id: "o_wompi",
      created_at,
      status: "pending",
      payment_collections: [
        { status: "awaiting", payment_sessions: [{ id: "s_1", status: "pending_authorization", provider_id: "pp_wompi_wompi" }] },
      ],
    },
    // Paid, manual and cancelled orders are not touched.
    { id: "o_paid", created_at, status: "pending", payment_collections: [{ status: "completed", payment_sessions: [] }] },
    {
      id: "o_manual",
      created_at,
      status: "pending",
      payment_collections: [{ status: "authorized", payment_sessions: [{ id: "s_2", status: "authorized" }] }],
    },
    {
      id: "o_canceled",
      created_at,
      status: "canceled",
      payment_collections: [
        { status: "awaiting", payment_sessions: [{ id: "s_3", status: "pending_authorization", provider_id: "pp_wompi_wompi" }] },
      ],
    },
    // Another provider's deferred session follows that provider's lifecycle.
    {
      id: "o_stripe",
      created_at,
      status: "pending",
      payment_collections: [
        { status: "awaiting", payment_sessions: [{ id: "s_4", status: "pending_authorization", provider_id: "pp_stripe_stripe" }] },
      ],
    },
    { id: "o_none", created_at, status: "pending", payment_collections: null },
  ])
  assert.deepEqual(pending, [{ id: "o_wompi", createdAt: new Date(created_at), sessionID: "s_1" }])
})

test("allPages reads past the first page and stops at a short one", async () => {
  const rows = Array.from({ length: 5 }, (_, i) => i)
  const read = async (take: number) => {
    const asked: number[] = []
    const all = await allPages(async (skip, size) => {
      asked.push(skip)
      return rows.slice(skip, skip + size)
    }, take)
    return { all, asked }
  }
  assert.deepEqual(await read(2), { all: rows, asked: [0, 2, 4] })
  // A full last page needs one more, empty, read to know it was the last.
  assert.deepEqual(await read(5), { all: rows, asked: [0, 5] })
})

test("a payment on a cancelled order is reported once", () => {
  const created_at = "2026-10-20T11:00:00Z"
  const orders = [
    { id: "o_late", created_at, status: "canceled", payment_collections: [{ status: "completed" }] },
    {
      id: "o_reported",
      created_at,
      status: "canceled",
      metadata: { [PAID_AFTER_CANCEL]: "2026-10-20T11:30:00Z" },
      payment_collections: [{ status: "completed" }],
    },
    { id: "o_unpaid", created_at, status: "canceled", payment_collections: [{ status: "canceled" }] },
    { id: "o_open", created_at, status: "pending", payment_collections: [{ status: "completed" }] },
  ]
  assert.deepEqual(paidAfterCancel(orders), ["o_late"])
})
