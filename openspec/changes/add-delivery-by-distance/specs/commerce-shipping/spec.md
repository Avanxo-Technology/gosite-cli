## ADDED Requirements

### Requirement: Distance from a point on the map
When the option's data has `origin` instead of `areas`, the commerce service SHALL measure the km as the straight line from `origin` to the point in the shipping address's `metadata.lat` and `metadata.lng`, to a tenth of a km, and price them as it prices an area's km.

#### Scenario: A point 5 km from the store
- **WHEN** the point is 5.0 km from `origin`, with 3 km included and 1.000 per km
- **THEN** the delivery costs the base amount plus 2.000, plus the weight surcharge

#### Scenario: No point
- **WHEN** the address has no `metadata.lat` and `metadata.lng`
- **THEN** the option has no price for the cart

### Requirement: Zones and the farthest delivery
With `origin`, the commerce service SHALL deliver only to points inside one of the option's `zones`, when it has them, and within `max_km`, when it has it, and SHALL keep the zone's name on the shipping method as `area`.

#### Scenario: A point in a zone
- **WHEN** the point falls in the ring of the zone "Riomar"
- **THEN** the method's `data.area` is "Riomar" and `data.km` its distance

#### Scenario: A zone in a neighbouring municipality
- **WHEN** the point falls in a zone whose `city` is "Soledad"
- **THEN** the option prices it when the address's city is Soledad, and has no price when it says another city

#### Scenario: A point outside the zones
- **WHEN** the point is outside every zone, or farther than `max_km`
- **THEN** the option has no price for the cart, even when the order would be free

### Requirement: Bulk orders are arranged with the store
When the option's data has `bulk_units`, an order with that many units of one product, its variants added up, SHALL get no price from the option.

#### Scenario: Six pairs of one boot
- **WHEN** `bulk_units` is 6 and the cart holds 3 pairs size 38 and 3 pairs size 40 of one boot
- **THEN** the option has no price for the cart

#### Scenario: Several products, a few of each
- **WHEN** the cart holds 5 units of each of four products
- **THEN** the option prices the order as usual
