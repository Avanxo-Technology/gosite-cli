import { ModuleProvider, Modules } from "@medusajs/framework/utils"

import LocalDeliveryProviderService from "./service"

// Registers local delivery as a fulfillment provider. It prices nothing until
// a store creates a shipping option with it and its rates as the option's data.
export default ModuleProvider(Modules.FULFILLMENT, {
  services: [LocalDeliveryProviderService],
})
