## Context

After the first two changes, a store has Medusa per site, a Go storefront with a checkout step machine and a payment renderer registry holding only `pp_system_default` (manual). Medusa lists providers per region (`GET /store/payment-providers?region_id=`), creates payment collections and sessions, exposes `/hooks/payment/<provider_id>` for webhooks, and its `completeCartWorkflow` authorizes the payment, creates the order and rolls the payment back on failure. Markets: Colombia (COP) and the USA (USD), one region per site.

## Goals / Non-Goals

**Goals:**
- Stripe for US stores, Wompi (cards, PSE, Nequi, Bancolombia) for Colombian stores, manual everywhere.
- Store owners pick providers per region in Medusa Admin; developers only set credentials.
- Adding another provider later = a Medusa module + a renderer, no checkout rewrite.
- A minimal Cockpit half that links content to products without duplicating them.

**Non-Goals:**
- PayPal, Mercado Pago, PayU (same redirect pattern, later).
- DIAN e-invoicing, US sales-tax providers.
- Saved cards, subscriptions, partial captures.
- Product CRUD in Cockpit.

## Decisions

**D1. Credentials gate registration.** Merchant accounts belong to each client (decided): the client's own Wompi or Stripe keys are set as env vars of that site's QA (test/sandbox keys) and prod (live keys) deployments in Coolify; Avanxo holds no merchant account. `medusa-config.ts` builds the `providers` array from env: manual always, Stripe if `STRIPE_API_KEY`, Wompi if its four keys. Enablement per region stays in Medusa Admin. Alternative: a `commerce_providers` key in `gosite.yml`. Rejected: duplicates a decision Medusa already owns and needs a redeploy for a business choice.

**D2. Three renderer kinds in Go.** Registry keyed by provider id prefix:
- `pp_system_default` → manual: "Confirm order" button, then complete.
- `pp_stripe_` → embedded: the step creates the session, renders `_pay_stripe.html` with the publishable Stripe key and `client_secret`; Stripe.js (loaded only on this step) confirms with `redirect: "if_required"`, then an htmx POST completes the cart. 3-D Secure redirects come back to `<checkout>/retorno`.
- `pp_wompi_` → redirect: the session's data carries the Web Checkout URL; the step renders a button that navigates there.

**D3. Wompi as our own Medusa module.** No official Medusa v2 module is known; spike 0.1 checks for a maintained community one before we write ours. `AbstractPaymentProvider` implementation:
- `initiatePayment`: build the Web Checkout URL with `reference` = payment session id, `amount-in-cents`, currency, `redirect-url` = `<site>/<checkout>/retorno`, and the SHA-256 integrity signature (`reference + amount + currency + integrity secret`).
- `authorizePayment` / `getPaymentStatus`: look up the transaction by reference with the private key; APPROVED → authorized/captured, PENDING → pending, DECLINED/VOIDED/ERROR → error.
- `getWebhookActionAndData`: verify the event checksum with the events secret, map `transaction.updated` to authorized/failed.
- `refundPayment`: Wompi refund API (void when supported for the method).
- `WOMPI_ENV` selects sandbox or production endpoints.

**D4. Completion from two paths, one order.** The return route and the webhook both call cart completion. The webhook path is Medusa's own (its payment webhook workflow is expected to complete the cart after `authorized`; spike 0.3 confirms this on the pinned version). The return route calls `POST /store/carts/:id/complete`; a cart already completed yields its order, which we treat as success (D6 of the addon design). Medusa's cart-completion lock prevents two orders.

**D5. Amount conversion in one function per provider.** Medusa v2 stores amounts in the currency's main unit (BigNumber). Wompi: `amount_in_cents = round(amount * 100)` with decimal arithmetic, COP included. Stripe's module handles its own zero-decimal table. Unit tests with 59900 COP and 19.99 USD.

**D6. Cockpit half: a read-only window on Medusa, plus a picker.** `src/addons/Commerce/`:
- a Commerce page listing products (drafts included) from the Medusa **Admin API**, read-only, each row linking to the product in Medusa Admin;
- a `commerceproduct` field type (single/multiple) that searches the same API and stores handles;
- a menu link to Medusa Admin on `shop.<site domain>/app`.
Credentials: the seed creates a Medusa secret API key for Cockpit and writes it to `/run/gosite-commerce/admin_key` on the shared volume, mounted read-only in the Cockpit container only (never in the site). The addon issues only `GET` requests. Medusa v2 secret keys are not scopable, so the key could write; this is accepted because the Cockpit container is already trusted with the site's content, and it is noted as a risk.
Extended product data is **not** part of the addon: each project models it as its own collections and singletons with a `commerceproduct` field (e.g. `product_extras`, `featured_products`), and its templates load them by handle. Alternative: an addon-shipped `commerce_content` model. Rejected: every project needs different fields.
Alternative for listing: go through the site with the Store API. Rejected: it only returns published products in the sales channel, and editors need to see drafts.

**D7. Template helper.** `commerceProducts .Content.featured` in templates returns live product cards (price in region) for a list of handles, fetched through the Store API client with a short in-process cache (60 s) and skipping missing handles. The page cache still applies to the page as a whole; purge events from Medusa (addon design D6) keep it fresh.

## Risks / Trade-offs

- [Wompi module is ours to maintain] → contract tests against the sandbox in CI (manual trigger), recorded fixtures for unit tests; pin the API version.
- [Webhook URL unreachable (DNS, Traefik)] → the return route still completes the order in the common case; a daily reconciliation job queries pending Wompi sessions older than 1 h and completes approved ones.
- [PSE/Nequi pending for minutes] → the return page shows "pending" and polls the status fragment every 5 s via htmx for up to 10 min; the webhook finishes it otherwise.
- [Stripe.js and CSP / cookie consent] → Stripe loads only on the payment step, which is strictly necessary for the purchase; document it for the consent addon.
- [Secret admin key in the Cockpit container can write to Medusa] → mounted only in Cockpit, read-only file, GET-only client, rotated by deleting it in Admin and restarting Medusa (the seed recreates it).
- [Test vs live keys mixed] → the admin shows the mode; Wompi sandbox and Stripe test keys are required in QA compose, live keys only in prod env.

## Migration Plan

Additive. Existing stores get new providers only after credentials are set and the owner enables them on the region. Rollback: unset credentials; the providers disappear from registration and from checkout; manual remains.

## Open Questions

- Does Wompi's refund API cover PSE and Nequi, or only cards? (Spike 0.2; if not, those refunds are marked manual in Admin.)
