import test from "node:test"
import assert from "node:assert/strict"
import { createHash } from "node:crypto"

import {
  buildCheckoutURL,
  integritySignature,
  mapStatus,
  type EventPayload,
  verifyEventChecksum,
} from "../../src/modules/wompi/wompi.ts"

test("status mapping", () => {
  assert.equal(mapStatus("APPROVED"), "authorized")
  assert.equal(mapStatus("PENDING"), "pending")
  assert.equal(mapStatus("DECLINED"), "error")
  assert.equal(mapStatus("VOIDED"), "error")
  assert.equal(mapStatus("ERROR"), "error")
})

test("integrity signature is sha256 of reference+amount+currency+secret", () => {
  const expected = createHash("sha256").update("REF-1" + "5990000" + "COP" + "secret").digest("hex")
  assert.equal(integritySignature("REF-1", 5990000, "COP", "secret"), expected)
})

test("checkout url carries the amount in cents and the signature", () => {
  const url = new URL(
    buildCheckoutURL({
      baseURL: "https://checkout.wompi.co/p",
      publicKey: "pub_test_123",
      reference: "pay_1",
      amount: "59900",
      currency: "COP",
      redirectURL: "https://shop.example.com/checkout/retorno",
      integritySecret: "secret",
    })
  )
  assert.equal(url.searchParams.get("amount-in-cents"), "5990000")
  assert.equal(url.searchParams.get("reference"), "pay_1")
  assert.equal(url.searchParams.get("currency"), "COP")
  assert.equal(
    url.searchParams.get("signature:integrity"),
    createHash("sha256").update("pay_1" + "5990000" + "COP" + "secret").digest("hex")
  )
})

test("a valid event checksum is accepted and a forged one rejected", () => {
  const secret = "events-secret"
  const event: EventPayload = {
    event: "transaction.updated",
    timestamp: 1700000000,
    data: { transaction: { id: "tx_1", status: "APPROVED", amount_in_cents: 5990000 } },
    signature: {
      properties: ["transaction.id", "transaction.status", "transaction.amount_in_cents"],
    },
  }
  const checksum = createHash("sha256")
    .update("tx_1" + "APPROVED" + "5990000" + "1700000000" + secret)
    .digest("hex")
  event.signature!.checksum = checksum

  assert.equal(verifyEventChecksum(event, secret), true)
  const forged = (checksum[0] === "0" ? "1" : "0") + checksum.slice(1)
  assert.equal(verifyEventChecksum({ ...event, signature: { ...event.signature, checksum: forged } }, secret), false)
  assert.equal(verifyEventChecksum(event, "wrong-secret"), false)
  assert.equal(verifyEventChecksum({ event: "x" }, secret), false)
})

test("checksum accepts sent_at when timestamp is absent", () => {
  const secret = "s"
  const event: EventPayload = {
    sent_at: "2026-01-01T00:00:00Z",
    data: { transaction: { id: "t" } },
    signature: { properties: ["transaction.id"] },
  }
  event.signature!.checksum = createHash("sha256").update("t" + "2026-01-01T00:00:00Z" + secret).digest("hex")
  assert.equal(verifyEventChecksum(event, secret), true)
})
