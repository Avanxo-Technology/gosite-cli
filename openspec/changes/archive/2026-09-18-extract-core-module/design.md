## Context

gosite is a bash CLI (`src/`) that scaffolds Go + Cockpit sites from `src/templates`. The Go core (`internal/app`, `cms`, `cache`, `config`, `seo`, `views`, `analytics`, `handlers`) is copied into each site. Addons are copied in two halves: PHP into `cockpit/addons/<Name>`, and Go overlays from `src/templates/addons/<name>/internal/**`. Upgrades follow `MIGRATIONS.md`: scaffold the old and new versions, then `git merge-file` each file. Six client sites plus `analytics-draft` exist. The repo is public (`Avanxo-Technology/gosite-cli`), and releases need a tag plus two assets.

Today the layout names core partials directly (`consent-head`, `analytics-head`, `analytics-body`, `consent-link`), and `internal/app/app.go` wires every dependency by hand. Sites edit both.

## Goals / Non-Goals

**Goals:**
- Core upgrades are a version bump. No file merges for sites.
- Sites cannot edit core, so a model working inside a site cannot fork it.
- New core features reach sites without layout or wiring edits.
- The CLI keeps its commands and options.

**Non-Goals:**
- Migrating existing sites (separate change `migrate-sites-to-core-module`).
- Fixing lnequipos-v2's direct Mongo reader (separate change `fix-lnequipos-cms-client`).
- A runtime plugin system (Go plugins, WASM).
- Site-specific Cockpit addons. Decided: every addon lives in gosite, and there is no `cockpit/site-addons/`.
- Changing SEO, analytics, consent or webapp behaviour. The code moves, and its behaviour stays the same.

## Decisions

