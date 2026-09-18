## Context

Thin sites run Go (core module) + Cockpit + Mongo, with Redis/MinIO/Traefik shared on the host. Addons today have a Go half (registered in `core/internal/addon`) and a PHP half (in the CMS image); neither brings containers. `gosite generate` copies a fixed set of files from `src/templates-thin/generated/` and substitutes placeholders; `gosite.yml` is a flat YAML subset (`key: value` and `- item` lists) read by both bash and Go, with no nesting.

Commerce is three changes. This one delivers the running engine; `add-commerce-addon` builds the storefront (PLP, PDP, cart, checkout with the manual provider) and the Cockpit product picker; `add-commerce-payments` adds Stripe, a Wompi module and the embedded/redirect payment renderers.

## Goals / Non-Goals

**Goals:**
- A site can switch a store on with `gosite addons add Commerce` + `gosite generate`, locally and on Coolify.
- A fresh store is usable end to end with no credentials: region, channel, key, shipping, manual payment and a demo product.
- The Go site gets its publishable key with no manual step.
- Nothing changes for sites that do not list `Commerce`.

**Non-Goals:**
- Storefront routes and templates (next change).
- Card or redirect payment providers (third change).
- Multi-region per site, customer accounts, DIAN e-invoicing, US sales-tax providers.
- A commerce admin inside Cockpit.

## Decisions

**D1. One Medusa per site and per environment.** Each generated compose file (dev, QA, prod) declares the site's own `medusa`, `medusa-db` and `medusa-redis`; QA and prod never share a database. Nothing commerce-related goes into the host-shared infra (`gosite infra`). Alternatives considered: one shared Medusa with a store/sales channel per client. Rejected: isolation, blast radius, and Medusa's RBAC is Enterprise-only, so a shared admin would expose every client's data to every admin user. Cost: ~3 containers per store; measured in the Coolify task before rollout.

**D2. Our own image, `gosite-medusa`, released in lockstep with the core.** The project lives in `services/medusa/` (Medusa v2, TypeScript) and is built by the release workflow as `ghcr.io/avanxo-technology/gosite-medusa:<version>`. Sites never scaffold Medusa code, which keeps them thin; the same rule as the CMS image carrying the PHP addons. Alternative: scaffold a Medusa project into each site. Rejected: it recreates the drift problem thin sites just removed. Per-site customisations (custom modules) are out of scope until a real need appears.

**D3. Addon-gated compose blocks.** Coolify deploys one compose file, so separate `docker-compose.commerce.yml` files or `include:` would not reach production. The generated compose templates carry blocks delimited by `# gosite:addon Commerce` / `# gosite:end`; `_thin_render` keeps a block (without its markers) when the addon is listed and drops it otherwise. Blocks are line-based and never nested, which the BSD awk/sed constraints allow. Alternative: generate compose from Go. Rejected: the generator is bash today and this is small.

**D4. Flat config keys.** `commerce_region: co` (and, in the next change, `commerce_plp_path`, `commerce_pdp_path`, `commerce_checkout_path`). `siteyml.sh` and `core/internal/siteconfig` stay flat. The value reaches Medusa as `COMMERCE_REGION` in the rendered compose. Supported codes live in one table in the seed (`co`: COP, CO, es; `us`: USD, US, en); adding a region is adding a row.

**D5. Seed = create-if-missing, keyed by stable handles.** Every seeded record carries a gosite handle or metadata (`metadata.gosite_seed = "<name>"`); the seed looks records up by that marker, creates what is missing, and never updates. A deleted demo product must stay deleted, so the seed records "demo product created" in a `gosite_seed_state` key in Medusa's store metadata instead of re-checking for the product. Runs as a Medusa `exec` script before `medusa start` in the container entrypoint, after `db:migrate`.

**D6. Key handoff via shared volume.** The seed writes `/run/gosite-commerce/publishable_key` on a named volume mounted read-only in the site container; the Go addon (next change) reads it at startup and retries until it exists. Alternative: env var set by hand in Coolify. Rejected: manual, error-prone, and the known `SERVICE_FQDN`/env quirks in Coolify. Alternative: an internal endpoint on Medusa that returns the key. Rejected: needs its own auth.

**D7. Exposure.** The commerce domain is always the `shop.` subdomain of the site's domain (`shop.<site>`), set by the CLI in the generated compose for each environment (so QA gets `shop.<qa domain>`). Traefik routes it to Medusa for `/app`, `/admin`, `/auth` and `/hooks` only; `/store` is not routed, so the Store API is internal (the site calls `http://medusa:9000`). Router names follow the QA/prod naming rule from `qa-prod-traefik-router-collision`. CORS for the admin is the commerce domain only.

**D8. Cart cleanup as a Medusa scheduled job** (`src/jobs/`), daily, deleting carts with `completed_at IS NULL` and `updated_at` older than `COMMERCE_CART_TTL_DAYS`. Lazy cart creation on the site (next change) keeps the volume low in the first place.

**D9. Secrets.** `JWT_SECRET`, `COOKIE_SECRET` and the Postgres password are generated per project by `gosite create`/`generate` into the site's `.env` (never committed) and read by Coolify's env UI in production. The admin user is created by the seed from `COMMERCE_ADMIN_EMAIL`; its password is printed once in the service log on first creation and must be changed.

## Risks / Trade-offs

- [Memory per store on the Coolify host] → measure a seeded store's idle RSS in the Coolify task; document the figure in MIGRATIONS/README before any client rollout.
- [Medusa minor releases break the seed or config] → pin exact Medusa versions in `services/medusa/package.json`; upgrades are a gosite release, tested with the seed on an empty and on a seeded database.
- [Compose block markers edited by hand] → the generated-file mark rule already stops `generate` from overwriting hand-edited files; a test asserts that no marker survives rendering.
- [Admin password in logs] → printed only on first creation; the README tells owners to rotate it. Alternative (email invite) needs a notification provider, deferred.
- [Postgres is new to our operations] → backups are not covered by our Mongo tooling; out of scope here, tracked as an open question before the first production store.

## Migration Plan

Additive. Sites without `Commerce` regenerate byte-identical compose files (tested). Enabling: `gosite addons add Commerce`, set `commerce_region`, `gosite generate`, deploy, open the commerce domain `/app`. Rollback: remove the addon and regenerate; volumes stay, so re-enabling restores the store.

## Open Questions

- Postgres backup strategy for production stores (before the first real client).
- Coolify: does a fixed `shop.<domain>` label coexist with Coolify's own domain handling for the service, or does it need the `SERVICE_FQDN_MEDUSA` form set to that value? (Checked in spike 0.1.)
- Verify on Coolify that a named volume can be shared read-only between two services of the same stack (spike task 0.1).
