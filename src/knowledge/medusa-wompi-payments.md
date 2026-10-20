# Wompi payments in gosite-medusa

Checked on `gosite-medusa:0.58.0` (Medusa 2.21.2) against Wompi's sandbox.

## Settings

- Four keys register the provider (`pp_wompi_wompi`): `WOMPI_PUBLIC_KEY`,
  `WOMPI_PRIVATE_KEY`, `WOMPI_INTEGRITY_SECRET`, `WOMPI_EVENTS_SECRET`. Then
  enable it on the region in Medusa Admin.
- Test keys (`pub_test_`, `prv_test_`, `test_integrity_`, `test_events_`) go
  with `WOMPI_API_URL=https://sandbox.wompi.co/v1`; production keys with
  `https://production.wompi.co/v1` (the default). Mixing them fails every
  transaction lookup. `WOMPI_CHECKOUT_URL` is `https://checkout.wompi.co/p` for
  both.
- Wompi's "URL de eventos" is per Wompi environment and points at Medusa, on
  the shop domain: `https://<SERVICE_FQDN_SHOP>/hooks/payment/wompi_wompi`.
  Medusa answers 200 to any `/hooks/payment/<name>`, so a 200 from curl only
  proves the route is reachable, not that the name is right.

## The order before the payment (0.58.0)

- Completing a cart whose Wompi session has no transaction yet creates the
  order awaiting payment and reserves its stock (`pending_authorization`).
  The webhook captures it; `expire-pending-payments` (every 5 minutes)
  catches a lost webhook and cancels what was not paid (failed at once, none
  started after `COMMERCE_PENDING_PAYMENT_TTL_MINUTES`, started but undecided
  after `COMMERCE_PENDING_PAYMENT_MAX_HOURS`).
- Local development never receives Wompi's webhook (it goes to the URL set in
  Wompi). A local payment is settled by the job instead, within 5 minutes.
- The checkout URL's `expiration-time` is signed:
  `sha256(reference + amount_in_cents + currency + expiration + integrity secret)`.

## Testing without a browser

The sandbox pays a reference through the API: `GET /merchants/<public key>`
(acceptance token), `POST /tokens/cards` (card `4242 4242 4242 4242` approves,
`4111 1111 1111 1111` declines), `POST /transactions` with the reference and
`signature = sha256(reference + amount_in_cents + currency + integrity secret)`.
Then post the event to `/hooks/payment/wompi_wompi` signed as Wompi does:
`checksum = sha256(transaction.id + transaction.status +
transaction.amount_in_cents + timestamp + events secret)`.