### D1. The module lives in this repo under `core/`
Module path `github.com/Avanxo-Technology/gosite-cli/core`, tagged `core/vX.Y.Z` (Go's convention for a module in a subdirectory). The CLI's `VERSION` and the core version move in lockstep: CLI 0.60.0 scaffolds sites on `core/v0.60.0`.
- *Alternative: a separate `gosite` repo.* It gives a cleaner import path, but every change then touches two repos and two PRs, and the scaffold and core drift apart. It can be split out later with a `go.mod` redirect.
- *Why lockstep:* one number across the three version surfaces (repo, install, release) that already drift.
- Start with a v0 major version. The deprecation rule still applies within v0 minors, because the sites are in production.

### D2. Public packages versus `core/internal`
```
core/
  gosite.go          Run, App, Router, options, State()
  page.go            Page view model
  cms/               client (public: sites read collections)
  gositetest/        contract checks
  internal/cache, internal/seo, internal/views, internal/handlers, internal/config
  internal/addon (registry), internal/addons/blog (the only Go half), internal/siteconfig (gosite.yml)
  theme/             embedded default partials (embed.FS)
```
Only `gosite`, `cms`, `gositetest` and the Page types are public. Keeping the public surface small is what makes the deprecation rule affordable.

### D3. `App` plus optional interfaces, not a hook registry
```go
type App interface{ Routes(r Router) }
type Middlewarer interface{ Middleware() []Middleware }
type TemplateDataer interface{ TemplateData(ctx Context, page string) map[string]any }
type Purger interface{ OnPurge(ctx context.Context) error }
```
Detected with type assertions at startup. Adding a new optional interface never breaks existing sites.
- *Alternative: a WordPress-style string hook registry (`AddAction("init", fn)`).* It is flexible, but untyped and hard to discover, and a misspelled hook name fails silently. Go's type system gives the same extensibility checked at compile time.
- Echo v5 stays the router behind a thin `Router` wrapper, so a future Echo major version doesn't become a breaking change for sites.

### D4. Template slots aggregate core partials
`gosite:head` executes the ordered list of partials registered for the head (`gosite:seo`, `gosite:consent-head`, `gosite:analytics-head`, …). The same goes for `body-start` and `body-end`. Default partials are embedded in the module. The renderer parses core partials first and the theme's templates second, so a theme definition with the same name wins. This uses the override behaviour `html/template` already has, isolated per page clone.
- `gositetest.CheckTheme` parses the layout, counts slot calls, and renders every page with a synthetic `Page`. It replaces the demo-data view tests that break on real sites.

### D5. The Redis split
Cache keys move from `<project>:*` to `<project>:cache:*`. Purge scans only `<project>:cache:*`. `State()` returns a client wrapper that prefixes `<project>:app:`. Cockpit's memory on DB 1 is unaffected. Thin sites start clean, and the key rename for existing sites belongs to the migration change.

### D6. `gosite.yml` replaces `.gosite.env` for thin sites
YAML, read by `gosite.Run` (addons, feature toggles) and by the CLI. The CLI reads it with a minimal parser: flat keys plus one `addons:` list, so bash needs no YAML dependency. Legacy detection: a project with no `gosite.yml` takes the existing code paths, untouched.

### D7. PHP addons installed into the CMS image
`Dockerfile.cms` installs gosite's PHP addons from a named build context, `gosite-addons`: in production that context is `src/addons` of this repo at the `core/vX.Y.Z` tag (BuildKit fetches a git URL with a subdirectory), in development it is the installed gosite's `src/addons`. `src/addons` stays the single source; nothing is copied into `core/`. Which addons are enabled is controlled by `config.core.php`, generated from `gosite.yml`, so all addons can sit in the image with only the listed ones active.
- *Alternative: copy only the listed addons.* It needs a rebuild on every add or remove either way. Controlling activation through config is simpler.
- *Verified (spike 0.1, cockpithq/cockpit:core-2.14.0):* `Lime\App::__construct` merges the config array into its registry, and `loadModule()` skips any module whose name is in `$registry['modules.disabled']`. So `config.core.php` sets `'modules.disabled' => [<every gosite addon not in gosite.yml>]`. The names are the directory basenames (`Blog`, `Forms`, …), because gosite addons load without a prefix.

### D8. Generated files plus override files
*Why a new command and not `gosite sync`:* sync was removed (cf7efa6) because it decided file by file whether gosite still owned something and failed silently. `gosite generate` never has to decide: it runs only on thin sites, and it only overwrites a file that carries the generated header. A file whose header is gone is reported and left alone.

`gosite generate` renders `docker-compose.yml`, `docker-compose.{qa,prod}.yml`, `deploy/*` and `cockpit/config.core.php`, each carrying a `# generated by gosite sync — edit gosite.yml or the override` header. `config.php` becomes a stub that includes core first and then `config.local.php` if present. Compose uses Docker's native `docker-compose.override.yml` for dev, and QA/prod overrides are merged by listing a second compose file in the Coolify config. The Coolify bare `${SERVICE_FQDN_APP}` rule must be kept in the prod template.

### D9. What implementation added
- **Core's browser assets live in the module.** `consent.js`, `analytics.js` and `consent.css` were copied into each site's `static/`, the same drift as the Go code. Core embeds them and registers each as an exact route under `/static/`, so they win over a same-named file in the site.
- **`Router.CachedRender`.** Sites need cached pages, and the cache is core's. Pages are keyed by URL under `<project>:cache:page:`, and every purge, narrow or site-wide, clears that group, because a site's page is not tied to one CMS model.
- **`.gosite.env` stays as the runtime marker.** `start`, `list` and `remove` read it. `gosite.yml` is the source for `generate` and `addons` only.
- **The override compose file is merged explicitly.** Every project command passes `-f docker-compose.yml`, which stops Compose from loading `docker-compose.override.yml` on its own. `project_compose` adds it for thin sites.
- **`GOSITE_CORE_DEV`.** Before a core tag exists, `create --thin` can point `go.mod` at a local `core/` with a `replace`, and the override mounts it at the same path in the dev container. For developing gosite only; the production image cannot see it.

## Risks / Trade-offs

- [A public API frozen too early] → Keep v0, a minimal public surface (D2), and optional interfaces rather than more methods on `App`.
- [Sites need something core doesn't expose, and people go back to vendoring or forking] → A documented escape hatch: `replace` in `go.mod` for local experiments only, and `gositetest` fails CI if `replace` points outside the module proxy. The real fix goes upstream.
- [Go module proxy caching: a bad tag can't be retracted] → Use the `retract` directive plus a patch release. Tag only after CI passes on a thin scaffold.
- [Two scaffold paths (legacy and thin) in the CLI for a while] → Legacy paths are frozen with no new features, and they're deleted once the six sites are migrated.
- [A future Cockpit version renames or removes `modules.disabled`] → Pin the Cockpit image tag. A core test boots the CMS image with one addon disabled and checks that its routes are absent.
- [Template override order bugs (a theme partial not winning)] → Contract test in core: an override fixture for every slot partial.
- [Coolify may not support `additional_contexts` with a git URL] → Verified with Docker Compose 5.1.4 locally, not on Coolify (task 7.0). Fallback: `generate` copies the enabled addons into a committed `cockpit/.gosite-addons/` directory for production builds.
- [Bash reading YAML] → Restrict the schema to flat keys plus one list, and test it in CI on Linux (watch the set -e + $() abort pattern).

## Migration Plan

1. Build `core/` by copying code with its tests, and adapt imports. Copy, not move: legacy `create`/`addons` still render `src/templates/internal`, which stays frozen until the thin default flips and is then deleted. CI builds the module on its own.
2. Add the `gosite.Run`/slots/Page layers. Port the scaffold's own tests to them.
3. Add the thin scaffold behind `gosite create --thin` while the existing path is still the default. Verify on a sandbox site in a redirected `GOSITE_HOME`, never on `~/gosites` projects other than analytics-draft.
4. Release workflow: tag `vX.Y.Z` and `core/vX.Y.Z` together, plus the CMS image assets.
5. Flip the default to thin in a minor release. Legacy sites keep working because nothing detects them as thin.
6. Rollback: CLI releases before the flip still scaffold legacy sites, and thin sites pin their core version.

## Open Questions

- ~~Site-specific Cockpit addons?~~ No, every addon lives in gosite.
- ~~Boot-time upgrade steps?~~ They belong to `migrate-sites-to-core-module`, because thin sites start clean.
- ~~Does Cockpit support disabling an installed addon through config (D7)?~~ Yes, `modules.disabled` (see D7).
- ~~Module path?~~ `github.com/Avanxo-Technology/gosite-cli/core`, confirmed.
