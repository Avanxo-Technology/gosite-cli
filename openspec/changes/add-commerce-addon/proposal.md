## Why

With the commerce service running (`add-commerce-service`), a site still has no store pages. This change adds the Go half of the `Commerce` addon: product listing (PLP), product detail (PDP), a cart held on the server and a guest checkout, rendered by the site and made responsive with htmx and Alpine.js, which the core layout already loads. It closes the loop with the manual payment provider, so a new store can be exercised end to end with the seeded demo product.

## What Changes

- New Go addon `core/internal/addons/commerce`, enabled by listing `Commerce` in `gosite.yml`.
- Default routes with configurable paths: PLP (`commerce_plp_path`, default `/tienda`), PDP (`commerce_pdp_path`, default `/producto`, as `<path>/:handle`), checkout (`commerce_checkout_path`, default `/checkout`), plus cart endpoints under `/_commerce/`.
- PLP and PDP go through the page cache; price, stock, the add-to-cart form and the mini-cart are uncached htmx fragments ("islands").
- The browser never talks to Medusa: the site keeps `cart_id` and region in an httpOnly cookie and calls the Store API with the publishable key read from the shared volume.
- Carts are created lazily on the first add, never on a page view.
- Guest checkout only: email → address → shipping → payment → complete, each step a server-rendered htmx fragment; payment step lists the region's providers and, in this change, renders only the manual provider.
- A Medusa subscriber purges the site's page cache when products, variants, prices or categories change.
- All pages and fragments are addon pages that a theme overrides by file name, like Blog's.
- The addon contract gains configuration: an addon can read and validate its own `gosite.yml` keys at startup.
- The current region comes from one function (`commerce_region` today), so multi-region can be added later without touching handlers.

## Capabilities

### New Capabilities
- `commerce-storefront`: PLP, PDP, server-side cart, guest checkout with the manual provider, islands and cache purge, configurable routes, theme-overridable pages.

### Modified Capabilities
- `addon-config`: an addon's Go half may read and validate its own flat keys from `gosite.yml`, and startup fails on invalid values.

## Impact

- New: `core/internal/addons/commerce/` (Store API client, handlers, pages, tests); `services/medusa/src/subscribers/` (purge subscriber).
- `core/internal/addon/addon.go`: `Addon` gains a configuration hook; `core/gosite.go` passes the parsed `gosite.yml`.
- `core/gosite.go`: blank import of the commerce addon.
- Page cache keys for commerce pages include the region.
- Depends on `add-commerce-service` (service, seed, key file). Payment providers beyond manual come in `add-commerce-payments`.
