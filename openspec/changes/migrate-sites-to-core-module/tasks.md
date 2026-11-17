## 1. Site addons in thin sites (gosite-cli PR)

- [x] 1.1 `src/lib/thin.sh`: detect `cockpit/site-addons/*/`, refuse a name that is a gosite addon (no file written), and pass a flag to the Dockerfile.cms render
- [x] 1.2 `src/templates-thin/generated/deploy/Dockerfile.cms`: emit the `COPY cockpit/site-addons/ /var/www/html/addons/` line only when the flag is set
- [x] 1.3 `tests/thin.bats`: no folder (byte-identical Dockerfile), one site addon, a collision with `Forms`, `generate` leaves the folder untouched
- [x] 1.4 Prove it in a sandbox thin site: build the CMS image and check that the site addon is in it next to gosite's (`php -l` passes); running `install.php` needs Mongo and is left to the avanxo pilot (5.9)
- [x] 1.5 Docs: README, `docs/index.html` folder tree, AGENTS.md/ARCHITECTURE.md templates of the scaffold, `core/CORE_API.md` (Cockpit addons)

- [x] 1.6 Fix found on the way: `gosite generate` exited 0 when a check inside `thin_generate` failed (process substitution); it now exits non-zero

## 2. WithFuncs (gosite-cli PR)

- [ ] 2.1 `core/gosite.go`: `WithFuncs(template.FuncMap)` option; `core/internal/views`: merge after core's functions; a name collision returns an error from `New`/`Run`
- [ ] 2.2 Go tests: a theme uses a site function; a collision fails with the name; `gositetest.CheckTheme` accepts the extra functions
- [ ] 2.3 `core/CORE_API.md` (Options table, Template functions)

## 3. Forms addon: update, field options, reCAPTCHA (gosite-cli PR)

- [ ] 3.1 `Helper/Forms.php`: `updateData()` (sanitize, merge, no dispatch); `fieldOptions`, `recaptchaMinScore`, `recaptchaActions` in the `formSettings` model and in `migrateSettingsModel()`
- [ ] 3.2 `Helper/Forms.php`: `verifyRecaptcha()` with the rules of D9 (5-second timeout, fail open on transport errors, log lines), called from `handleSubmission()` before the rate limit and from `updateData()` when a token is given
- [ ] 3.3 `api.php`: `PATCH /forms/submissions/{id}` (`forms/manage`, 404 for an unknown ID) and `GET /forms/settings/{form}` (only `label` and `fieldOptions`)
- [ ] 3.4 `config.core.php` (thin) and `src/templates/cockpit/config.php` (legacy): `forms.recaptchaSecret` from `RECAPTCHA_SECRET_KEY`; generated composes pass the variable to the CMS only
- [ ] 3.5 `core/cms`: `Submit` (with optional token/action), `UpdateSubmission`, `FormSettings`, `ErrRecaptcha`; Go tests with an `httptest` server
- [ ] 3.6 Prove it against a sandbox CMS: PATCH merges and does not notify; settings answer has no secret fields; low score and missing token answer 403; Google unreachable (blocked DNS in the container) accepts and logs
- [ ] 3.7 Forms README, `core/CORE_API.md`, CHANGELOG

## 4. Release

- [ ] 4.1 Versions 0.73.0 (section 1), 0.74.0 (section 2), 0.75.0 (section 3), each with its CHANGELOG and MIGRATIONS entry (legacy: Forms addon copy and `config.php` line in 0.75.0)
- [ ] 4.2 Green CI, tags `v0.75.0` and `core/v0.75.0`, release with assets, the usual post-release checks (`go get core@v0.75.0` from a clean cache, updater from 0.72.0, gosite-medusa image)

## 5. avanxo-dev pilot in a sandbox copy

- [ ] 5.1 Copy the site into a sandbox workspace; start the legacy build; capture every route of `internal/app/router.go` plus blog index, one article, a 404, `robots.txt`, `sitemap.xml`, `llms.txt`, with status and `Cache-Control`/`X-Robots-Tag`; record the Redis keys it writes
- [ ] 5.2 Scaffold thin with the same project, module, ports, domains, flavor, storage, database and gosite addons (Analytics, Blog, Forms, Replica, Webapp)
- [ ] 5.3 Move `cockpit/addons/{Casos,Home,Nosotros}` to `cockpit/site-addons/`; drop the copies of gosite addons; site parts of `cockpit/config.php` into `config.local.php` (including `webhookColor`), keeping `MONGO_DB` and the memory prefix
- [ ] 5.4 Move templates to `theme/` (layout, components, pages); replace copies of core partials with the slots; count `{{template}}` calls of the slots in the layout (exactly once each)
- [ ] 5.5 Move handlers and `internal/scan` to `site/` on the public API: `CachedRender` for cached pages, `Render` for fragments; `site.Funcs()` for the 11 functions; site config from the environment with the same defaults
- [ ] 5.6 Forms: contact and lead through core's client; delete `cms/submission.go` and `recaptcha.go`; stop on `cms.ErrRecaptcha`; home build reads `FormSettings("diagnostico").FieldOptions["necesidad"]`, falling back to `dx_options`
- [ ] 5.7 Redis: `scan:rate` and `scanlead` through `State()`; startup `RENAMENX` of `scanlead:*` with a test (TTL kept, existing new key not overwritten, old key left and logged)
- [ ] 5.8 `gosite.yml` `app_env:` for the site variables; site-only compose parts into `docker-compose.override.yml`; `gosite generate` leaves no diff
- [ ] 5.9 Checks: `go build`, `go vet`, `go test ./...`, `gositetest.CheckTheme`, `php -l` on `cockpit/`, `docker compose config -q` on all composes, body diff of every captured route, `<head>` asset list, screenshots of home and one solution page, cache canary purge, state keys survive a restart, CMS login and every addon screen, a form submission stored, Replica manifest, CMS PHP version
- [ ] 5.10 Check the open question of D8: a `formSettings` save purges the home page

## 6. avanxo-dev PR

- [ ] 6.1 Branch `chore/thin-core` from `development` in `~/gosites/avanxo-dev`; apply the sandbox result; AGENTS.md/ARCHITECTURE.md describe the thin layout
- [ ] 6.2 PR into `development` with the proof (text in `<details>`, screenshots attached) and the owner actions: Coolify compose and CMS build with `additional_contexts`, `COCKPIT_SEC_KEY`, `RECAPTCHA_SECRET_KEY` on the CMS, both `formSettings` entries (choices, score, actions), old cache key cleanup command, reverse rename for rollback

## 7. Documentation and follow-up

- [ ] 7.1 MIGRATIONS.md "legacy -> thin" from what the pilot needed; ship in the next gosite release
- [ ] 7.2 Open a follow-up issue in avanxo-website: remove `dx_options` from the Home model and the fallback once `formSettings` has the choices in production
- [ ] 7.3 Update issue #49 with the pilot result and the order for the next sites
