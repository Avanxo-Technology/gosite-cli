import type { MedusaContainer } from "@medusajs/framework/types"
import { ContainerRegistrationKeys, Modules } from "@medusajs/framework/utils"

// Daily cleanup of abandoned carts (design D8). The storefront creates carts
// lazily, so this only ever removes carts a visitor never completed.
export const config = {
  name: "cleanup-abandoned-carts",
  schedule: "0 3 * * *",
}

export default async function cleanupAbandonedCarts(container: MedusaContainer) {
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)
  const cartModuleService = container.resolve(Modules.CART)

  const ttlDays = Number(process.env.COMMERCE_CART_TTL_DAYS || "30")
  if (!Number.isFinite(ttlDays) || ttlDays <= 0) {
    logger.warn(
      `cleanup-abandoned-carts: ignoring invalid COMMERCE_CART_TTL_DAYS=${process.env.COMMERCE_CART_TTL_DAYS}`
    )
    return
  }

  const cutoff = new Date(Date.now() - ttlDays * 24 * 60 * 60 * 1000)

  // completed_at stays null until the cart becomes an order: orders and
  // completed carts are never selected, so they are never deleted.
  const [carts, count] = await cartModuleService.listAndCountCarts(
    {
      completed_at: { $eq: null },
      updated_at: { $lt: cutoff },
    } as never,
    { select: ["id"] }
  )

  if (!count) {
    logger.info(
      `cleanup-abandoned-carts: no abandoned carts older than ${ttlDays}d`
    )
    return
  }

  await cartModuleService.deleteCarts(carts.map((cart) => cart.id))
  logger.info(
    `cleanup-abandoned-carts: deleted ${count} cart(s) older than ${ttlDays}d`
  )
}
