// The local delivery rate: pure, so it is unit-tested without Medusa. The
// rates are the shipping option's data, set by the store (see
// `gosite docs medusa-local-delivery`).

// A surcharge for the order's weight. Tiers go up by up_to_grams; the last one
// has none and takes every heavier order.
export type WeightTier = { up_to_grams?: number; surcharge: number }

// A place on the map, in degrees.
export type Point = { lat: number; lng: number }

// A named part of the area delivered to: one or more rings of [lng, lat]
// corners, as in GeoJSON. A point inside any of the rings is in the zone.
// city, when the zone is in another municipality than the rates' city: the
// address's city must then be the zone's.
export type Zone = { name: string; rings: Array<Array<[number, number]>>; city?: string }

// The rates price the distance one of two ways: by area, from a table of km
// per neighbourhood the buyer picks (areas), or by the straight line from
// the store to the point the buyer marks on a map (origin).
export type DeliveryRates = {
  // The city delivered to, compared without case or accents; with origin,
  // zones may add others (Zone.city).
  city: string
  // Area (neighbourhood) name -> km by road from the starting point.
  areas?: Record<string, number>
  // Where deliveries leave from.
  origin?: Point
  // With origin: the parts of the city delivered to. A point outside every
  // zone is not delivered to; without zones any point within max_km is.
  zones?: Zone[]
  // With origin: the farthest delivery, in km in a straight line.
  max_km?: number
  base_amount: number
  // Km the base amount covers; every further km or part of one adds per_km.
  included_km: number
  per_km: number
  // The amount is rounded up to a multiple of this.
  round_to?: number
  // Orders whose items add up to this or more are delivered free.
  free_from?: number
  // Weight of an item whose variant and product have none.
  default_weight_grams?: number
  weight_tiers?: WeightTier[]
  // An order with this many units of one product is not delivered at this
  // rate: the store arranges it with the buyer.
  bulk_units?: number
}

// What Medusa passes about the cart, reduced to what the rate needs.
export type DeliveryCart = {
  items?: Array<{
    product_id?: string | null
    variant_id?: string | null
    unit_price?: unknown
    quantity?: unknown
    variant?: { weight?: unknown } | null
    product?: { weight?: unknown } | null
  }>
  shipping_address?: {
    city?: string | null
    metadata?: Record<string, unknown> | null
  } | null
}

export type DeliveryQuote = {
  amount: number
  // The area picked, or the zone the point falls in ("" without zones).
  area: string
  km: number
  weight_grams: number
  free: boolean
}

// The shipping address's metadata keys: the buyer's area, or the point they
// marked on the map.
export const AREA_KEY = "area"
export const LAT_KEY = "lat"
export const LNG_KEY = "lng"

// city: another city. area: an area outside the table. location: no point on
// the map. zone: a point outside the zones or past max_km. bulk: an order the
// store arranges itself (bulk_units).
export type DeliveryErrorCode = "city" | "area" | "location" | "zone" | "bulk"

export class DeliveryError extends Error {
  readonly code: DeliveryErrorCode

