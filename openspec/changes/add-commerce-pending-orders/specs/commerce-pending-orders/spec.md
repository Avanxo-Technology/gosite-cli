## ADDED Requirements

### Requirement: Order placed before payment
When a site completes a cart whose payment session is Wompi's before the buyer pays, the commerce service SHALL create the order awaiting payment and reserve its stock.

#### Scenario: "Pagar" pressed
- **WHEN** the cart is completed and Wompi holds no transaction for its reference
- **THEN** an order exists with payment status `awaiting` and a reservation for each line

#### Scenario: Payment approved
- **WHEN** Wompi's verified webhook reports the transaction APPROVED
- **THEN** the order's payment is captured and its stock stays reserved for fulfilment

### Requirement: Stock released when the payment does not come
The commerce service SHALL cancel an order awaiting payment, releasing its reservations, when the provider reports its payment failed, when no payment was started within the pending window, or when a started payment is still undecided after the maximum wait.

#### Scenario: Card declined
- **WHEN** Wompi reports the transaction DECLINED
- **THEN** the order is cancelled within one job run and its reservations are deleted

#### Scenario: Buyer never pays
- **WHEN** no transaction exists `COMMERCE_PENDING_PAYMENT_TTL_MINUTES` after the order
- **THEN** the order is cancelled and its reservations are deleted

#### Scenario: Transfer in progress
- **WHEN** a PENDING transaction exists after the pending window but before `COMMERCE_PENDING_PAYMENT_MAX_HOURS`
- **THEN** the order keeps waiting

#### Scenario: Webhook lost
- **WHEN** the transaction is APPROVED but no webhook arrived
- **THEN** the job authorizes the order on its next run

### Requirement: Checkout URL expires with the order
The Wompi checkout URL SHALL carry a signed `expiration-time` equal to the pending window.

#### Scenario: Old checkout tab
- **WHEN** a buyer opens a checkout URL after its expiration time
- **THEN** Wompi does not let them start a payment

### Requirement: Session of the buyer who paid
The commerce service SHALL give the site a customer token for a paid order only when the request proves the order's cart and carries the shared token, and only for an account that order created.

#### Scenario: New address
- **WHEN** the order is paid and its address has no account
- **THEN** a registered customer with an `email-code` identity is created, the order moves to it, and a customer token is returned

#### Scenario: Address with an account
- **WHEN** the order is paid and its address already has an account the order did not create
- **THEN** the order is attached to that account and no token is returned

#### Scenario: Not paid or wrong token
- **WHEN** the order awaits payment or is cancelled, or the shared token is wrong
- **THEN** no account is created and no token is returned
