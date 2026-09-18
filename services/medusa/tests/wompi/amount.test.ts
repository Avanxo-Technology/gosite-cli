import test from "node:test"
import assert from "node:assert/strict"

import { fromCents, toCents } from "../../src/modules/wompi/wompi.ts"

test("COP is multiplied by 100 like every Wompi currency", () => {
  // The spec's example: a 59.900 COP cart is 5990000 to Wompi.
  assert.equal(toCents("59900"), 5990000)
  assert.equal(toCents(59900), 5990000)
  assert.equal(fromCents(5990000), "59900")
})

test("USD uses two decimals exactly", () => {
  // The bug this guards: 19.99 * 100 in floating point is 1998.9999999999998.
  assert.equal(toCents("19.99"), 1999)
  assert.equal(toCents(19.99), 1999)
  assert.equal(fromCents(1999), "19.99")
})

test("round trips without drift", () => {
  for (const amount of ["19.99", "0.01", "1000.00", "59900", "0", "0.00"]) {
    assert.equal(fromCents(toCents(amount)), amount.replace(/\.00$/, ""))
  }
})

test("rejects more precision than the currency allows", () => {
  assert.throws(() => toCents("19.999"), /more precision/)
})

test("rejects malformed amounts", () => {
  assert.throws(() => toCents(""), /invalid amount/)
  assert.throws(() => toCents("abc"), /invalid amount/)
})

test("negative amounts keep their sign", () => {
  assert.equal(toCents("-19.99"), -1999)
  assert.equal(fromCents(-1999), "-19.99")
})
