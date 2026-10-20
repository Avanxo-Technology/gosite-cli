## Context

Medusa 2.21 supports deferred payments: when a provider's `authorizePayment` returns `pending_authorization`, `completeCartWorkflow` creates the order and reserves inventory without a payment record, and `processPaymentWorkflow` has an `authorize-existing-order` branch that authorizes it when the provider's webhook reports `authorized`. Cancelling an order (`cancelOrderWorkflow`) deletes its reservations. `GET /store/orders/:id` needs no login. The customer module allows one registered and one guest customer per address (unique on email + has_account).

## Decisions

**D1. Use Medusa's deferred authorization, not draft orders.** The provider decides: no Wompi transaction or a PENDING one is `pending_authorization`; APPROVED is `captured` (Web Checkout charges on approval); DECLINED, VOIDED, ERROR are `error`. Alternative: create a draft order at "Pagar" and convert it on payment. Rejected: draft orders hold no stock and the webhook maps to the cart's payment session, not a draft's.

**D2. The checkout URL expires with the order.** `expiration-time` = now + the pending window (60 min), signed as `reference + amount + currency + expiration + secret` (Wompi's rule; checked in the sandbox: Web Checkout shows the methods and a countdown). A buyer cannot start paying an order the job already cancelled. A payment started before the expiry can still settle later (PSE): see D3.

**D3. One job settles, the webhook is the fast path.** Every 5 minutes the job lists recent orders (created within max hours + 24 h) whose payment collection is `awaiting` with a Wompi (`pp_wompi_wompi`) session in `pending_authorization`, reading every page of them, and calls `paymentModule.authorizePaymentSession` for each: a payment record means paid (a missed webhook, or local development, where webhooks never arrive); `null` means still deferred; a `NOT_ALLOWED` error means the provider reported failure; any other error (Wompi unreachable) is retried next run. Cancel when failed, when no transaction exists after the TTL, or when a started one is undecided after max hours (a PSE payment in progress is not cancelled at one hour). The provider records which case it is in the session data as `transaction_status` (`none` or Wompi's status). A cancelled order with an authorized or completed collection is logged as an error once (`metadata.gosite_paid_after_cancel`).

**D4. The buyer's session: proof of the cart, never of the address.** The checkout address is not verified, so a session is given only for an account the order itself created. The site calls `POST /store/gosite/checkout-session` with the order's cart id (only the browser that placed it holds it) and the shared `GOSITE_PURGE_TOKEN` (already shared by the site and Medusa; `/store` is not routed publicly). Decisions (pure, `lib/checkout-session.ts`): unpaid → `pending`; cancelled → `canceled`; older than 24 h → `expired`; address has an account this order did not create → attach the order, no token; otherwise create the customer (`createCustomerAccountWorkflow`) with an auth identity of provider `email-code`, move the order to it, and return a token built by Medusa's own `generateJwtTokenForAuthIdentity` (same secret, lifetime and claims as a login, so `/store/customers/me` and `/auth/token/refresh` accept it). Calls are serialized per order with the locking module, so a page polling twice never creates two accounts.

**D5. Passwordless from the start.** Accounts get an `email-code` identity and no password, so the later sign-in by e-mail code needs no migration: it registers an auth provider with that id (send a code, verify it).

## Risks

- A payment approved after its order was cancelled is captured on a cancelled order; it is logged for a refund. The URL expiry makes it rare.
- The job reads every recent order, 200 per page, each run. A shop with thousands of orders in its window makes one run longer, not partial.
- Other providers' deferred sessions (Stripe) are left to those providers: the job only settles Wompi's.
