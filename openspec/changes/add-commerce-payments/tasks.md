## 0. Spikes

- [ ] 0.1 Re-check for a maintained Medusa v2 Wompi module; record in design.md D3
- [ ] 0.2 Confirm in Wompi sandbox which methods (card, PSE, Nequi, Bancolombia) support refunds and voids
- [ ] 0.3 Confirm that Medusa's payment webhook workflow completes the cart on `authorized` in the pinned version; if not, add a subscriber that does

## 1. Provider registration

- [x] 1.1 `medusa-config.ts` builds providers from env: manual always, Stripe if `STRIPE_API_KEY`, Wompi if its keys
- [x] 1.2 Compose passes the Stripe and Wompi env (empty by default); QA uses test/sandbox keys

## 2. Wompi module

- [x] 2.1 `src/modules/wompi`: `initiatePayment` with Web Checkout URL and integrity signature
- [ ] 2.2 Status lookup by reference mapping APPROVED/PENDING/DECLINED/VOIDED/ERROR
- [x] 2.3 Webhook: event checksum verification and action mapping; forged event rejected
- [ ] 2.4 Refund/void
- [x] 2.5 COP/USD amount conversion with decimal arithmetic; unit tests (59.900 COP, 19.99 USD)
- [ ] 2.6 Daily reconciliation job for pending sessions older than 1 h

## 3. Go renderers

- [ ] 3.1 Embedded renderer for `pp_stripe_`: session on the server, `_pay_stripe.html` with Stripe.js loaded only on the step, htmx complete after confirm
- [x] 3.2 Redirect renderer for `pp_wompi_`: button to the Web Checkout URL
- [x] 3.3 `<checkout>/retorno`: complete on approved; pending page polling a status fragment; declined keeps the cart
- [ ] 3.4 Tests: completed-cart treated as success, return/webhook race yields one order (against a Medusa test instance)

## 4. Cockpit addon

- [ ] 4.1 Seed (commerce service): secret API key for Cockpit written to `/run/gosite-commerce/admin_key`; compose mounts it read-only in the Cockpit container only
- [ ] 4.2 `src/addons/Commerce` skeleton (bootstrap, admin) following Blog's layout; GET-only Medusa Admin API client reading the key file
- [ ] 4.3 Products page: list with drafts, thumbnail, title, handle, status, price, inventory; search and pagination; row links to Medusa Admin; error state when Medusa is down
- [ ] 4.4 `commerceproduct` field type (single/multiple) storing handles
- [ ] 4.5 Menu link to `shop.<site domain>/app`
- [ ] 4.6 Document how a project models extended data (example `product_extras` collection and `featured_products` singleton) and loads it by handle in templates

## 5. Template helper

- [ ] 5.1 `commerceProducts` helper with 60 s in-process cache, skipping missing or unpublished handles
- [ ] 5.2 Document it in `CORE_API.md` with a featured-products example

## 6. Verification

- [ ] 6.1 US store (analytics-draft-v2, region `us`): Stripe test card, declined card, 3-D Secure card, refund from Admin
- [ ] 6.2 CO store (region `co`): Wompi sandbox card, PSE approved, PSE declined, Nequi pending then approved by webhook with the tab closed
- [ ] 6.3 Cockpit: products page lists the demo product and a draft; a `featured_products` singleton picks three products, one is deleted in Admin, the page still renders; a `product_extras` entry shows on its PDP
- [ ] 6.4 Document provider onboarding for the client's own Wompi/Stripe accounts (test keys in QA, live keys in prod, webhook URLs, region enablement) in the README
