## Why

After `add-commerce-addon` a store can only take manual payments. Our first markets are Colombia and the USA: Colombian buyers expect PSE, Nequi and cards (Wompi covers all three), US buyers expect cards and wallets (Stripe). Which providers a store offers must be the store owner's decision per region in Medusa Admin, not a code change. This change also adds the small Cockpit half of the addon, so editors can place store products on content pages without a second product catalogue.

## What Changes

- The `gosite-medusa` image registers Stripe (official module) and a new gosite Wompi payment module; each is active only when its credentials are set, and the store owner enables them per region in Medusa Admin.
- New Wompi provider module (`AbstractPaymentProvider`): Web Checkout redirect with integrity signature, return handling, webhook with event checksum verification, transaction status lookup, refunds.
- Payment renderers in the Go addon for the two new flow kinds: embedded (Stripe Payment Element with the session's client secret) and redirect (Wompi), next to the existing manual one.
- Return route `<checkout>/retorno` completes the cart after a redirect payment; the Wompi webhook completes it even if the buyer never returns.
- New Cockpit addon `Commerce` (PHP): a read-only products page fed by the Medusa Admin API, a product-picker field type, and a link to Medusa Admin on `shop.<site>`; nothing of the catalogue is copied into Cockpit. Extended product data is modelled per project with its own collections and singletons referencing products by handle.
- Templates can render products picked in Cockpit (e.g. featured products on the home page) through a template helper that fetches them live.

## Capabilities

### New Capabilities
- `commerce-payments`: provider registration by credentials, per-region enablement, embedded and redirect flows, Wompi module, webhook-driven completion, amounts and currencies.
- `commerce-cockpit`: the Cockpit addon (read-only products page, product picker field, admin link), the rule that extended data lives in project collections/singletons, and the template helper that renders picked products.

### Modified Capabilities
<!-- none: the storefront's payment step (commerce-storefront) already hides unrenderable providers; new renderers are additions -->

## Impact

- `services/medusa/`: Stripe module config, new `src/modules/wompi/`, env `STRIPE_API_KEY`, `STRIPE_WEBHOOK_SECRET`, `WOMPI_PUBLIC_KEY`, `WOMPI_PRIVATE_KEY`, `WOMPI_INTEGRITY_SECRET`, `WOMPI_EVENTS_SECRET`, `WOMPI_ENV`.
- `core/internal/addons/commerce/`: embedded and redirect renderers, return route, product template helper.
- `src/addons/Commerce/` (PHP) in the CMS image; `config.core.php` generation already enables/disables it by the addons list.
- Stripe.js loaded only on the payment step. Webhook URLs on the commerce domain (`/hooks/payment/<provider>`), already routed by `add-commerce-service`.
- Depends on `add-commerce-service` and `add-commerce-addon`.
