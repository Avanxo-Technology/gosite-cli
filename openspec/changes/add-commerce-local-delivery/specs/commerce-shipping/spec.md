## ADDED Requirements

### Requirement: Local delivery priced by area and weight
The commerce service SHALL price a shipping option of the `local-delivery` provider from the option's data: the base amount, plus the per-km amount for every km or part of one past the included km of the buyer's area, plus the surcharge of the order's weight tier, rounded up to the rounding step.

#### Scenario: Near the store
- **WHEN** the buyer's area is within the included km and the order is in the lightest tier
- **THEN** the delivery costs the base amount

#### Scenario: Farther and heavier
- **WHEN** the area is 8.1 km away with 3 km included, 1.000 per km, and the order weighs 5.4 kg with a 3.000 tier above 5 kg
- **THEN** the delivery costs the base amount plus 6.000 plus 3.000

#### Scenario: The cart changes
- **WHEN** the buyer changes quantities after choosing delivery
- **THEN** the delivery price follows the new weight and total

### Requirement: Free delivery from an order total
Orders whose items add up to the option's `free_from` or more SHALL be delivered at no cost, inside the city and table.

#### Scenario: Reaching the total
- **WHEN** the items add up to `free_from`
- **THEN** the delivery costs 0, whatever the distance and weight

### Requirement: Only the city and areas in the table
An address outside the option's city, or whose `metadata.area` is not in its table, SHALL have no price for the option, and the cart's update SHALL NOT fail because of it.

#### Scenario: Moving to an area outside the table
- **WHEN** a cart with local delivery changes to an area not in the table
- **THEN** the cart is updated and its delivery method is dropped

#### Scenario: Choosing delivery outside the table
- **WHEN** the buyer chooses local delivery for an address in another city
- **THEN** the method is refused and the cart keeps no delivery method

### Requirement: Rates are the option's data
The rates SHALL be the shipping option's data and SHALL be checked when the option is created or updated, refusing wrong data with the field named.

#### Scenario: A wrong rate
- **WHEN** an option is created with `per_km` below 0
- **THEN** the Admin API refuses it naming `per_km`
