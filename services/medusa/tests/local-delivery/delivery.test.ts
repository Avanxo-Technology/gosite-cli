import test from "node:test"
import assert from "node:assert/strict"

import {
  DeliveryError,
  itemsWeight,
  parseRates,
  quote,
  type DeliveryCart,
  type DeliveryRates,
} from "../../src/modules/local-delivery/delivery.ts"

const rates: DeliveryRates = parseRates({
  city: "Barranquilla",
  areas: { Centro: 0, "El Prado": 4.0, Riomar: 8.1, "Barrio Abajo": 2.1 },
  base_amount: 10000,
  included_km: 3,
  per_km: 1000,
  round_to: 1000,
  free_from: 300000,
  default_weight_grams: 500,
  weight_tiers: [
    { up_to_grams: 5000, surcharge: 0 },
    { up_to_grams: 10000, surcharge: 3000 },
    { up_to_grams: 15000, surcharge: 6000 },
    { surcharge: 15000 },
  ],
})

function cart(area: string, items: DeliveryCart["items"], city = "Barranquilla"): DeliveryCart {
  return { items, shipping_address: { city, metadata: { area } } }
}

const boots = { unit_price: 90000, quantity: 1, variant: { weight: 1800 }, product: { weight: null } }

test("within the included km the base amount applies", () => {
  assert.equal(quote(rates, cart("Centro", [boots])).amount, 10000)
  assert.equal(quote(rates, cart("Barrio Abajo", [boots])).amount, 10000)
})

test("every km or part of one past the included adds per_km", () => {
  // 4.0 km is one km past 3, not two from float noise.
  assert.equal(quote(rates, cart("El Prado", [boots])).amount, 11000)
  // 8.1 km: 5.1 past 3 -> 6 km.
  assert.equal(quote(rates, cart("Riomar", [boots])).amount, 16000)
})

test("the area matches without case or accents and answers the table's spelling", () => {
  const q = quote(rates, cart("el prado", [boots]))
  assert.equal(q.area, "El Prado")
  assert.equal(q.km, 4)
  assert.equal(quote(rates, { items: [boots], shipping_address: { city: "BARRANQUILLA ", metadata: { area: "Centro" } } }).amount, 10000)
})

test("weight tiers add their surcharge", () => {
  // Cheap pairs, so no order reaches free_from.
  const pairs = (n: number) => [{ ...boots, unit_price: 10000, quantity: n }]
  assert.equal(quote(rates, cart("Centro", pairs(2))).amount, 10000) // 3.6 kg
  assert.equal(quote(rates, cart("Centro", pairs(3))).amount, 13000) // 5.4 kg
  assert.equal(quote(rates, cart("Centro", pairs(6))).amount, 16000) // 10.8 kg
  assert.equal(quote(rates, cart("Centro", pairs(9))).amount, 25000) // 16.2 kg: the open tier
  assert.equal(quote(rates, cart("El Prado", pairs(3))).amount, 14000) // distance and weight add up
})

test("weight falls back to the product's, then the default", () => {
  const items = [
    { unit_price: 1, quantity: 2, variant: { weight: null }, product: { weight: 700 } },
    { unit_price: 1, quantity: 3, variant: null, product: null },
  ]
  assert.equal(itemsWeight({ items }, 500), 2 * 700 + 3 * 500)
})

test("orders from free_from are free, wherever they go and however heavy", () => {
  const q = quote(rates, cart("Riomar", [{ ...boots, unit_price: 100000, quantity: 3 }]))
  assert.equal(q.amount, 0)
  assert.equal(q.free, true)
  // 1 peso short: Riomar's 16.000 plus 3.000 for 5.4 kg.
  assert.equal(quote(rates, cart("Riomar", [{ ...boots, unit_price: 99999, quantity: 3 }])).amount, 19000)
})

test("amounts arrive as BigNumber objects or strings", () => {
  const items = [{ unit_price: { numeric: 150000 }, quantity: "2", variant: { weight: { value: "1800" } } }]
  assert.equal(quote(rates, cart("Centro", items)).amount, 0)
})

test("another city or an area outside the table is refused", () => {
  assert.throws(() => quote(rates, cart("Centro", [boots], "Soledad")), (e: DeliveryError) => e.code === "city")
  assert.throws(() => quote(rates, cart("Villa Campestre", [boots])), (e: DeliveryError) => e.code === "area")
  assert.throws(() => quote(rates, { items: [boots], shipping_address: { city: "Barranquilla" } }), (e: DeliveryError) => e.code === "area")
  assert.throws(() => quote(rates, { items: [boots] }), (e: DeliveryError) => e.code === "city")
})

test("an area outside the table is refused even when the order is free", () => {
  assert.throws(() => quote(rates, cart("Villa Campestre", [{ ...boots, quantity: 10 }])), DeliveryError)
})

test("without tiers or rounding the distance alone prices it", () => {
  const plain = parseRates({ city: "X", areas: { A: 5.5 }, base_amount: 8000, included_km: 3, per_km: 700 })
  assert.equal(quote(plain, { items: [boots], shipping_address: { city: "x", metadata: { area: "a" } } }).amount, 8000 + 3 * 700)
})

test("parseRates names the field that is wrong", () => {
  const ok = { city: "X", areas: { A: 1 }, base_amount: 1, included_km: 0, per_km: 1 }
  assert.doesNotThrow(() => parseRates(ok))
  assert.throws(() => parseRates({ ...ok, city: "" }), /city/)
  assert.throws(() => parseRates({ ...ok, areas: {} }), /areas/)
  assert.throws(() => parseRates({ ...ok, areas: { A: "far" } }), /areas\["A"\]/)
  assert.throws(() => parseRates({ ...ok, per_km: -1 }), /per_km/)
  assert.throws(() => parseRates({ ...ok, free_from: "x" }), /free_from/)
  assert.throws(() => parseRates({ ...ok, weight_tiers: [] }), /weight_tiers/)
  assert.throws(() => parseRates({ ...ok, weight_tiers: [{ up_to_grams: 5, surcharge: 0 }] }), /last tier/)
  assert.throws(
    () => parseRates({ ...ok, weight_tiers: [{ up_to_grams: 5, surcharge: 0 }, { up_to_grams: 5, surcharge: 1 }, { surcharge: 2 }] }),
    /weight_tiers\[1\]\.up_to_grams/,
  )
  assert.throws(() => parseRates(undefined), /city/)
})