  constructor(code: DeliveryErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

export function normalizeName(name: string): string {
  return name
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim()
}

// Medusa hands amounts as numbers, strings or BigNumber objects.
export function toNumber(value: unknown): number {
  if (value === null || value === undefined || value === "") {
    return NaN
  }
  if (typeof value === "object") {
    const v = value as { numeric?: unknown; value?: unknown }
    if (typeof v.numeric === "number") {
      return v.numeric
    }
    if (v.value !== undefined) {
      return Number(v.value)
    }
  }
  return Number(value)
}

function isAmount(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
}

function isLatLng(lat: unknown, lng: unknown): boolean {
  return (
    typeof lat === "number" && typeof lng === "number" &&
    Math.abs(lat) <= 90 && Math.abs(lng) <= 180
  )
}

function isPoint(value: unknown): value is Point {
  const p = value as Point | undefined
  return !!p && typeof p === "object" && isLatLng(p.lat, p.lng)
}

function isRing(ring: unknown): boolean {
  return (
    Array.isArray(ring) && ring.length >= 3 &&
    ring.every((c) => Array.isArray(c) && c.length === 2 && isLatLng(c[1], c[0]))
  )
}

// parseRates checks a shipping option's data and returns it typed; it throws
// naming the first field that is wrong.
//
// A field set to null counts as unset: Medusa merges an option's data on
// update, so null is how an update drops a field (areas, when moving to
// origin).
export function parseRates(data: unknown): DeliveryRates {
  const d = Object.fromEntries(
    Object.entries((data ?? {}) as Record<string, unknown>).filter(([, v]) => v !== null),
  )
  const fail = (field: string, why: string): never => {
    throw new Error(`local delivery: ${field} ${why}`)
  }
  if (typeof d.city !== "string" || !d.city.trim()) {
    fail("city", "must name the city delivered to")
  }
  if ((d.areas === undefined) === (d.origin === undefined)) {
    fail("areas", "or origin must be set, and not both")
  }
  if (d.areas !== undefined) {
    const areas = d.areas as Record<string, unknown>
    if (!areas || typeof areas !== "object" || Array.isArray(areas) || !Object.keys(areas).length) {
      fail("areas", "must map each area to its km")
    }
    for (const [name, km] of Object.entries(areas)) {
      if (!isAmount(km)) {
        fail(`areas["${name}"]`, "must be a distance in km")
      }
    }
  } else {
    if (!isPoint(d.origin)) {
      fail("origin", "must be a point: { lat, lng }")
    }
    if (d.zones !== undefined) {
      const zones = d.zones as Zone[]
      if (!Array.isArray(zones) || !zones.length) {
        fail("zones", "must be a list of zones")
      }
      zones.forEach((zone, i) => {
        if (typeof zone?.name !== "string" || !zone.name.trim()) {
          fail(`zones[${i}].name`, "must name the zone")
        }
        if (!Array.isArray(zone.rings) || !zone.rings.length || !zone.rings.every(isRing)) {
          fail(`zones[${i}].rings`, "must be rings of 3 or more [lng, lat] corners")
        }
        if (zone.city != null && (typeof zone.city !== "string" || !zone.city.trim())) {
          fail(`zones[${i}].city`, "must name the zone's municipality")
        }
      })
    }
  }
  if (d.max_km !== undefined && (!isAmount(d.max_km) || d.areas !== undefined)) {
    fail("max_km", "must be a distance in km, and goes with origin")
  }
  if (d.bulk_units !== undefined && !(Number.isInteger(d.bulk_units) && (d.bulk_units as number) >= 2)) {
    fail("bulk_units", "must be a whole number of units, 2 or more")
  }
  for (const field of ["base_amount", "included_km", "per_km"]) {
    if (!isAmount(d[field])) {
      fail(field, "must be a number, 0 or more")
    }
  }
  for (const field of ["round_to", "free_from", "default_weight_grams"]) {
    if (d[field] !== undefined && !isAmount(d[field])) {
      fail(field, "must be a number, 0 or more")
    }
  }
  if (d.weight_tiers !== undefined) {
    const tiers = d.weight_tiers as WeightTier[]
    if (!Array.isArray(tiers) || !tiers.length) {
      fail("weight_tiers", "must be a list of tiers")
    }
    let previous = -1
    tiers.forEach((tier, i) => {
      if (!isAmount(tier?.surcharge)) {
        fail(`weight_tiers[${i}].surcharge`, "must be a number, 0 or more")
      }
      const last = i === tiers.length - 1
      if (last && tier.up_to_grams !== undefined) {
        fail(`weight_tiers[${i}]`, "is the last tier and must not have up_to_grams")
      }
      if (!last) {
        if (!isAmount(tier.up_to_grams) || tier.up_to_grams <= previous) {
          fail(`weight_tiers[${i}].up_to_grams`, "must be a weight above the previous tier's")
        }
        previous = tier.up_to_grams!
      }
    })
  }
  return d as unknown as DeliveryRates
}

// findArea returns the table's spelling of the buyer's area and its km.
export function findArea(rates: DeliveryRates, name: unknown): [string, number] | undefined {
  if (typeof name !== "string" || !name.trim()) {
    return undefined
  }
  const wanted = normalizeName(name)
  for (const [area, km] of Object.entries(rates.areas ?? {})) {
    if (normalizeName(area) === wanted) {
      return [area, km]
    }
  }
  return undefined
}

// addressPoint reads the point the buyer marked from the address's
// metadata; numbers may arrive as strings.
export function addressPoint(metadata: Record<string, unknown> | null | undefined): Point | undefined {
  const lat = toNumber(metadata?.[LAT_KEY])
  const lng = toNumber(metadata?.[LNG_KEY])
  return isLatLng(lat, lng) ? { lat, lng } : undefined
}

const EARTH_RADIUS_KM = 6371

// distanceKm is the straight line between two points over the earth's
// surface (haversine), to a tenth of a km.
export function distanceKm(a: Point, b: Point): number {
  const rad = Math.PI / 180
  const dLat = (b.lat - a.lat) * rad
  const dLng = (b.lng - a.lng) * rad
  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2
  return Math.round(2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(h)) * 10) / 10
}

// inRing tells whether a point is inside a ring of [lng, lat] corners (ray
// casting: a ray from the point crosses the edge an odd number of times).
export function inRing(p: Point, ring: Array<[number, number]>): boolean {
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i]
    const [xj, yj] = ring[j]
    if (yi > p.lat !== yj > p.lat && p.lng < ((xj - xi) * (p.lat - yi)) / (yj - yi) + xi) {
      inside = !inside
    }
  }
  return inside
}

