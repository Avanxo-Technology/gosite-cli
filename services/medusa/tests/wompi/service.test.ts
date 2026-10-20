import test from "node:test"
import assert from "node:assert/strict"

import WompiProviderService from "../../src/modules/wompi/service.ts"

// Medusa constructs a provider with the container's cradle, which holds
// dependencies as properties and has no resolve().
const cradle = {
  logger: { info() {}, warn() {}, error() {}, debug() {} },
}

const options = {
  publicKey: "pub_test_123",
  privateKey: "prv_test_123",
  integritySecret: "integrity-secret",
  eventsSecret: "events-secret",
}

test("the provider loads from a cradle with no resolve()", () => {
  assert.doesNotThrow(() => new WompiProviderService(cradle as never, options))
})

test("initiatePayment references the session id Medusa passes", async () => {
  const service = new WompiProviderService(cradle as never, options)
  const output = await service.initiatePayment({
    data: { session_id: "payses_1" },
    amount: 59900,
    currency_code: "cop",
    context: {},
  } as never)
  const url = new URL(output.data?.checkout_url as string)
  assert.equal(url.searchParams.get("reference"), "payses_1")
})

// withWompi answers Wompi's transaction lookup with the given transactions (or
// an HTTP status) for the duration of fn.
async function withWompi(answer: Array<{ id: string; status: string }> | number, fn: () => Promise<void>) {
  const original = globalThis.fetch
  globalThis.fetch = (async () =>
    typeof answer === "number"
      ? new Response("down", { status: answer })
      : new Response(JSON.stringify({ data: answer }), { status: 200 })) as typeof fetch
  try {
    await fn()
  } finally {
    globalThis.fetch = original
  }
}

const authorize = (service: WompiProviderService) =>
  service.authorizePayment({ data: { reference: "payses_1" }, context: {} } as never)

test("before the buyer pays, authorizePayment lets the order wait for the payment", async () => {
  const service = new WompiProviderService(cradle as never, options)
  await withWompi([], async () => {
    const output = await authorize(service)
    assert.equal(output.status, "pending_authorization")
    assert.equal(output.data?.transaction_status, "none")
  })
  await withWompi([{ id: "tx_1", status: "PENDING" }], async () => {
    const output = await authorize(service)
    assert.equal(output.status, "pending_authorization")
    assert.equal(output.data?.transaction_status, "pending")
    assert.equal(output.data?.transaction_id, "tx_1")
  })
})

test("an approved transaction is captured and a declined one fails", async () => {
  const service = new WompiProviderService(cradle as never, options)
  await withWompi([{ id: "tx_1", status: "APPROVED" }], async () => {
    assert.equal((await authorize(service)).status, "captured")
  })
  await withWompi([{ id: "tx_1", status: "DECLINED" }], async () => {
    assert.equal((await authorize(service)).status, "error")
  })
})

test("an unreachable Wompi throws instead of passing for an unpaid order", async () => {
  const service = new WompiProviderService(cradle as never, options)
  await withWompi(503, async () => {
    await assert.rejects(() => authorize(service), /lookup failed: 503/)
  })
})

test("the checkout url expires when configured, and empty URLs fall back to Wompi's", async () => {
  const service = new WompiProviderService(cradle as never, {
    ...options,
    checkoutURL: "",
    baseURL: "",
    expirationMinutes: 60,
  })
  const before = Date.now()
  const output = await service.initiatePayment({
    data: { session_id: "payses_1" },
    amount: 59900,
    currency_code: "cop",
    context: {},
  } as never)
  const url = new URL(output.data?.checkout_url as string)
  assert.equal(url.origin + url.pathname, "https://checkout.wompi.co/p/")
  const expires = Date.parse(url.searchParams.get("expiration-time") ?? "")
  assert.ok(expires >= before + 59 * 60_000 && expires <= Date.now() + 60 * 60_000)
})
