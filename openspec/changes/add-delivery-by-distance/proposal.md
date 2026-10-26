## Why

The area table limits the buyer to the neighbourhoods someone listed: a barrio missing from it, or spelled another way, cannot be delivered to. aldu-dev wants the price to follow the distance from the store to the buyer's own address, found on a map, and to keep bulk orders (many units of one product) out of the standard rate so the store arranges them.

## What Changes

- `local-delivery` measures the distance one of two ways: the existing `areas` table, or `origin` (the store's point) and the straight line to the point in the shipping address's `metadata.lat`/`metadata.lng`. The two are exclusive.
- With `origin`, optional `zones` (named rings of `[lng, lat]` corners) limit delivery to the places in them and name the one the point falls in, and a zone's optional `city` reaches a neighbouring municipality (the address must name it); optional `max_km` caps the distance. The zone's name is kept on the shipping method as `area`.
- Optional `bulk_units`, either way: an order with that many units of one product (its variants added up) gets no price.
- An address without a point, outside the zones or past `max_km`, and a bulk order, have no price, as an address outside the table does today.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `commerce-shipping`: distance from a point on the map, zones, and bulk orders.

## Impact

- `services/medusa/src/modules/local-delivery/` (`delivery.ts`, `service.ts` comments), `tests/local-delivery/`.
- Options made with `areas` keep working unchanged. No migration, no env.
