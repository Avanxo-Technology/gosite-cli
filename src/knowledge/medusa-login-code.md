# Signing in by e-mail code (gosite-medusa)

Checked on `gosite-medusa:0.61.0` (Medusa 2.21.2) with Mailpit.

## Turning it on

- SMTP and the Mailer as in `gosite docs medusa-mailer`.
- In Admin › Mailer, create the rule "Código de acceso" from its starting
  template (event `gosite.customer.login_code`, recipient "The event's email
  field") and switch it on. Without it the request route answers `no_rule`.

## The site's side

Both routes are internal: `/store` is not routed publicly, and each call
carries `X-Gosite-Token` (Medusa's `GOSITE_PURGE_TOKEN`; sites send their
`COCKPIT_API_TOKEN`, the same value) plus the publishable key.

- `POST /store/gosite/login-code { email }` → 200 `sent` (`new_account`,
  `expires_in_minutes`), 429 `too_soon` (`retry_after` seconds), 503
  `no_rule`, 502 `send_failed`, 400 `invalid_email`.
- `POST /store/gosite/login-code/verify { email, code }` → 200 `signed_in` or
  `created` with `token`, `claimed_orders` and `saved_addresses`; 400 `wrong`
  (`attempts_left`), `expired`, `invalid`; 429 `too_many_attempts`.

The token is the one Medusa's own login gives: keep it as the session (the
checkout session does the same), call the Store API with `Authorization:
Bearer`, renew it with `/auth/token/refresh`. `GET /store/orders/:id` answers
anyone with the id, so check `customer_id` before showing an order.

## Limits

10 minutes per code, one code a minute and five an hour per address, five
wrong tries per code; only the newest code works. The table keeps an HMAC of
the code (keyed with `JWT_SECRET`), and the Mailer log shows `••••••`. Codes
older than a day are deleted at 03:15.

## Accounts

A right code for an address without an account creates one; an account made
another way gets an `email-code` identity; the address's guest orders move
into the account (the code proved the address), and their shipping
addresses into its saved addresses. An empty address book is filled from
all the account's orders on sign-in, so accounts made before 0.61.0 get
theirs; the checkout session saves the paid order's address too. Template variables:
`$.data.code`, `$.data.expires_in_minutes`, `$.data.new_account`,
`$.data.email`, and `$.customer` for an existing account.
