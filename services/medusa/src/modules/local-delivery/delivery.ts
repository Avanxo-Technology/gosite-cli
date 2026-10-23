// The local delivery rate: pure, so it is unit-tested without Medusa. The
// rates are the shipping option's data, set by the store (see
// `gosite docs medusa-local-delivery`).

// A surcharge for the order's weight. Tiers go up by up_to_grams; the last one
// has none and takes every heavier order.
export type WeightTier = { up_to_grams?: number; surcharge: number }

export type DeliveryRates = {
  // The one city delivered to, compared without case or accents.
  city: string
  // Area (neighbourhood) name -> km by road from the starting point.
  areas: Record<string, number>
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
}

// What Medusa passes about the cart, reduced to what the rate needs.
export type DeliveryCart = {
  items?: Array<{
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
  area: string
  km: number
  weight_grams: number
  free: boolean
}

// The shipping address's metadata key that names the buyer's area.
export const AREA_KEY = "area"

export class DeliveryError extends Error {
  readonly code: "city" | "area"

  constructor(code: "city" | "area", message: string) {
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

// parseRates checks a shipping option's data and returns it typed; it throws
// naming the first field that is wrong.
export function parseRates(data: unknown): DeliveryRates {
  const d = (data ?? {}) as Record<string, unknown>
  const fail = (field: string, why: string): never => {
    throw new Error(`local delivery: ${field} ${why}`)
  }
  if (typeof d.city !== "string" || !d.city.trim()) {
    fail("city", "must name the city delivered to")
  }
  const areas = d.areas as Record<string, unknown> | undefined
  if (!areas || typeof areas !== "object" || Array.isArray(areas) || !Object.keys(areas).length) {
    fail("areas", "must map each area to its km")
  }
  for (const [name, km] of Object.entries(areas!)) {
    if (!isAmount(km)) {
      fail(`areas["${name}"]`, "must be a distance in km")
    }
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
  for (const [area, km] of Object.entries(rates.areas)) {
    if (normalizeName(area) === wanted) {
      return [area, km]
    }
  }
  return undefined
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

// quote prices delivering the cart to its shipping address. It throws a
// DeliveryError when the address is outside the city or its area is not in
// the table.
export function quote(rates: DeliveryRates, cart: DeliveryCart): DeliveryQuote {
  const address = cart.shipping_address
  if (!address?.city || normalizeName(address.city) !== normalizeName(rates.city)) {
    throw new DeliveryError("city", `Delivery is only to ${rates.city}`)
  }
  const found = findArea(rates, address.metadata?.[AREA_KEY])
  if (!found) {
    throw new DeliveryError("area", `The address's ${AREA_KEY} is not one delivered to`)
  }
  const [area, km] = found
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
