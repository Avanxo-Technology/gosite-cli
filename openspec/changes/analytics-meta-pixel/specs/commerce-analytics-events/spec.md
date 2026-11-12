## ADDED Requirements

### Requirement: The storefront emits e-commerce events through analytics.track
The Commerce storefront SHALL send `ViewContent`, `AddToCart`, `InitiateCheckout` and `Purchase` through `analytics.track()`, so every enabled provider receives them under the consent it already needs. Properties SHALL be `value` (number), `currency` (ISO 4217, upper case), `content_ids` (variant ids), `content_type` (`product`) and `num_items`; `Purchase` SHALL also carry `order_id`.

#### Scenario: Product page
- **WHEN** a consented visitor opens a product page
- **THEN** `ViewContent` is sent once with the product's variant id, price and currency

#### Scenario: Add to cart
- **WHEN** a consented visitor adds a variant to the cart
- **THEN** `AddToCart` is sent with that variant id, its unit price, the quantity and the currency

#### Scenario: Checkout
- **WHEN** a consented visitor opens the checkout
- **THEN** `InitiateCheckout` is sent with the cart total, currency, variant ids and item count

#### Scenario: Order confirmed
- **WHEN** a consented visitor reaches the confirmation of a completed order
- **THEN** `Purchase` is sent with the order total, currency, variant ids, item count and order id

### Requirement: Events are data, never inline script
Server-rendered pages SHALL carry events as `<script type="application/json" data-analytics-event>` blocks, and htmx responses SHALL carry them in an `HX-Trigger` header; no value from the store SHALL be interpolated into executable JavaScript.

#### Scenario: Product name with a quote
- **WHEN** a product title contains `"` or `</script>`
- **THEN** the page still parses, the event is sent, and no script runs from the title

### Requirement: Purchase is counted once per order
`Purchase` SHALL be sent at most once per order in a browser session, and SHALL pass the order id as Meta's `eventID` so Meta can deduplicate.

#### Scenario: Reload the confirmation
- **WHEN** the visitor reloads the confirmation page
- **THEN** no second `Purchase` is sent

### Requirement: No event without consent
Events SHALL NOT be sent, and SHALL NOT be queued for later, while the visitor has not consented to the category a provider needs.

#### Scenario: Undecided visitor buys
- **WHEN** a visitor who has not answered the banner completes an order
- **THEN** no provider receives `Purchase`, also after the visitor accepts later
