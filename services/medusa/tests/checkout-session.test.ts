import test from "node:test"
import assert from "node:assert/strict"

import {
  decideSession,
  normalizeEmail,
  sharedTokenMatches,
  type SessionOrder,
} from "../src/lib/checkout-session.ts"

const now = new Date("2026-10-20T12:00:00Z")
const paid: SessionOrder = {
  id: "order_1",
  email: "compras@empresa.com",
  createdAt: new Date("2026-10-20T11:00:00Z"),
  canceled: false,
  paid: true,
}

test("a paid order with a new address creates the account", () => {
  assert.deepEqual(decideSession(paid, null, now), { kind: "create" })
})

test("an address with an account gets the order, never a session", () => {
  assert.deepEqual(decideSession(paid, { customerID: "cus_other" }, now), {
    kind: "existing_account",
    customerID: "cus_other",
  })
})

test("the account this order created opens again from the same order", () => {
  const order = { ...paid, accountCreatedFor: "cus_1" }
  assert.deepEqual(decideSession(order, { customerID: "cus_1" }, now), { kind: "reissue", customerID: "cus_1" })
})

test("no session before payment, after cancellation or after the window", () => {
  assert.deepEqual(decideSession({ ...paid, paid: false }, null, now), { kind: "pending" })
  assert.deepEqual(decideSession({ ...paid, canceled: true }, null, now), { kind: "canceled" })
  const late = new Date(paid.createdAt.getTime() + 25 * 3_600_000)
  assert.deepEqual(decideSession(paid, null, late), { kind: "expired" })
  assert.deepEqual(decideSession({ ...paid, accountCreatedFor: "cus_1" }, { customerID: "cus_1" }, late), {
    kind: "expired",
  })
})

test("addresses are compared trimmed and in lower case", () => {
  assert.equal(normalizeEmail("  Compras@Empresa.COM "), "compras@empresa.com")
})

test("the shared token must be configured and match", () => {
  assert.equal(sharedTokenMatches("secret", "secret"), true)
  assert.equal(sharedTokenMatches("other1", "secret"), false)
  assert.equal(sharedTokenMatches("secret", "secret-longer"), false)
  assert.equal(sharedTokenMatches(undefined, "secret"), false)
  assert.equal(sharedTokenMatches("", ""), false)
  assert.equal(sharedTokenMatches("anything", undefined), false)
})
