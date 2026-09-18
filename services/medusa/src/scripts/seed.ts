import { randomBytes } from "node:crypto"
import { mkdir, writeFile } from "node:fs/promises"

import type { ExecArgs, MedusaContainer } from "@medusajs/framework/types"
import {
  ContainerRegistrationKeys,
  Modules,
  ProductStatus,
} from "@medusajs/framework/utils"
import {
  batchLinksWorkflow,
  createApiKeysWorkflow,
  createInventoryItemsWorkflow,
  createInventoryLevelsWorkflow,
  createLocationFulfillmentSetWorkflow,
  createProductsWorkflow,
  createRegionsWorkflow,
  createSalesChannelsWorkflow,
  createShippingOptionsWorkflow,
  createShippingProfilesWorkflow,
  createStockLocationsWorkflow,
  linkSalesChannelsToApiKeyWorkflow,
  linkSalesChannelsToStockLocationWorkflow,
  updateRegionsWorkflow,
  updateStoresWorkflow,
} from "@medusajs/medusa/core-flows"

import { resolveRegion, type RegionDef } from "../lib/regions"

// Stable names the seed looks up on every start (design D5): each created
// record is findable by one of these, so the seed never duplicates and never
// updates what the store owner changed. A deleted demo product stays deleted,
// tracked in the store's gosite_seed_state instead of by re-checking.
const SALES_CHANNEL_NAME = "gosite"
const STOCK_LOCATION_NAME = "gosite"
const FULFILLMENT_SET_NAME = "gosite"
const SHIPPING_OPTION_NAME = "gosite-standard"
const DEFAULT_SHIPPING_PROFILE_NAME = "Default Shipping Profile"
const PUBLISHABLE_KEY_TITLE = "gosite"
const DEMO_PRODUCT_HANDLE = "gosite-demo"
const DEMO_SKU = "gosite-demo-default"
const DEMO_STOCK = 1000
const DEFAULT_KEY_DIR = "/run/gosite-commerce"

type SeedState = {
  demo_product_created?: boolean
}

type Logger = { info: (m: string) => void; warn: (m: string) => void }

export default async function seed({ container }: ExecArgs) {
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER) as Logger
  const storeModuleService = container.resolve(Modules.STORE)

  // Fail fast before touching the database: an unsupported region names the
  // bad value and the supported codes.
  const region = resolveRegion(process.env.COMMERCE_REGION)

  const [store] = await storeModuleService.listStores()
  if (!store) {
    throw new Error("commerce seed: no store exists; run the migrations first")
  }
  const state: SeedState = (store.metadata?.gosite_seed_state as SeedState) ?? {}

  const salesChannel = await ensureSalesChannel(container, logger)
  await ensureRegion(container, region, logger)
  const stockLocation = await ensureStockLocation(container, logger)

  await linkSalesChannelsToStockLocationWorkflow(container).run({
    input: { id: stockLocation.id, add: [salesChannel.id] },
  })

  const shippingProfile = await ensureShippingProfile(container, logger)
  const serviceZone = await ensureServiceZone(container, stockLocation.id, region, logger)
  await ensureShippingOption(
    container,
    shippingProfile.id,
    serviceZone.id,
    stockLocation.id,
    region,
    logger
  )

  const { token } = await ensurePublishableKey(container, salesChannel.id, logger)
  await writePublishableKey(token, logger)

  await ensureDemoProduct(
    container,
    salesChannel.id,
    stockLocation.id,
    shippingProfile.id,
    region,
    state,
    logger
  )

  await ensureAdminUser(container, logger)

  await updateStoresWorkflow(container).run({
    input: {
      selector: { id: store.id },
      update: { metadata: { ...(store.metadata ?? {}), gosite_seed_state: state } },
    },
  })

  logger.info(
    `commerce seed: ready (region ${region.code}, currency ${region.currency.toUpperCase()})`
  )
}

async function ensureSalesChannel(container: MedusaContainer, logger: Logger) {
  const service: any = container.resolve(Modules.SALES_CHANNEL)
  const existing = await service.listSalesChannels({ name: SALES_CHANNEL_NAME })
  if (existing.length) {
    return existing[0]
  }
  const { result } = await createSalesChannelsWorkflow(container).run({
    input: { salesChannelsData: [{ name: SALES_CHANNEL_NAME }] },
  })
  logger.info(`commerce seed: created sales channel ${SALES_CHANNEL_NAME}`)
  return result[0]
}

async function ensureRegion(container: MedusaContainer, region: RegionDef, logger: Logger) {
  const service: any = container.resolve(Modules.REGION)
  const existing = await service.listRegions({ name: region.name })
  if (existing.length) {
    // Keep the manual provider enabled without dropping any the owner added.
    const current = (existing[0].payment_providers ?? []).map((p: any) => p.id)
    const providers = Array.from(new Set([...current, "pp_system_default"]))
    await updateRegionsWorkflow(container).run({
      input: { selector: { id: existing[0].id }, update: { payment_providers: providers } },
    })
    return existing[0]
  }
  const { result } = await createRegionsWorkflow(container).run({
    input: {
      regions: [
        {
          name: region.name,
          currency_code: region.currency,
          countries: [region.country],
          payment_providers: ["pp_system_default"],
        },
      ],
    },
  })
  logger.info(`commerce seed: created region ${region.name} (${region.currency})`)
  return result[0]
}

