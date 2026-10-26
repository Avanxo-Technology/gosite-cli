import { AbstractFulfillmentProviderService, MedusaError } from "@medusajs/framework/utils"
import type {
  CalculatedShippingOptionPrice,
  CalculateShippingOptionPriceDTO,
  CreateFulfillmentResult,
  FulfillmentOption,
  ValidateFulfillmentDataContext,
} from "@medusajs/framework/types"

import { DeliveryError, parseRates, quote, type DeliveryCart } from "./delivery"

// LocalDeliveryProviderService prices delivery inside one city by how far the
// buyer is from the store (their area's km, or the straight line to the point
// they marked) and the order's weight; the rate logic lives in ./delivery.
// Fulfilling is manual, as with Medusa's manual provider.
class LocalDeliveryProviderService extends AbstractFulfillmentProviderService {
  static identifier = "local-delivery"

  async getFulfillmentOptions(): Promise<FulfillmentOption[]> {
    return [{ id: "local-delivery" }]
  }

  // Checked when the Admin API creates or updates the option.
  async validateOption(data: Record<string, unknown>): Promise<boolean> {
    try {
      parseRates(data)
    } catch (e) {
      throw new MedusaError(MedusaError.Types.INVALID_DATA, (e as Error).message)
    }
    return true
  }

  async canCalculate(): Promise<boolean> {
    return true
  }

  // Runs when the buyer picks the option. Medusa has already refused an
  // address it cannot deliver to, for having no price ("do not have a
  // price"); this keeps the area (or zone) and km on the shipping method, for
  // whoever delivers, and refuses such an address itself should Medusa stop
  // checking.
  async validateFulfillmentData(
    optionData: Record<string, unknown>,
    data: Record<string, unknown>,
    context: ValidateFulfillmentDataContext,
  ): Promise<Record<string, unknown>> {
    try {
      const q = quote(parseRates(optionData), context as unknown as DeliveryCart)
      return { ...data, area: q.area, km: q.km }
    } catch (e) {
      if (e instanceof DeliveryError) {
        throw new MedusaError(MedusaError.Types.NOT_ALLOWED, e.message)
      }
      throw e
    }
  }

  // Medusa recalculates every time the cart changes. An address the rate
  // cannot place has no price rather than an error: Medusa then drops the
  // method from the cart and will not add it, where an error would fail the
  // cart's update.
  async calculatePrice(
    optionData: CalculateShippingOptionPriceDTO["optionData"],
    _data: CalculateShippingOptionPriceDTO["data"],
    context: CalculateShippingOptionPriceDTO["context"],
  ): Promise<CalculatedShippingOptionPrice> {
    let amount: number | undefined
    try {
      amount = quote(parseRates(optionData), context as unknown as DeliveryCart).amount
    } catch (e) {
      if (!(e instanceof DeliveryError)) {
        throw e
      }
    }
    return {
      calculated_amount: amount as number,
      is_calculated_price_tax_inclusive: true,
    }
  }

  async createFulfillment(): Promise<CreateFulfillmentResult> {
    return { data: {}, labels: [] }
  }

  async cancelFulfillment(): Promise<Record<string, unknown>> {
    return {}
  }

  async createReturnFulfillment(): Promise<CreateFulfillmentResult> {
    return { data: {}, labels: [] }
  }
}

export default LocalDeliveryProviderService
