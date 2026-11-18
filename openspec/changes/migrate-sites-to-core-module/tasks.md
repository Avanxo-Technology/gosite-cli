## 1. Site addons in thin sites (gosite-cli PR)

- [x] 1.1 `src/lib/thin.sh`: detect `cockpit/site-addons/*/`, refuse a name that is a gosite addon (no file written), and pass a flag to the Dockerfile.cms render
- [x] 1.2 `src/templates-thin/generated/deploy/Dockerfile.cms`: emit the `COPY cockpit/site-addons/ /var/www/html/addons/` line only when the flag is set
- [x] 1.3 `tests/thin.bats`: no folder (byte-identical Dockerfile), one site addon, a collision with `Forms`, `generate` leaves the folder untouched
- [x] 1.4 Prove it in a sandbox thin site: build the CMS image and check that the site addon is in it next to gosite's (`php -l` passes); running `install.php` needs Mongo and is left to the avanxo pilot (5.9)
- [x] 1.5 Docs: README, `docs/index.html` folder tree, AGENTS.md/ARCHITECTURE.md templates of the scaffold, `core/CORE_API.md` (Cockpit addons)

- [x] 1.6 Fix found on the way: `gosite generate` exited 0 when a check inside `thin_generate` failed (process substitution); it now exits non-zero

## 2. WithFuncs (gosite-cli PR)

- [x] 2.1 `core/gosite.go`: `WithFuncs(template.FuncMap)` option; `core/internal/views`: merge after core's functions; a name collision returns an error from `New`/`Run`
- [x] 2.2 Go tests: a theme uses a site function; a collision fails with the name; `gositetest.CheckTheme` accepts the extra functions
- [x] 2.3 `core/CORE_API.md` (Options table, Template functions)

## 3. Forms addon: update, field options, reCAPTCHA (gosite-cli PR)

- [x] 3.1 `Helper/Forms.php`: `updateData()` (sanitize, merge, no dispatch); `fieldOptions`, `recaptchaMinScore`, `recaptchaActions` in the `formSettings` model and in `migrateSettingsModel()`
- [x] 3.2 `Helper/Forms.php`: `verifyRecaptcha()` with the rules of D9 (5-second timeout, fail open on transport errors, log lines), called from `handleSubmission()` before the rate limit and from `updateData()` when a token is given
- [x] 3.3 `api.php`: `PATCH /forms/submissions/{id}` (`forms/manage`, 404 for an unknown ID) and `GET /forms/settings/{form}` (only `label` and `fieldOptions`)
- [x] 3.4 `config.core.php` (thin) and `src/templates/cockpit/config.php` (legacy): `forms.recaptchaSecret` from `RECAPTCHA_SECRET_KEY`; generated composes pass the variable to the CMS only
- [x] 3.5 `core/cms`: `Submit` (with optional token/action), `UpdateSubmission`, `FormSettings`, `ErrRecaptcha`; Go tests with an `httptest` server
- [x] 3.6 Prove it against a sandbox CMS: PATCH merges and does not notify; settings answer has no secret fields; low score and missing token answer 403; Google unreachable (blocked DNS in the container) accepts and logs
- [x] 3.7 Forms README, `core/CORE_API.md`, CHANGELOG

- [x] 3.8 Fix found on the way: submit now returns the entry `_id`; before, avanxo's lead ID was always empty (no `scanlead` link, a second submission instead of an update)

## 4. Release

- [x] 4.1 Versions 0.73.0 (section 1), 0.74.0 (section 2), 0.75.0 (section 3), each with its CHANGELOG and MIGRATIONS entry (legacy: Forms addon copy and `config.php` line in 0.75.0)
- [x] 4.2 Green CI, tags `v0.75.0` and `core/v0.75.0`, release with assets, the usual post-release checks (`go get core@v0.75.0` from a clean cache, updater from 0.72.0, gosite-medusa image)

## 5. avanxo-dev pilot in a sandbox copy

- [x] 5.1 Copy the site into a sandbox workspace; start the legacy build; capture every route of `internal/app/router.go` plus blog index, one article, a 404, `robots.txt`, `sitemap.xml`, `llms.txt`, with status and `Cache-Control`/`X-Robots-Tag`; record the Redis keys it writes
- [x] 5.2 Scaffold thin with the same project, module, ports, domains, flavor, storage, database and gosite addons (Analytics, Blog, Forms, Replica, Webapp)
- [x] 5.3 Move `cockpit/addons/{Casos,Home,Nosotros}` to `cockpit/site-addons/`; drop the copies of gosite addons; site parts of `cockpit/config.php` into `config.local.php` (including `webhookColor`), keeping `MONGO_DB` and the memory prefix
- [x] 5.4 Move templates to `theme/` (layout, components, pages); replace copies of core partials with the slots; count `{{template}}` calls of the slots in the layout (exactly once each)
- [x] 5.5 Move handlers and `internal/scan` to `site/` on the public API: `CachedRender` for cached pages, `Render` for fragments; `site.Funcs()` for the 11 functions; site config from the environment with the same defaults
- [x] 5.6 Forms: contact and lead through core's client; delete `cms/submission.go`; `recaptcha.go` only reads the token; stop on `cms.ErrRecaptcha`. `dx_options` stays page content (owner decision 2026-11-17: the 9 pages have different lists)
- [x] 5.7 Redis: `scan:rate` and `scanlead` through `State()`. No `RENAMENX`: the legacy `scanlead:*` keys were never written (the addon returned no submission ID before 0.75.0), confirmed in the code and in local Redis
- [x] 5.8 `gosite.yml` `app_env:` for the site variables; site-only compose parts into `docker-compose.override.yml`; `gosite generate` leaves no diff
- [x] 5.9 Checks: `go build`, `go vet`, `go test ./...`, `gositetest.CheckTheme`, `php -l` on `cockpit/`, `docker compose config -q` on all composes, body diff of every captured route, `<head>` asset list, screenshots of home and one solution page, cache canary purge, state keys survive a restart, CMS login and every addon screen, a form submission stored, Replica manifest, CMS PHP version
- [x] 5.10 Open question of D8: no longer applies (the choices stay on the pages)

## 6. avanxo-dev PR

- [x] 6.1 Branch `chore/thin-core` from `development` in `~/gosites/avanxo-dev`; apply the sandbox result; AGENTS.md/ARCHITECTURE.md describe the thin layout
- [x] 6.2 PR into `development` with the proof (text in `<details>`, screenshots attached) and the owner actions: Coolify compose and CMS build with `additional_contexts`, `COCKPIT_SEC_KEY`, `RECAPTCHA_SECRET_KEY` on the CMS, both `formSettings` entries (choices, score, actions), old cache key cleanup command, reverse rename for rollback

- [x] 6.3 Found on the way and released as 0.75.1/0.75.2 (#67): thin QA never passed `HTTP_BASIC_CREDENTIALS` to the app; `SITE_URL` missing in QA/prod; `generate` scanned the whole site for placeholders and wrote half the files before failing; `gosite.yml` 0600 unreadable in a locally built app image
- [x] 6.4 Tailwind: the blog pages stay in the theme (identical to core's) so `styles.css` keeps their utilities

## 7. Documentation and follow-up

- [x] 7.1 MIGRATIONS.md "legacy -> thin" from what the pilot needed; ship in the next gosite release
- [x] 7.2 No follow-up needed: `dx_options` stays (see 5.6)
- [ ] 7.3 Update issue #49 with the pilot result and the order for the next sites
