## 0. Spikes

- [ ] 0.1 On Coolify, verify a named volume shared read-only between services of one stack (D6) and how a fixed `shop.<domain>` coexists with Coolify's domain handling (D7); record both in design.md
- [x] 0.2 Pin the Medusa v2 version; confirm `medusa exec` runs a script before `medusa start` in a production build

## 1. Medusa project and image

- [x] 1.1 Create `services/medusa/` (Medusa v2, TypeScript) with `medusa-config.ts` reading `DATABASE_URL`, `REDIS_URL`, `JWT_SECRET`, `COOKIE_SECRET`, `COMMERCE_REGION`, admin CORS from env
- [x] 1.2 Dockerfile + entrypoint: `db:migrate`, seed, `medusa start`; local build runs against Postgres and Redis
- [ ] 1.3 Release workflow builds and pushes `gosite-medusa:<version>` with the same tag as the CLI and core

## 2. Seed

- [x] 2.1 Region table (`co`, `us`) and fail-fast on unknown `COMMERCE_REGION`
- [x] 2.2 Create-if-missing by `metadata.gosite_seed`: region, sales channel, stock location, shipping option, manual provider on the region, publishable key
- [x] 2.3 Demo product (one variant, price in the region currency, stock) created once, tracked in store metadata so a deleted demo product is not recreated
- [x] 2.4 Admin user from `COMMERCE_ADMIN_EMAIL`, password printed once on creation
- [x] 2.5 Write the publishable key to `/run/gosite-commerce/publishable_key`
- [x] 2.6 Tests: empty DB, restart, renamed product, deleted product, unknown region

## 3. Cart cleanup

- [x] 3.1 Daily scheduled job deleting uncompleted carts older than `COMMERCE_CART_TTL_DAYS` (default 30)
- [x] 3.2 Test: old uncompleted cart deleted, completed cart and orders untouched

## 4. CLI and generated compose

- [x] 4.1 Add `Commerce` to `Library` in `core/internal/addon/addon.go` and to the CLI addon library
- [x] 4.2 `_thin_render`: keep or drop `# gosite:addon <Name>` / `# gosite:end` blocks by the addons list; test that no marker survives
- [x] 4.3 Commerce blocks in the three generated compose files: `medusa`, `medusa-db`, `medusa-redis`, volumes, shared key volume mounted read-only in the app, `COMMERCE_REGION` from `commerce_region`
- [ ] 4.4 Traefik labels on `shop.<site domain>` per environment for `/app`, `/admin`, `/auth`, `/hooks` only, router names per the QA/prod rule
- [x] 4.5 Per-project secrets (`JWT_SECRET`, `COOKIE_SECRET`, DB password) generated into `.env` on generate when missing
- [x] 4.6 Test: a site without `Commerce` regenerates byte-identical compose files; `generate` output names the commerce services when enabled

## 5. Verification

- [ ] 5.1 In analytics-draft-v2: enable Commerce, generate, up; Admin reachable, demo product visible, Store API refused from the browser and served from the app container
- [ ] 5.2 Remove Commerce, regenerate: services gone, volumes kept; re-enable restores the store
- [ ] 5.3 Coolify deploy of the same site from its QA and prod compose files: two independent Medusa stacks (an order in QA is absent in prod); measure idle memory of the commerce services and record it in the README
- [ ] 5.4 Document enabling a store in README and MIGRATIONS.md
