## Why

`gosite create` copies the whole Go core (`internal/app`, `cms`, `cache`, `seo`, `views`, `analytics`, `handlers`) and the Cockpit addons into each site, and from then on the site owns that copy. Every upgrade is a three-way merge per file, and every trap recorded in `MIGRATIONS.md` (manifest hashes that lie, duplicated declarations after a clean merge, `content` vs `content.Map()`, missing Forms config, purge wiping app state) comes from sites owning core code. The copies also let models building a site rewrite core. That is how lnequipos-v2 came to read Mongo directly and aga-growth got its own cache. Core has to become a dependency that sites cannot edit and that upgrades as a whole, the way WordPress core does.

## What Changes

- Publish the Go core as a public Go module with semantic versioning. Sites depend on it through `go.mod` and never contain its source.
- Add `gosite.Run(app)`: a small `App` interface (routes) plus optional interfaces (middleware, extra template data, purge hook). Core features such as sitemap, robots, llms, health, purge, SEO, analytics and consent register themselves.
- Add stable template slots (`gosite:head`, `gosite:body-start`, `gosite:body-end`) that layouts call instead of naming individual core partials. A theme overrides a core partial by defining a template with the same name.
- Add a documented page view model where `.Content` is always a `map[string]any`.
- Split Redis namespaces: core owns `<project>:cache:*`, and app state goes through `gosite.State()` under `<project>:app:*`, which purge never matches.
- Make the Cockpit REST client the only way core and sites read content. There is no direct Mongo reader.
- **BREAKING** (for newly created sites only): `gosite create` generates a thin site with `main.go`, `site/`, `theme/`, `gosite.yml` and a `go.mod` that requires the core module, instead of copying `internal/`.
- `gosite addons add/remove/list` edit and read the `addons` list in `gosite.yml`. The Go half of each addon becomes a package inside the core module that is enabled by that list. The PHP half is installed into the CMS image at the core version.
- `gosite sync` generates compose files, Dockerfiles and the core part of `cockpit/config.php` from `gosite.yml`. Local changes go in override files that sync never touches.
- Add a deprecation policy (a slot, field or option keeps working and logs a warning for at least one minor version before removal) and a `gositetest` contract-test helper.
- Existing sites keep working with no change. Moving them is a separate change (`migrate-sites-to-core-module`).

## Capabilities

### New Capabilities
- `core-module`: The versioned Go module, what it contains, its public API surface, semver and the deprecation policy.
- `app-extension-api`: `gosite.Run`, the `App` interface and its optional interfaces, the `gosite.State()` namespace, and the Cockpit client as the only content source.
- `theme-slots`: Template slots, overriding partials by name, the page view model, and the `gositetest` contract checks.
- `addon-config`: Addons declared in `gosite.yml`; `gosite addons add/remove/list` against that file; Go halves enabled from the module; PHP halves from the CMS image.
- `thin-scaffold`: What `gosite create` generates, the `gosite.yml` schema, and generated deploy/compose/config files with override files.

### Modified Capabilities
<!-- none: seo-resolution, seo-templates and webapp-addon keep their behaviour; the code moves into the module unchanged -->

## Impact

- **Repo:** a new Go module directory with its own `go.mod` and release tags. `src/templates/internal/**` and `src/templates/addons/*/internal/**` move into it. `src/templates` becomes the thin-site scaffold.
- **CLI:** `cmd_create.sh`, `cmd_addons.sh`, `cmd_update.sh` (sync), `lib/templates.sh` and the manifest logic.
- **CMS image:** `deploy/Dockerfile.cms` installs gosite's addons at the core version.
- **Release process:** CLI tags plus module tags. The release workflow must publish both.
- **Docs:** `README.md`, `docs/index.html`, the `MEMORY.md`/`ARCHITECTURE.md` templates, and a new `CORE_API.md` contract document.
- **Sites:** none in this change. The six existing sites and `analytics-draft` are untouched.
