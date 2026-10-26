## 1. Provider

- [x] 1.1 `delivery.ts`: `origin`, `zones`, `max_km`, `bulk_units` parsed with field-named errors; haversine km to a tenth; point in ring; units per product; unit tests
- [x] 1.2 `service.ts`: unchanged behaviour, comments for both ways of measuring

## 2. Verification

- [x] 2.1 Unit tests and `tsc`
- [x] 2.2 End to end on aldu-dev through the Admin and Store APIs with an image built from this branch: the option moved from `areas` to `origin` (old table sent as null), Barranquilla's five localidades as zones, `bulk_units` 6. Centro 10.000, El Prado (3.5 km) 11.000, Riomar (6.5 km) 14.000, Las Flores (8.5 km) 16.000; coordinates as strings priced the same; Soledad (7 km, outside every zone) and an address without a point get no price and the method is refused (400); 3+2 pairs of one boot 14.000 (with 9 kg), 3+3 no price, 3+3 of two products 17.000. The `areas` way is covered by the unit tests

## 3. Release

- [ ] 3.1 CHANGELOG, VERSION 0.63.0, `gosite docs medusa-local-delivery`
