import type { SubscriberArgs, SubscriberConfig } from "@medusajs/framework"
import { ContainerRegistrationKeys } from "@medusajs/framework/utils"

import { createDebouncer } from "../lib/debounce"

// Catalogue changes that make the site's cached commerce pages stale. A price
// change reaches the site through these product/variant events.
export const PURGE_EVENTS = [
  "product.created",
  "product.updated",
  "product.deleted",
  "product-variant.created",
  "product-variant.updated",
  "product-variant.deleted",
  "product-category.created",
  "product-category.updated",
  "product-category.deleted",
  "product-collection.created",
  "product-collection.updated",
  "product-collection.deleted",
]

const DEBOUNCE_MS = 5000

// purgeSite calls the site's /cache/purge with the shared token. An unset URL
// disables purging (a store used without a Go site).
async function purgeSite(): Promise<void> {
  const url = process.env.GOSITE_PURGE_URL
  if (!url) {
    return
  }
  const token = process.env.GOSITE_PURGE_TOKEN
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(token ? { "X-Api-Key": token } : {}),
    },
    // Purge the whole page cache: over-purging costs a re-render, while
    // under-purging serves a price that no longer exists.
    body: JSON.stringify({ scope: "all" }),
  })
  if (!response.ok) {
    throw new Error(`site purge answered ${response.status}`)
  }
}

const schedulePurge = createDebouncer(DEBOUNCE_MS, purgeSite)

export default async function purgeSubscriber({ container }: SubscriberArgs) {
  const logger = container.resolve(ContainerRegistrationKeys.LOGGER)
  schedulePurge()
  logger.debug("commerce purge: scheduled after a catalogue change")
}

export const config: SubscriberConfig = {
  event: PURGE_EVENTS,
}
