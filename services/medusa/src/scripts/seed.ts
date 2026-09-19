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
  updateStoresWorkflow,
} from "@medusajs/medusa/core-flows"

import { resolveRegion, type RegionDef } from "../lib/regions"
import { pickSeeded, usableKeys } from "../lib/seeded"

// What the seed created is recorded by id in the store's gosite_seed_state
// (design D5). On every start a recorded record is found by that id, so an owner
// who renames the region or the sales channel does not get a second one. The
// names below only adopt records from a deployment that predates the ids. The
// seed never updates what exists, and a deleted demo product stays deleted.
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
  ids?: Record<string, string>
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
  const state: SeedState = { ...((store.metadata?.gosite_seed_state as SeedState) ?? {}) }
  state.ids = { ...(state.ids ?? {}) }
  const ids = state.ids

  const salesChannel = await ensureSalesChannel(container, ids, logger)
  await ensureRegion(container, region, ids, logger)
  const stockLocation = await ensureStockLocation(container, ids, logger)

  await linkSalesChannelsToStockLocationWorkflow(container).run({
    input: { id: stockLocation.id, add: [salesChannel.id] },
  })

  const shippingProfile = await ensureShippingProfile(container, logger)
  const serviceZone = await ensureServiceZone(container, stockLocation.id, region, logger)
  await ensureShippingOption(
    container,
    ids,
    shippingProfile.id,
    serviceZone.id,
    stockLocation.id,
    region,
    logger
  )

  const { token } = await ensurePublishableKey(container, salesChannel.id, ids, logger)
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

async function ensureSalesChannel(
  container: MedusaContainer,
  ids: Record<string, string>,
  logger: Logger
) {
  const service: any = container.resolve(Modules.SALES_CHANNEL)
  const existing = await findSeeded(ids, "sales_channel", (filter) =>
    service.listSalesChannels(filter ?? { name: SALES_CHANNEL_NAME })
  )
  if (existing) {
    return existing
  }
  const { result } = await createSalesChannelsWorkflow(container).run({
    input: { salesChannelsData: [{ name: SALES_CHANNEL_NAME }] },
  })
  logger.info(`commerce seed: created sales channel ${SALES_CHANNEL_NAME}`)
  ids.sales_channel = result[0].id
  return result[0]
}

async function ensureRegion(
  container: MedusaContainer,
  region: RegionDef,
  ids: Record<string, string>,
  logger: Logger
) {
  const service: any = container.resolve(Modules.REGION)
  const existing = await findSeeded(ids, "region", (filter) =>
    service.listRegions(filter ?? { name: region.name })
  )
  if (existing) {
    // Never touched once it exists: an owner who removed the manual provider
    // (to take only card payments) must not see it come back on a restart,
    // or buyers could place orders without paying.
    return existing
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
  ids.region = result[0].id
  return result[0]
}

async function ensureStockLocation(
  container: MedusaContainer,
  ids: Record<string, string>,
  logger: Logger
) {
  const service: any = container.resolve(Modules.STOCK_LOCATION)
  const existing = await findSeeded(ids, "stock_location", (filter) =>
    service.listStockLocations(filter ?? { name: STOCK_LOCATION_NAME })
  )
  if (existing) {
    return existing
  }
  const { result } = await createStockLocationsWorkflow(container).run({
    input: { locations: [{ name: STOCK_LOCATION_NAME }] },
  })
  logger.info(`commerce seed: created stock location ${STOCK_LOCATION_NAME}`)
  ids.stock_location = result[0].id
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
  ids: Record<string, string>,
  shippingProfileId: string,
  serviceZoneId: string,
  stockLocationId: string,
  region: RegionDef,
  logger: Logger
) {
  const service: any = container.resolve(Modules.FULFILLMENT)
  const existing = await findSeeded(ids, "shipping_option", (filter) =>
    service.listShippingOptions(filter ?? { name: SHIPPING_OPTION_NAME })
  )
  if (existing) {
    return existing
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
  ids.shipping_option = result[0].id
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
  ids: Record<string, string>,
  logger: Logger
) {
  const service: any = container.resolve(Modules.API_KEY)
  // A revoked key is never reused: writing it out would leave the site unable
  // to call the Store API. Revoking it in the Admin is how an owner rotates it.
  let key = await findSeeded(ids, "publishable_key", async (filter) =>
    usableKeys(await service.listApiKeys(filter ?? { title: PUBLISHABLE_KEY_TITLE, type: "publishable" }))
  )
  if (!key) {
    const { result } = await createApiKeysWorkflow(container).run({
      input: {
        api_keys: [
          { title: PUBLISHABLE_KEY_TITLE, type: "publishable", created_by: "gosite-seed" },
        ],
      },
    })
    key = result[0]
    ids.publishable_key = key.id
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

  const given = process.env.COMMERCE_ADMIN_PASSWORD
  const password = given || randomBytes(12).toString("base64url")
  const user = await userModuleService.createUsers({ email })

  const { success, authIdentity, error } = await authModuleService.register("emailpass", {
    body: { email, password },
  })
  if (!success || !authIdentity) {
    // Without this the next start would find the user, skip it, and leave an
    // admin nobody can log in as.
    await userModuleService.deleteUsers([user.id])
    throw new Error(`commerce seed: could not create the admin login: ${JSON.stringify(error)}`)
  }
  await authModuleService.updateAuthIdentities({
    id: authIdentity.id,
    app_metadata: { user_id: user.id },
  })

  if (given) {
    logger.info(`commerce seed: admin ${email} created with the password from COMMERCE_ADMIN_PASSWORD`)
    return
  }
  // Printed once, on creation, and only when the seed generated it.
  logger.info(
    `commerce seed: admin ${email} created; password: ${password} (change it after the first login)`
  )
}

// findSeeded returns the record the seed created earlier, by its recorded id,
// or adopts one found by the default lookup (list called with no filter) and
// records its id. undefined means "create it".
async function findSeeded(
  ids: Record<string, string>,
  kind: string,
  list: (filter?: Record<string, unknown>) => Promise<any[]>
): Promise<any | undefined> {
  const recorded = ids[kind]
  const record = await pickSeeded(recorded, recorded ? await list({ id: recorded }) : [], () => list())
  if (record) {
    ids[kind] = record.id
  }
  return record
}