async function ensureStockLocation(container: MedusaContainer, logger: Logger) {
  const service: any = container.resolve(Modules.STOCK_LOCATION)
  const existing = await service.listStockLocations({ name: STOCK_LOCATION_NAME })
  if (existing.length) {
    return existing[0]
  }
  const { result } = await createStockLocationsWorkflow(container).run({
    input: { locations: [{ name: STOCK_LOCATION_NAME }] },
  })
  logger.info(`commerce seed: created stock location ${STOCK_LOCATION_NAME}`)
  return result[0]
}

async function ensureShippingProfile(container: MedusaContainer, logger: Logger) {
  const service: any = container.resolve(Modules.FULFILLMENT)
  // Reuse Medusa's built-in default profile: createProductsWorkflow assigns it
  // to the demo product, and a shipping option must use the same profile or the
  // cart cannot be completed ("items require shipping profiles not satisfied by
  // the current shipping methods").
  const existing = await service.listShippingProfiles({ type: "default" })
  if (existing.length) {
    return existing[0]
  }
  const { result } = await createShippingProfilesWorkflow(container).run({
    input: { data: [{ name: DEFAULT_SHIPPING_PROFILE_NAME, type: "default" }] },
  })
  logger.info("commerce seed: created the default shipping profile")
  return result[0]
}

async function ensureServiceZone(
  container: MedusaContainer,
  locationId: string,
  region: RegionDef,
  logger: Logger
) {
  const service: any = container.resolve(Modules.FULFILLMENT)
  let [set] = await service.listFulfillmentSets({ name: FULFILLMENT_SET_NAME })
  if (!set) {
    await createLocationFulfillmentSetWorkflow(container).run({
      input: {
        location_id: locationId,
        fulfillment_set_data: { name: FULFILLMENT_SET_NAME, type: "shipping" },
      },
    })
    ;[set] = await service.listFulfillmentSets({ name: FULFILLMENT_SET_NAME })
  }
  if (!set) {
    throw new Error("commerce seed: fulfillment set was not created")
  }
  const zones = await service.listServiceZones({ fulfillment_set_id: set.id })
  if (zones.length) {
    return zones[0]
  }
  const zone = await service.createServiceZones({
    name: region.name,
    fulfillment_set_id: set.id,
    geo_zones: [{ country_code: region.country, type: "country" }],
  })
  logger.info(`commerce seed: created service zone ${region.name}`)
  return zone
}

async function ensureShippingOption(
  container: MedusaContainer,
  shippingProfileId: string,
  serviceZoneId: string,
  stockLocationId: string,
  region: RegionDef,
  logger: Logger
) {
  const service: any = container.resolve(Modules.FULFILLMENT)
  const existing = await service.listShippingOptions({ name: SHIPPING_OPTION_NAME })
  if (existing.length) {
    return existing[0]
  }
  const providers = await service.listFulfillmentProviders({})
  const manual = providers.find((p: any) => /manual/i.test(p.id)) ?? providers[0]
  if (!manual) {
    throw new Error("commerce seed: no fulfillment provider is available")
  }
  // A shipping option's provider must be enabled for the stock location, or the
  // create workflow rejects it. The Admin does this with a link; the seed does
  // the same, and only when the link is missing.
  await ensureFulfillmentProvider(container, stockLocationId, manual.id)

  const { result } = await createShippingOptionsWorkflow(container).run({
    input: [
      {
        name: SHIPPING_OPTION_NAME,
        service_zone_id: serviceZoneId,
        shipping_profile_id: shippingProfileId,
        provider_id: manual.id,
        price_type: "flat",
        type: { label: "Standard", description: "Standard shipping", code: "standard" },
        prices: [{ amount: region.shippingPrice, currency_code: region.currency }],
      },
    ],
  })
  logger.info(`commerce seed: created shipping option ${SHIPPING_OPTION_NAME}`)
  return result[0]
}

async function ensureFulfillmentProvider(
  container: MedusaContainer,
  stockLocationId: string,
  providerId: string
) {
  const query: any = container.resolve(ContainerRegistrationKeys.QUERY)
  const { data } = await query.graph({
    entity: "stock_location",
    fields: ["id", "fulfillment_providers.id"],
    filters: { id: stockLocationId },
  })
  const current = (data?.[0]?.fulfillment_providers ?? []).map((p: any) => p.id)
  if (current.includes(providerId)) {
    return
  }
  await batchLinksWorkflow(container).run({
    input: {
      create: [
        {
          [Modules.STOCK_LOCATION]: { stock_location_id: stockLocationId },
          [Modules.FULFILLMENT]: { fulfillment_provider_id: providerId },
        },
      ],
    },
  })
}

