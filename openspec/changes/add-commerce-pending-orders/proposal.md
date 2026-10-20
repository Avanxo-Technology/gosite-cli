## Why

With Wompi the order only existed once the payment was confirmed: the buyer left for Web Checkout with a cart, the stock was not held while they paid, and a buyer who closed the tab left nothing a store owner could follow. Stores want the order the moment the buyer presses "Pagar", with its stock reserved until the payment is confirmed or abandoned, and the buyer recognised afterwards as a customer, not a guest.

## What Changes

- The Wompi provider answers `pending_authorization` while the buyer has not paid (no transaction, or a PENDING one), so `completeCartWorkflow` creates the order and reserves its stock before payment; an APPROVED transaction is `captured`. Medusa's own `authorize-existing-order` branch authorizes the order when the webhook arrives.
- The Web Checkout URL carries `expiration-time` (in the integrity signature), set to the pending window, so a checkout left open cannot be paid after its order was cancelled.
- New job `expire-pending-payments` (every 5 minutes): asks the provider about each order awaiting payment; authorizes it if paid (a missed webhook), cancels it if the payment failed, or if nobody started paying within `COMMERCE_PENDING_PAYMENT_TTL_MINUTES` (60), or if a started payment is still undecided after `COMMERCE_PENDING_PAYMENT_MAX_HOURS` (24). Cancelling releases the reservations. A payment found on a cancelled order is logged once for a person to refund.
- New internal route `POST /store/gosite/checkout-session { cart_id }` (shared token `GOSITE_PURGE_TOKEN`): once the order is paid, an address without an account gets a registered customer with an `email-code` auth identity (no password) and a customer token; an address with an account gets the order attached and no token. For 24 hours after the order only.
- The Wompi module no longer treats an empty `WOMPI_API_URL` / `WOMPI_CHECKOUT_URL` as a URL, and a Wompi API failure throws instead of reading as "not paid".

## Capabilities

### New Capabilities
- `commerce-pending-orders`: orders placed before payment, stock held while it is awaited, expiry and reconciliation, and the session of the buyer who paid.

### Modified Capabilities
<!-- commerce-payments' redirect flow keeps working: a cart a site does not complete before redirecting is still completed by the webhook. -->

## Impact

- `services/medusa/`: `src/modules/wompi/`, `src/lib/pending-payments.ts`, `src/jobs/expire-pending-payments.ts`, `src/lib/checkout-session.ts`, `src/api/store/gosite/checkout-session/route.ts`, `medusa-config.ts`. New optional env: `COMMERCE_PENDING_PAYMENT_TTL_MINUTES`, `COMMERCE_PENDING_PAYMENT_MAX_HOURS`.
- Sites: to place the order before payment, a site completes the cart before redirecting to the checkout URL (aldu-dev does). Core's flow (complete on return or by webhook) is unchanged.
- Not in this change: signing in with an e-mail code (the `email-code` provider and its routes), the notification that sends the code, account pages.
