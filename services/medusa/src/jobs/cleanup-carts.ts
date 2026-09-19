import type { MedusaContainer } from "@medusajs/framework/types"
import { ContainerRegistrationKeys, Modules } from "@medusajs/framework/utils"

import { deleteAbandonedCarts } from "../lib/cleanup"

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

  const deleted = await deleteAbandonedCarts(cartModuleService as never, cutoff)
  logger.info(
    deleted
      ? `cleanup-abandoned-carts: deleted ${deleted} cart(s) older than ${ttlDays}d`
      : `cleanup-abandoned-carts: no abandoned carts older than ${ttlDays}d`
  )
}
