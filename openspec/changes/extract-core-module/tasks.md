## 0. Spikes (resolve open questions first)

- [x] 0.1 Verify whether Cockpit can disable an installed addon via config; record the result in design.md D7
- [x] 0.2 Decide on the module path (`gosite-cli/core` or a renamed/split repo) before any tag
- [x] 0.3 Decide on site-specific addons and on boot-time upgrade steps (in or out of this change)

## 1. Core module skeleton

- [x] 1.1 Create `core/go.mod` (`github.com/Avanxo-Technology/gosite-cli/core`, go 1.25, echo v5, go-redis v9)
- [x] 1.2 Copy (not move: the legacy scaffold still reads them) `src/templates/internal/{app,cache,config,seo,views,handlers,analytics}` into `core/internal/` with their tests, `cms` into `core/cms`, and the tailwind views as the interim default theme
- [x] 1.3 Replace `__MODULE__` imports with the module path and `__PROJECT__`/`__REDIS_*__` with runtime config (`GOSITE_PROJECT`); `go build ./... && go test ./...` passes in `core/`
- [x] 1.4 Add a CI job that builds and tests `core/` on Linux

## 2. App extension API

- [x] 2.1 Implement `gosite.Run`, `App`, `Router` wrapper and options, moving the wiring from `internal/app/app.go` and `cmd/server/main.go`
- [x] 2.2 Implement optional interfaces (middleware, template data, purge hook) with startup detection and tests (template data is detected here and reaches pages in 3.3)
- [x] 2.3 Core routes (health, robots, sitemap, llms, favicon, purge) self-register; site routes on the same path win; per-feature disable options
- [x] 2.4 Move cache keys to `<project>:cache:*`, restrict purge to that prefix, add `gosite.State()` under `<project>:app:*`; test that purge keeps state keys and TTL
- [x] 2.5 Confirm no direct Mongo content reader exists in the module; the cms client is the only reader

## 3. Theme slots and view model

- [x] 3.1 Embed default partials in the module; implement slots `gosite:head`, `gosite:body-start`, `gosite:body-end` as ordered partial lists
- [x] 3.2 Parse order core-then-theme so theme definitions override by name; fixture test per slot partial
- [x] 3.3 Define `gosite.Page` (`.Title`, `.Path`, `.Content` as map, `.SEOData`, `.Data`, `.IsDev`) and `Router.Render`, merging `TemplateData` into `.Data`
- [x] 3.4 Add `gositetest.CheckTheme` (missing slot, duplicate slot, page execution failure)
- [x] 3.5 Deprecation helper: log-once warning naming the replacement; unit test

## 4. Addons as module packages

- [ ] 4.1 Move addon Go halves (`src/templates/addons/*/internal/**`) into `core/addons/<name>` with self-registration keyed by name
- [ ] 4.2 `gosite.Run` reads `addons` from `gosite.yml`, enables listed addons, fails on unknown names
- [ ] 4.3 Move PHP addons into `core/cockpit-addons/`; `Dockerfile.cms` installs them for `GOSITE_CORE_VERSION`
- [ ] 4.4 Generate `modules.disabled` (gosite addons not listed in gosite.yml) into `config.core.php`

## 5. Thin scaffold and CLI

- [ ] 5.1 Create the thin scaffold: `main.go`, `site/`, `theme/` per flavor, `static/`, `gosite.yml`, `go.mod` requiring the core version
- [ ] 5.2 Minimal `gosite.yml` reader/writer in `src/lib` (flat keys plus `addons:` list) with CI tests on Linux
- [ ] 5.3 `gosite create --thin` writes `gosite.yml` from existing flags (`--storage`, `--database`, `--addons`, `--no-addons`, `-y`)
- [ ] 5.4 `gosite sync` for thin sites: regenerate compose, Dockerfiles, `config.core.php` with generated headers; never touch `docker-compose.override.yml` or `config.local.php`; keep the bare `${SERVICE_FQDN_APP}` form
- [ ] 5.5 `gosite addons list/add/remove` edit `gosite.yml` for thin sites; keep legacy behaviour when `gosite.yml` is absent
- [ ] 5.6 Legacy detection everywhere: projects without `gosite.yml` take today's code paths unchanged

## 6. Verification

- [ ] 6.1 Sandbox (redirected `GOSITE_HOME`/`GOSITE_WORKSPACE`): `create --thin -y`, start, home renders from CMS, no core source in tree
- [ ] 6.2 Bump core minor in the sandbox site with a feature added to `gosite:body-end`; rendered page shows it with no site edits
- [ ] 6.3 Add and remove Blog through `gosite addons` on the sandbox site; routes appear and disappear; content stays in the database
- [ ] 6.4 Run `gosite sync` and check a local compose override and `config.local.php` survive
- [ ] 6.5 Confirm a legacy project (copy of analytics-draft in the sandbox) still syncs and runs unchanged

## 7. Release and docs

- [ ] 7.1 Release workflow tags `vX.Y.Z` and `core/vX.Y.Z` together and publishes the required assets
- [ ] 7.2 Write `core/CORE_API.md` (public surface, slots, Page fields, deprecation policy)
- [ ] 7.3 Update `README.md`, `docs/index.html` (commands, folder tree), `MEMORY.md`/`ARCHITECTURE.md` templates in `cmd_create.sh`
- [ ] 7.4 Bump `src/VERSION`
- [ ] 7.5 Later minor release: flip `create` default to thin (tracked here, shipped after 6.x passes)