// findZone returns the zone a point falls in.
export function findZone(rates: DeliveryRates, p: Point): Zone | undefined {
  return rates.zones?.find((z) => z.rings.some((ring) => inRing(p, ring)))
}

// mostUnits is the largest number of units of one product in the cart.
export function mostUnits(cart: DeliveryCart): number {
  const units = new Map<string, number>()
  let most = 0
  ;(cart.items ?? []).forEach((item, i) => {
    const quantity = toNumber(item.quantity)
    if (!Number.isFinite(quantity)) {
      return
    }
    const key = item.product_id || item.variant_id || `item-${i}`
    const n = (units.get(key) ?? 0) + quantity
    units.set(key, n)
    most = Math.max(most, n)
  })
  return most
}

export function itemsTotal(cart: DeliveryCart): number {
  let total = 0
  for (const item of cart.items ?? []) {
    const price = toNumber(item.unit_price)
    const quantity = toNumber(item.quantity)
    if (Number.isFinite(price) && Number.isFinite(quantity)) {
      total += price * quantity
    }
  }
  return total
}

export function itemsWeight(cart: DeliveryCart, defaultGrams = 0): number {
  let total = 0
  for (const item of cart.items ?? []) {
    const quantity = toNumber(item.quantity)
    if (!Number.isFinite(quantity)) {
      continue
    }
    let grams = toNumber(item.variant?.weight)
    if (!Number.isFinite(grams)) {
      grams = toNumber(item.product?.weight)
    }
    if (!Number.isFinite(grams)) {
      grams = defaultGrams
    }
    total += grams * quantity
  }
  return total
}

export function weightSurcharge(rates: DeliveryRates, grams: number): number {
  for (const tier of rates.weight_tiers ?? []) {
    if (tier.up_to_grams === undefined || grams <= tier.up_to_grams) {
      return tier.surcharge
    }
  }
  return 0
}

function sameCity(city: string | null | undefined, wanted: string): boolean {
  return !!city && normalizeName(city) === normalizeName(wanted)
}

// place answers where the address is and how far: the area picked from the
// table, or the zone and straight-line km of the point on the map, and the
// city the address must be in.
function place(rates: DeliveryRates, metadata: Record<string, unknown> | null | undefined): [string, number, string] {
  if (!rates.origin) {
    const found = findArea(rates, metadata?.[AREA_KEY])
    if (!found) {
      throw new DeliveryError("area", `The address's ${AREA_KEY} is not one delivered to`)
    }
    return [...found, rates.city]
  }
  const point = addressPoint(metadata)
  if (!point) {
    throw new DeliveryError("location", `The address has no ${LAT_KEY} and ${LNG_KEY}`)
  }
  const km = distanceKm(rates.origin, point)
  const zone = rates.zones ? findZone(rates, point) : { name: "" }
  if (zone === undefined || (rates.max_km !== undefined && km > rates.max_km)) {
    throw new DeliveryError("zone", "The address is outside the area delivered to")
  }
  return [zone.name, km, (zone as Zone).city ?? rates.city]
}

// quote prices delivering the cart to its shipping address. It throws a
// DeliveryError when the address is outside the city or the area delivered
// to, or the order is one the store arranges itself (bulk_units).
export function quote(rates: DeliveryRates, cart: DeliveryCart): DeliveryQuote {
  const address = cart.shipping_address
  if (!address?.city) {
    throw new DeliveryError("city", `Delivery is only to ${rates.city}`)
  }
  if (rates.bulk_units !== undefined && mostUnits(cart) >= rates.bulk_units) {
    throw new DeliveryError("bulk", `Orders of ${rates.bulk_units} or more units of one product are arranged with the store`)
  }
  const [area, km, city] = place(rates, address.metadata)
  if (!sameCity(address.city, city)) {
    throw new DeliveryError("city", `This address is in ${city}`)
  }
  const weight = itemsWeight(cart, rates.default_weight_grams ?? 0)
  const result = { area, km, weight_grams: weight }

  if (rates.free_from !== undefined && rates.free_from > 0 && itemsTotal(cart) >= rates.free_from) {
    return { ...result, amount: 0, free: true }
  }

  // Tenths of a km, so 4.0 km is one km past 3 and not two from float noise.
  const extraKm = Math.max(0, Math.ceil(Math.round((km - rates.included_km) * 10) / 10))
  let amount = rates.base_amount + extraKm * rates.per_km + weightSurcharge(rates, weight)
  if (rates.round_to) {
    amount = Math.ceil(amount / rates.round_to) * rates.round_to
  }
  return { ...result, amount, free: false }
}
