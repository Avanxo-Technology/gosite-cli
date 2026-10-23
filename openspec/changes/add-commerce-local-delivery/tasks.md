## 1. Provider

- [x] 1.1 `delivery.ts`: rates parsing with field-named errors, area lookup without case or accents, weight with fallbacks, tiers, rounding, free from a total; unit tests
- [x] 1.2 `service.ts`: calculated price, no price for an address it cannot place, area and km kept on the method, option data checked on create and update
- [x] 1.3 Registered in `medusa-config.ts` with the manual provider

## 2. Verification

- [x] 2.1 Unit tests and `tsc`
- [x] 2.2 End to end on aldu-dev through the Admin and Store APIs: provider enabled on the location, option created with 211 areas; Centro 10.000, El Prado 11.000, Riomar 16.000, Las Flores 18.000; 3 pairs of boots (5.4 kg) 19.000; from 300.000 free; an area outside the table drops the method and cannot be added; another city cannot be added; pickup (manual, flat 0) unaffected

## 3. Release

- [x] 3.1 CHANGELOG, VERSION 0.62.0 (released as 0.62.1), `gosite docs medusa-local-delivery`
