import { ModuleProvider, Modules } from "@medusajs/framework/utils"

import WompiProviderService from "./service"

// Registers Wompi as a payment provider. medusa-config.ts only lists it when the
// credentials are set, so a store without a Wompi account never sees it.
export default ModuleProvider(Modules.PAYMENT, {
  services: [WompiProviderService],
})
