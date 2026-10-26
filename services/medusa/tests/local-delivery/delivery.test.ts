import test from "node:test"
import assert from "node:assert/strict"

import {
  DeliveryError,
  distanceKm,
  inRing,
  itemsWeight,
  mostUnits,
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

// Delivery by distance: the store marks its point, the buyer theirs.
const origin = { lat: 10.97964, lng: -74.77872 }
// A point km due north (+) or south (-) of the origin: a degree of latitude
// is 111.19 km.
const north = (km: number) => ({ lat: origin.lat + km / 111.19, lng: origin.lng })
const square = (south: number, north: number, west: number, east: number): Array<[number, number]> => [
  [west, south], [east, south], [east, north], [west, north], [west, south],
]
const byDistance: DeliveryRates = parseRates({
  city: "Barranquilla",
  origin,
  zones: [
    { name: "Norte", rings: [square(origin.lat, 11.1, -74.9, -74.7)] },
    { name: "Sur", rings: [square(10.93, origin.lat, -74.9, -74.7), square(10.89, 10.91, -74.9, -74.7)] },
  ],
  max_km: 12,
  base_amount: 10000,
  included_km: 3,
  per_km: 1000,
  round_to: 1000,
  free_from: 300000,
  default_weight_grams: 500,
  weight_tiers: [{ up_to_grams: 5000, surcharge: 0 }, { surcharge: 3000 }],
  bulk_units: 6,
})

function at(point: { lat: unknown; lng: unknown } | undefined, items: DeliveryCart["items"] = [boots]): DeliveryCart {
  return { items, shipping_address: { city: "Barranquilla", metadata: point ? { ...point } : {} } }
}

test("distanceKm is the straight line, to a tenth of a km", () => {
  assert.equal(distanceKm({ lat: 0, lng: 0 }, { lat: 1, lng: 0 }), 111.2)
  assert.equal(distanceKm(origin, north(5)), 5)
  assert.equal(distanceKm(origin, origin), 0)
})

test("by distance the km from the origin price it, as the table's did", () => {
  assert.equal(quote(byDistance, at(north(2))).amount, 10000)
  const q = quote(byDistance, at(north(5)))
  assert.deepEqual([q.amount, q.km, q.area], [12000, 5, "Norte"])
  // Weight still adds its surcharge: 3 pairs are 5.4 kg.
  assert.equal(quote(byDistance, at(north(5), [{ ...boots, unit_price: 10000, quantity: 3 }])).amount, 15000)
  // And free_from still wins.
  assert.equal(quote(byDistance, at(north(5), [{ ...boots, unit_price: 100000, quantity: 3 }])).free, true)
})

test("the zone is the one whose ring holds the point, any of its rings", () => {
  assert.equal(quote(byDistance, at(north(-4))).area, "Sur")
  assert.equal(quote(byDistance, at({ lat: 10.9, lng: -74.78 })).area, "Sur")
  assert.equal(inRing({ lat: 1, lng: 1 }, square(0, 2, 0, 2)), true)
  assert.equal(inRing({ lat: 3, lng: 1 }, square(0, 2, 0, 2)), false)
})

test("coordinates may arrive as strings", () => {
  const p = north(5)
  assert.equal(quote(byDistance, at({ lat: String(p.lat), lng: String(p.lng) })).amount, 12000)
})

test("a point outside the zones, past max_km or missing is refused", () => {
  const outside = { lat: 10.92, lng: -74.78 } // between the two rings of Sur
  assert.throws(() => quote(byDistance, at(outside)), (e: DeliveryError) => e.code === "zone")
  assert.throws(() => quote(byDistance, at(north(13))), (e: DeliveryError) => e.code === "zone")
  assert.throws(() => quote(byDistance, at(undefined)), (e: DeliveryError) => e.code === "location")
  assert.throws(() => quote(byDistance, at({ lat: "x", lng: 1 })), (e: DeliveryError) => e.code === "location")
  // Free orders are refused there too.
  assert.throws(() => quote(byDistance, at(outside, [{ ...boots, unit_price: 100000, quantity: 3 }])), DeliveryError)
})

test("without zones any point within max_km is delivered to", () => {
  const anywhere = parseRates({ city: "X", origin, max_km: 10, base_amount: 1000, included_km: 0, per_km: 100 })
  const q = quote(anywhere, { items: [boots], shipping_address: { city: "X", metadata: north(9) } })
  assert.deepEqual([q.amount, q.area], [1000 + 9 * 100, ""])
})

test("bulk_units of one product, across its variants, is arranged with the store", () => {
  const pair = (variant: string, quantity: number) => ({ ...boots, product_id: "prod_boot", variant_id: variant, quantity })
  assert.equal(mostUnits({ items: [pair("v38", 3), pair("v40", 2), { ...boots, product_id: "prod_vest", quantity: 4 }] }), 5)
  assert.doesNotThrow(() => quote(byDistance, at(north(5), [pair("v38", 3), pair("v40", 2)])))
  assert.throws(() => quote(byDistance, at(north(5), [pair("v38", 3), pair("v40", 3)])), (e: DeliveryError) => e.code === "bulk")
  // Many products, few of each, is not bulk.
  const mixed = ["a", "b", "c", "d"].map((id) => ({ ...boots, product_id: id, quantity: 5 }))
  assert.doesNotThrow(() => quote(byDistance, at(north(5), mixed)))
  // The area table takes bulk_units too.
  const table = parseRates({ ...rates, bulk_units: 6 })
  assert.throws(() => quote(table, cart("Centro", [pair("v38", 6)])), (e: DeliveryError) => e.code === "bulk")
})

test("parseRates checks the distance fields", () => {
  const ok = { city: "X", origin, base_amount: 1, included_km: 0, per_km: 1 }
  assert.doesNotThrow(() => parseRates(ok))
  assert.throws(() => parseRates({ ...ok, areas: { A: 1 } }), /not both/)
  const { origin: _, ...neither } = ok
  assert.throws(() => parseRates(neither), /areas or origin/)
  assert.throws(() => parseRates({ ...ok, origin: { lat: 91, lng: 0 } }), /origin/)
  assert.throws(() => parseRates({ ...ok, zones: [] }), /zones/)
  assert.throws(() => parseRates({ ...ok, zones: [{ name: "", rings: [square(0, 1, 0, 1)] }] }), /zones\[0\]\.name/)
  assert.throws(() => parseRates({ ...ok, zones: [{ name: "A", rings: [[[0, 0], [1, 1]]] }] }), /zones\[0\]\.rings/)
  assert.throws(() => parseRates({ ...ok, max_km: -1 }), /max_km/)
  assert.throws(() => parseRates({ city: "X", areas: { A: 1 }, base_amount: 1, included_km: 0, per_km: 1, max_km: 5 }), /max_km/)
  assert.throws(() => parseRates({ ...ok, bulk_units: 1 }), /bulk_units/)
  assert.throws(() => parseRates({ ...ok, bulk_units: 2.5 }), /bulk_units/)
  // Medusa merges data on update: null drops the old table.
  const moved = parseRates({ ...ok, areas: null, zones: null })
  assert.equal(moved.areas, undefined)
  assert.equal(quote(moved, { items: [boots], shipping_address: { city: "X", metadata: north(2) } }).amount, 3)
})
