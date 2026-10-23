## Why

The seed gives a store one shipping option: free, anywhere in the country. A store that delivers in its own city (aldu-dev: Barranquilla, by its own courier) needs a price that grows with the distance from the store and with the order's weight, and free delivery from an order total. Medusa's manual provider only has flat prices, and flat options per zone cannot follow weight.

## What Changes

- New fulfillment provider `local-delivery` (`AbstractFulfillmentProviderService`), always registered next to Medusa's manual one: calculated price from a base amount, km past the included ones, a weight tier surcharge, rounding, and free from an order total.
- The rates are the shipping option's `data` (city, area -> km table, amounts, tiers), checked when the option is created or updated; the store sets them up through the Admin API. Nothing comes from env or files.
- The buyer's area is the shipping address's `metadata.area`; weight is the variant's, else the product's, else a default.
- An address outside the city or the table has no price (not an error), so Medusa drops the method from a cart that moves there instead of failing the cart's update. The chosen area and km stay in the shipping method's `data`.
- `medusa-config.ts` lists the fulfillment providers (manual and local-delivery).

## Capabilities

### New Capabilities
- `commerce-shipping`: local delivery priced by area and weight.

### Modified Capabilities
<!-- none -->

## Impact

- `services/medusa/`: `src/modules/local-delivery/` (`delivery.ts` pure, `service.ts`, `index.ts`), `medusa-config.ts`, `tests/local-delivery/`.
- No migration, no env. Existing stores keep their options until they create one with the provider (`gosite docs medusa-local-delivery`).
