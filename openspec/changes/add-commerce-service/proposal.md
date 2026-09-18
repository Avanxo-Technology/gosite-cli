## Why

gosite sites cannot sell. Clients in Colombia and the USA need an optional store (catalog, cart, checkout) without leaving gosite, and we chose MedusaJS v2 as the commerce engine (`ecommerce.md`: MIT core, workflows/modules/links for extension). This change is the first of three: it brings up the commerce service itself, so the storefront (`add-commerce-addon`) and payments (`add-commerce-payments`) have something real to talk to.

## What Changes

- New gosite-maintained Medusa v2 image (`gosite-medusa`), versioned in lockstep with the core module, with our `medusa-config.ts`, an idempotent seed and a cart-cleanup job.
- New library addon `Commerce`. Listing it in `gosite.yml` makes `gosite generate` add the commerce services (Medusa, its Postgres, its Redis) to the site's compose files; removing it takes them out again and leaves their volumes.
- One commerce service per site (not shared across sites). Medusa's own Admin (`/app`) is the only place where the catalog, prices, stock and orders are managed; nothing of that is duplicated in Cockpit.
- The seed runs on every start and only creates what is missing: one region from `commerce_region` (`co` → COP, `us` → USD), a sales channel, a stock location, a shipping option, the manual payment provider on the region, a publishable API key, and one demo product with a variant and a price, so the default PLP/PDP/checkout can be exercised with no credentials.
- The publishable key reaches the Go site through a shared volume file written by the seed, not through a hand-copied env var.
- Medusa is exposed on its own domain for `/app` (admin) and `/hooks/*` (payment webhooks, used by the payments change); the Store API is only reached from the site container over the internal network.
- Anonymous carts older than a configurable age that were never completed are deleted by a scheduled job.
- New flat `gosite.yml` keys: `commerce_region` (and the route keys consumed by `add-commerce-addon`). `gosite.yml` stays flat; no nesting is introduced.

## Capabilities

### New Capabilities
- `commerce-service`: the per-site Medusa service: image, conditional compose, seed contract (region, channel, key, demo product), key handoff to the site, exposure rules, cart cleanup.

### Modified Capabilities
- `addon-config`: `Commerce` joins the addon library, and enabling or removing an addon can add or remove services in the generated compose files (today addons only toggle Go and PHP halves).

## Impact

- New: `services/medusa/` (Node/TS project, Dockerfile), release job publishing `gosite-medusa:<version>`.
- `src/templates-thin/generated/docker-compose*.yml`: addon-gated service blocks; `src/lib/thin.sh` rendering of those blocks; `src/lib/siteyml.sh` unchanged (flat keys).
- `core/internal/addon/addon.go`: `Commerce` in `Library` (the Go half itself lands in `add-commerce-addon`).
- Infra per store: +Node, +Postgres, +Redis containers (memory on the Coolify host), one more public domain per store.
- Release: the Medusa image becomes a third versioned artifact next to the CLI assets and the core module tag.