async function ensurePublishableKey(
  container: MedusaContainer,
  salesChannelId: string,
  logger: Logger
) {
  const service: any = container.resolve(Modules.API_KEY)
  const existing = await service.listApiKeys({
    title: PUBLISHABLE_KEY_TITLE,
    type: "publishable",
  })
  let key = existing[0]
  if (!key) {
    const { result } = await createApiKeysWorkflow(container).run({
      input: {
        api_keys: [
          { title: PUBLISHABLE_KEY_TITLE, type: "publishable", created_by: "gosite-seed" },
        ],
      },
    })
    key = result[0]
    logger.info("commerce seed: created publishable API key")
  }
  await linkSalesChannelsToApiKeyWorkflow(container).run({
    input: { id: key.id, add: [salesChannelId] },
  })
  return key
}

async function writePublishableKey(token: string, logger: Logger) {
  if (!token) {
    throw new Error("commerce seed: the publishable key has no token")
  }
  const dir = process.env.COMMERCE_KEY_DIR || DEFAULT_KEY_DIR
  await mkdir(dir, { recursive: true })
  await writeFile(`${dir}/publishable_key`, token, { mode: 0o644 })
  logger.info(`commerce seed: publishable key written to ${dir}/publishable_key`)
}

async function ensureDemoProduct(
  container: MedusaContainer,
  salesChannelId: string,
  stockLocationId: string,
  shippingProfileId: string,
  region: RegionDef,
  state: SeedState,
  logger: Logger
) {
  if (state.demo_product_created) {
    return
  }
  const productService: any = container.resolve(Modules.PRODUCT)
  // Even before the flag is set, adopt an existing product with the handle so a
  // deployment that predates the flag does not duplicate it.
  const existing = await productService.listProducts({ handle: DEMO_PRODUCT_HANDLE })
  if (existing.length) {
    state.demo_product_created = true
    return
  }

  const { result } = await createProductsWorkflow(container).run({
    input: {
      products: [
        {
          title: "Demo product",
          handle: DEMO_PRODUCT_HANDLE,
          description: "A demo product created by gosite so the store works with no setup.",
          status: ProductStatus.PUBLISHED,
          shipping_profile_id: shippingProfileId,
          options: [{ title: "Default", values: ["Default"] }],
          variants: [
            {
              title: "Default",
              sku: DEMO_SKU,
              options: { Default: "Default" },
              prices: [{ amount: region.demoPrice, currency_code: region.currency }],
            },
          ],
          sales_channels: [{ id: salesChannelId }],
        },
      ],
    },
  })
  const product: any = result[0]

  // The product workflow creates the variant's inventory item; give it stock at
  // the location so the demo product can actually be added to a cart.
  const inventoryService: any = container.resolve(Modules.INVENTORY)
  let items = await inventoryService.listInventoryItems({ sku: DEMO_SKU })
  if (!items.length) {
    const created = await createInventoryItemsWorkflow(container).run({
      input: {
        items: [
          {
            sku: DEMO_SKU,
            location_levels: [
              { location_id: stockLocationId, stocked_quantity: DEMO_STOCK },
            ],
          },
        ],
      },
    })
    items = created.result
  } else {
    await createInventoryLevelsWorkflow(container).run({
      input: {
        inventory_levels: [
          {
            inventory_item_id: items[0].id,
            location_id: stockLocationId,
            stocked_quantity: DEMO_STOCK,
          },
        ],
      },
    })
  }

  state.demo_product_created = true
  logger.info(`commerce seed: created demo product ${product.handle ?? DEMO_PRODUCT_HANDLE}`)
}

async function ensureAdminUser(container: MedusaContainer, logger: Logger) {
  const email = (process.env.COMMERCE_ADMIN_EMAIL || "admin@gosite.local").toLowerCase()
  const userModuleService: any = container.resolve(Modules.USER)
  const authModuleService: any = container.resolve(Modules.AUTH)

  const existing = await userModuleService.listUsers({ email })
  if (existing.length) {
    logger.info(`commerce seed: admin ${email} already exists`)
    return
  }

  const password = process.env.COMMERCE_ADMIN_PASSWORD || randomBytes(12).toString("base64url")
  const user = await userModuleService.createUsers({ email })

  const { success, authIdentity, error } = await authModuleService.register("emailpass", {
    body: { email, password },
  })
  if (!success || !authIdentity) {
    throw new Error(`commerce seed: could not create the admin login: ${JSON.stringify(error)}`)
  }
  await authModuleService.updateAuthIdentities({
    id: authIdentity.id,
    app_metadata: { user_id: user.id },
  })

  // Printed once, on creation only. The README tells owners to rotate it.
  logger.info(
    `commerce seed: admin ${email} created; password: ${password} (change it after the first login)`
  )
}
