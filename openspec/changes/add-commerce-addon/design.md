## Context

`add-commerce-service` gives each store a Medusa v2 service on the project network (`http://medusa:9000`), a seeded region, a demo product and the publishable key in `/run/gosite-commerce/publishable_key`. The core layout already loads htmx 2 and Alpine.js 3. The core page cache stores whole pages under `<project>:cache:*` and is purged through `POST /cache/purge`. Addons register a Go half (`Mount`, `Pages`) keyed by name; Blog is the only one today.

## Goals / Non-Goals

**Goals:**
- PLP, PDP, cart and guest checkout that work with the seeded demo product and the manual provider.
- Fast pages: cached HTML, live price/stock/cart through small fragments.
- The cart lives in Medusa; the site only holds a cookie; the browser never sees Medusa.
- Paths configurable; pages overridable by themes.
- One place decides the region, so multi-region is an addition later.

**Non-Goals:**
- Card and redirect providers (`add-commerce-payments`).
- Customer accounts, order history, wishlists.
- Search beyond category filter and pagination.
- Multi-region selection.

## Decisions

**D1. Addon configuration hook.** `Addon` gains `Configure func(cfg siteconfig.Config) error`, called by `gosite.New` before `Mount`, in addon order. The addon keeps what it parsed in package state set by `Configure` and read by `Mount`. Keys are namespaced by prefix (`commerce_*`) because `gosite.yml` stays flat. Alternative: pass config to `Mount` (changes Blog's signature). Rejected: the new optional field keeps existing addons untouched.

**D2. Server as the only Medusa client.** A small typed Store API client in the addon (`net/http`, JSON, timeouts, `x-publishable-api-key` header). Alternative: htmx calling Medusa directly or Medusa's JS SDK in the browser. Rejected: exposes the key, needs CORS on Medusa, and moves the cart state to the client, which is the opposite of the "backend controls the cart" goal. The key is loaded from the file at startup, with retries while the file is missing; until it exists, store routes answer 503 and the rest of the site works.

**D3. Cookie.** `gosite_cart` = `<cart_id>.<region>`, httpOnly, SameSite=Lax, Secure outside dev, 30 days. No server-side session store: Medusa is the state. A cookie whose cart is missing, completed or of another region is dropped (see spec).

**D4. Region from one function.** `currentRegion(c) string` returns the configured `commerce_region`; handlers, cart creation and cache keys call only this. Multi-region later changes this function (cookie, domain) and adds a selector.

**D5. Islands.** PLP/PDP render product content from the cache. Each PDP embeds `<div hx-get="/_commerce/buy/<handle>?v=<variant>" hx-trigger="load">` for price, stock and the add form; the header embeds the mini-cart fragment the same way. Cart mutations return the changed fragment plus the mini-cart as `hx-swap-oob`. Alpine handles only local UI: variant option selection (which triggers the island reload), quantity steppers and the cart drawer. Forms are real `<form method="post">` so they work without JS (progressive enhancement): the handler answers a redirect when `HX-Request` is absent.

**D6. Cache keys and purge.** Commerce pages use `page:commerce:<region>:<path>` under the existing prefix, so the existing purge-all and group purge reach them. A Medusa subscriber on `product.*`, `product-variant.*`, `product-category.*`, `product-collection.*` and price events calls the site's `POST /cache/purge` with the existing token (`COCKPIT_API_TOKEN` reused as the purge secret, passed to Medusa via env). Alternative: short TTL only. Rejected: prices must not be stale for minutes after an edit.

**D7. Checkout as a step machine.** `GET <checkout>` renders the step derived from the cart (no email → email; no shipping address → address; no shipping method → shipping; else payment). Each step POSTs to `/_commerce/checkout/<step>`, updates the Medusa cart and returns the next step's fragment. The step is never stored separately; the cart is the state, so a reload resumes correctly. Complete: `type == "order"` → clear cookie, redirect to `<checkout>/gracias/<order display id>`. The sequential order number is shown on purpose (decided); the page renders only for the browser that just completed that cart (a short-lived signed cookie set on complete), so guessing another number shows nothing; `type == "cart"` → show error, keep cookie.

**D8. Payment renderer registry.** `map[providerPrefix]Renderer` where a renderer has a kind (`manual`, `embedded`, `redirect`) and a fragment template. This change registers `pp_system_default` → manual. Unknown providers are hidden and logged once. The payments change adds renderers without touching the step machine.

**D9. Address form per region.** The address fragment is `pages/commerce/address_<region>.html` with a generic fallback; `co` asks for departamento and municipio, `us` for state and ZIP. Also the extension point for multi-region.

**D10. Pages.** Embedded under the addon's `pages/`: `commerce-plp.html`, `commerce-pdp.html`, `commerce-buy.html`, `commerce-cart.html`, `commerce-cart-lines.html`, `commerce-minicart.html` and (later) the checkout pages. Page names are flat because core discovers `pages/*.html` only (CORE_API: a theme is `layout.html`, `pages/*.html`): a theme overrides one by shipping `pages/commerce-pdp.html`. Fragments (buy, cart lines, mini-cart) are the same files served on their own via `ExecuteTemplate("content")`; overriding a fragment would need a fragment renderer in core (deferred). The header's `#commerce-minicart` element needs an addon-contributed slot partial, which core does not support yet (only `views.WithSlotPartial` at the site level), so the mini-cart is returned as an oob swap but nothing places it in the layout until that lands (deferred). Default markup uses the core Tailwind classes.

## Risks / Trade-offs

- [Store API latency on every island] → islands are small; the client keeps a pooled HTTP connection; PLP prices come from the cached page's list call, only the PDP island is live. Measure p95 in the verification task.
- [Double submit on "complete"] → the button disables itself (`hx-disabled-elt`); Medusa's complete workflow is idempotent for an already completed cart and we treat that as success.
- [Purge storms during bulk imports] → the subscriber debounces (one purge per 5 s window).
- [Theme overrides drift from fragment contracts] → document the IDs and form field names each fragment relies on; a `gositetest` helper renders every commerce page of a theme against fixtures.
- [Key file not yet written on first deploy] → 503 on store routes only, with retry; logged once.

## Migration Plan

Additive for sites without `Commerce`. Enabling on a site that already has `add-commerce-service`: bump the core, `gosite generate`, deploy. Rollback: remove the addon; store routes disappear, Medusa data stays.

## Open Questions

- Should the PLP be the site's own Cockpit page with a product-grid block instead of a fixed route? (Possible later, using the Cockpit product picker from the payments change.)
