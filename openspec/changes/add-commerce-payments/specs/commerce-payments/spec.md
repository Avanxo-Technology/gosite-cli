## ADDED Requirements

### Requirement: Providers enabled by credentials and region
The commerce service SHALL register the Stripe provider only when `STRIPE_API_KEY` is set and the Wompi provider only when its keys are set, and the providers offered at checkout SHALL be exactly those the store owner enabled on the cart's region in Medusa Admin that the site can render.

#### Scenario: Colombian store
- **WHEN** Wompi keys are set and the owner enables Wompi and manual on region `co`
- **THEN** the payment step offers Wompi and manual, and not Stripe

#### Scenario: Missing credentials
- **WHEN** `STRIPE_API_KEY` is not set
- **THEN** Stripe is not registered and cannot be enabled on any region

### Requirement: Embedded payment flow
For an embedded provider the payment step SHALL create the payment session on the server and render the provider's client-side form with the session's client secret, and the card data SHALL NOT pass through the site or Medusa.

#### Scenario: Stripe card payment
- **WHEN** a US buyer pays with a Stripe test card and the payment is confirmed in the browser
- **THEN** the site completes the cart, an order exists and the confirmation page is shown

#### Scenario: Card declined
- **WHEN** Stripe declines the card
- **THEN** the buyer stays on the payment step with the provider's message and no order exists

### Requirement: Redirect payment flow
For a redirect provider the site SHALL send the buyer to the provider's checkout URL from the payment session and SHALL complete the cart at `<checkout>/retorno` when the provider reports the payment as approved.

#### Scenario: PSE approved
- **WHEN** a Colombian buyer pays with PSE through Wompi and returns
- **THEN** the cart is completed and the confirmation page is shown

#### Scenario: Payment declined or pending
- **WHEN** the buyer returns with a declined or still pending transaction
- **THEN** no order is created, the cart is kept and the page states the transaction status

### Requirement: Webhook completes orders
A verified provider webhook reporting an approved payment SHALL complete the cart even if the buyer never returns to the site, and completing a cart twice SHALL produce one order.

#### Scenario: Buyer closes the tab
- **WHEN** Wompi approves a payment and the buyer closes the browser before the return
- **THEN** the webhook completes the cart and one order exists

#### Scenario: Forged webhook
- **WHEN** a webhook arrives with an invalid checksum
- **THEN** it is rejected and no cart or payment changes

#### Scenario: Return and webhook race
- **WHEN** the return route and the webhook complete the same cart at the same time
- **THEN** exactly one order exists and both paths report success

### Requirement: Amounts in the provider's unit
Amounts sent to a provider SHALL be converted from Medusa's amount in the region currency to the provider's unit without rounding loss, including COP.

#### Scenario: COP to Wompi
- **WHEN** a cart totals 59.900 COP
- **THEN** Wompi receives `amount_in_cents` 5990000 and the order total in Medusa is 59.900 COP

### Requirement: Refunds from Medusa Admin
A refund issued in Medusa Admin on an order paid with Stripe or Wompi SHALL be executed on the provider.

#### Scenario: Full refund
- **WHEN** the owner refunds a Wompi-paid order in Medusa Admin
- **THEN** the refund is requested from Wompi and the order shows the refund
