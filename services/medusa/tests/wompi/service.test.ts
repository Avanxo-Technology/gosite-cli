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
