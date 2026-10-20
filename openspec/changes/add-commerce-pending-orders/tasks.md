## 1. Wompi provider

- [x] 1.1 `authorizationStatus`: no transaction / PENDING → `pending_authorization`, APPROVED → `captured`, else `error`; unit tests
- [x] 1.2 `authorizePayment` records `transaction_status`; a Wompi API failure throws
- [x] 1.3 `expiration-time` on the checkout URL, in the integrity signature; unit tests; checked in the sandbox
- [x] 1.4 Empty `WOMPI_API_URL` / `WOMPI_CHECKOUT_URL` fall back to Wompi's URLs

## 2. Pending orders

- [x] 2.1 `lib/pending-payments.ts`: window from env, cancel decision, settle loop, awaiting filter, paid-after-cancel; unit tests
- [x] 2.2 `jobs/expire-pending-payments.ts` every 5 minutes
- [x] 2.3 End to end on the sandbox: order before payment with its reservation; approved → captured; declined → cancelled by the job; unpaid → cancelled after the TTL, reservations deleted

## 3. Checkout session

- [x] 3.1 `lib/checkout-session.ts`: decisions, address normalization, shared token; unit tests
- [x] 3.2 `POST /store/gosite/checkout-session`: new account with an `email-code` identity and a customer token; existing account gets the order; locked per order
- [x] 3.3 End to end: token accepted by `/store/customers/me`; second call reissues; existing address gets no token; wrong token 401

## 4. Later (not this change)

- [ ] 4.1 `email-code` auth provider: send and verify a code, then Medusa's token
- [ ] 4.2 Notification provider for the code e-mail
