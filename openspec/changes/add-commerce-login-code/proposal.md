## Why

Since 0.58.0 a buyer who pays gets an account with an `email-code` identity and a session, but nothing lets them sign in again once that session ends: the identity has no password and no route sends a code. Stores also want buyers who never paid online (or who bought as guests) to reach their orders with the same address.

## What Changes

- New `loginCode` module: one row per code sent (address, keyed hash, expiry, wrong attempts, consumed). Codes older than a day are deleted daily (`cleanup-login-codes`).
- New internal route `POST /store/gosite/login-code { email }` (shared token `GOSITE_PURGE_TOKEN`, like `checkout-session`): e-mails a six-digit code valid for 10 minutes, at most one a minute and five an hour per address. The e-mail is the store's active Mailer rules on the new event `gosite.customer.login_code`, sent by the route itself (not the event bus) so the answer says whether it left (`sent`, `too_soon`, `no_rule`, `send_failed`).
- New internal route `POST /store/gosite/login-code/verify { email, code }`: five wrong tries spend a code. A right code signs the address in with the same customer token as Medusa's own login; an address without an account gets one; an account made another way gets an `email-code` identity; the address's guest orders move into the account, and their shipping addresses into its saved addresses (an empty book is filled from all its orders, so older accounts get theirs too). `checkout-session` saves the paid order's address the same way.
- Mailer: event `gosite.customer.login_code` (variables `$.data.code`, `.expires_in_minutes`, `.new_account`), starter "Código de acceso", previews with a made-up code. A delivery can carry a secret: the code is sent but stored as `••••••`, and a failed code e-mail is not retried (it would arrive expired).
- `checkout-session` uses the shared account helpers (`lib/customer-account.ts`); its behaviour is unchanged.

## Capabilities

### New Capabilities
- `commerce-accounts`: signing in by e-mail code, accounts created by it, guest orders claimed.

### Modified Capabilities
- `commerce-mailer`: one more gosite event, sent synchronously, with its secret kept out of the log.

## Impact

- `services/medusa/`: `src/modules/login-code/`, `src/lib/login-code.ts`, `src/lib/customer-account.ts`, `src/api/store/gosite/login-code/`, `src/jobs/cleanup-login-codes.ts`, mailer `rules.ts`, `send.ts`, `starters.ts`, `context.ts`, Admin `helpers.ts`, `medusa-config.ts`. New table `login_code` (migration in the image).
- Sites: a store turns it on by creating the "Código de acceso" rule in Admin › Mailer; its site asks for and checks codes through the two routes (aldu-dev does) and keeps the token as the session, as after checkout.
