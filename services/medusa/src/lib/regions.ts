// The supported commerce regions, one table for the whole service (design D4).
// Adding a region is adding a row here: the seed, the demo product and the
// storefront all read the region from this file.
//
// `code` is the value a site writes as `commerce_region` in gosite.yml and the
// service receives as COMMERCE_REGION.

export interface RegionDef {
  code: string
  name: string
  currency: string
  country: string
  locale: string
  // demoPrice is the seeded demo product's price in the currency's major unit
  // (Medusa stores amounts as decimals: 19.99 USD, 59900 COP).
  demoPrice: number
  // shippingPrice is the flat price of the seeded shipping option.
  shippingPrice: number
}

export const REGIONS: Record<string, RegionDef> = {
  co: {
    code: "co",
    name: "Colombia",
    currency: "cop",
    country: "co",
    locale: "es-CO",
    demoPrice: 59900,
    shippingPrice: 0,
  },
  us: {
    code: "us",
    name: "United States",
    currency: "usd",
    country: "us",
    locale: "en-US",
    demoPrice: 19.99,
    shippingPrice: 0,
  },
}

export const SUPPORTED_REGIONS = Object.keys(REGIONS).join(", ")

// resolveRegion returns the region for COMMERCE_REGION, or throws naming the
// bad value and the supported codes. The seed calls it before touching the
// database so an unsupported value fails the container at startup.
export function resolveRegion(raw: string | undefined): RegionDef {
  const code = (raw ?? "").trim().toLowerCase()
  const region = REGIONS[code]
  if (!region) {
    throw new Error(
      `COMMERCE_REGION "${raw ?? ""}" is not supported; supported codes: ${SUPPORTED_REGIONS}`
    )
  }
  return region
}
