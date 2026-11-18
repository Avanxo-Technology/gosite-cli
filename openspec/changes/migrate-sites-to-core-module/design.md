## Context

Brief: issue #49. Legacy sites carry copies of `src/templates`; thin sites import `github.com/Avanxo-Technology/gosite-cli/core` and upgrade with `gosite upgrade`. The core design (archive `2026-09-18-extract-core-module`) made site migration a non-goal and decided "every addon lives in gosite, no `cockpit/site-addons/`".

The pilot is avanxo-dev (legacy, 0.65.5; repository `avanxo-website`). Inventory, 2026-11-17:

| Area | What avanxo has | Where it goes |
| --- | --- | --- |
| Template copies | `internal/{app,cache,cms,config,seo,blog,views,analytics}`, handlers `purge`, `robots`, `sitemap`, `llms`, `favicon`, `health` (some with local edits for `CacheKeyPrefix`) | Dropped; core provides them |
| Site Go code | 15 files, about 5,000 lines: handlers for the solution pages, `casos`, `nosotros`, `planes-*`, `desarrollo-web`, `home`; the `diagnostico-empresarial` scan flow (submit, poll, lead, screenshot proxy, game, results, assistant, guard); `contact`; `recaptcha`; `internal/scan` client; `cms/submission.go` | `site/` on the public API, except reCAPTCHA (addon) and `submission.go` (core client) |
| Templates | `internal/views/layout.html`, 30 components, 15 pages | `theme/` |
| Template functions core lacks | `add`, `assetH`, `assetW`, `dict`, `div`, `iif`, `list`, `mod`, `safeCSS`, `seq`, `year` | `site/` through `WithFuncs` |
| Own Cockpit addons | `Casos`, `Home`, `Nosotros`: model install and migration on admin load and through `install.php`; no admin screen, no API | `cockpit/site-addons/` |
| Forms | the contact form (`diagnostico`) and the scan lead (`diagnostico-empresarial-lead`) post to the addon; the lead is then changed by writing `formSubmissions` through the content API; the contact form's choices are `dx_options` in the `home` singleton; reCAPTCHA v3 (`scan`, `lead`) is checked in Go; local patch of the Mattermost footer and colour in `Helper/Forms.php` | Forms addon (see D7–D9) |
| Redis outside the cache | `scan:rate:<ip>` (INCR, 1 h) and `scanlead:<scanID>` (lead ID, 7 days), with no project prefix | `State()` (D4) |
| Environment the site reads | `WHATSAPP_NUMBER`, `SCAN_API_URL`, `SCAN_API_KEY`, `SCAN_RATE_LIMIT`, `SCAN_ASSETS_HOST`, `SCAN_ASSETS_DIAL`, `SCAN_REF_SECRET`, `RECAPTCHA_SITE_KEY`, `RECAPTCHA_MIN_SCORE`, `RECAPTCHA_SECRET_KEY` | `app_env:` in `gosite.yml`. Exceptions: the secret goes to the CMS, and the minimum score becomes `recaptchaMinScore` in `formSettings` (D9) |
| CMS image | FrankenPHP build, PHP 8.4.27 | The thin template image. `cockpithq/cockpit:core-2.14.1` ships PHP 8.4.27 since 2026-10-22, as the aldu 0.72.0 upgrade check showed (D2) |

Core already provides what the remaining legacy code does: the basic-auth gate with `X-Robots-Tag` for QA, HEAD on every GET, gzip, asset cache headers, the `/storage/uploads` proxy, blog, SEO, sitemap, robots, `llms.txt`, favicon, health, and purge. Purge compares the token in constant time and answers 503 without one, where avanxo's current purge accepts any request in production when `COCKPIT_API_TOKEN` is empty.

## Goals / Non-Goals

**Goals:**
- avanxo-dev becomes a thin site with no change that visitors or editors see, apart from the purge fix.
- A thin site can keep its own model addons.
- Every form operation of a site goes through the Forms addon.
- A written procedure that the next legacy sites follow.

**Non-Goals:**
- Other legacy sites. Each gets its own PR later.
- lnequipos-v2's direct MongoDB reader (D3 of #49).
- A `gosite migrate` command (D6).
- Redesigns, new pages, and Cockpit data changes.
- Deploys.

## Decisions

### D1. Site addons in `cockpit/site-addons/`
Owner decision. `generate` emits `COPY cockpit/site-addons/ /var/www/html/addons/` in `deploy/Dockerfile.cms` only when that folder has at least one directory, because Docker fails a `COPY` of a missing path. `generate` refuses a site addon whose name is a gosite addon, because the later `COPY` would replace gosite's code without anyone noticing. `modules.disabled` keeps listing only gosite addons.
- *Alternative: rewrite the three addons as generic model files read by a gosite addon.* It fits the old design, but it is more upstream work and a rewrite of working code.
- *Alternative: drop the addons.* The models stay in Mongo, but a new environment would not get them and a field change would no longer apply itself.

### D2. CMS image
Keep the thin template image (`cockpithq/cockpit:core-2.14.1`, PHP 8.4.27). The migration check confirms the PHP version in the built image.

### D4. Redis state
`scanlead:<id>` moves to `State()`, which stores it as `<project>:app:scanlead:<id>`. At startup `site/` runs SCAN `scanlead:*`, then `RENAMENX` each key to the new name, so the TTL is kept. The SCAN uses a COUNT and a 10-second limit, and logs how many keys it moved and how many it skipped. The old prefix is a single constant, so the reverse command is one loop.

`scan:rate:<ip>` moves to `State()` with no copy, because it is a 1-hour counter. Losing it only resets the limit once, at deploy time.

QA must not use Redis database 1, which holds Cockpit's memory.

The old cache keys are not carried over: the new build writes `<project>:<env>:cache:`. The PR gives the one-time SCAN/DEL for the old names (`avanxo-dev:*_html`, `avanxo-dev:seo:*`, `avanxo-dev:blog:*` and their `:stale`). That command excludes `<project>:app:` and database 1.

### D5. Core gaps closed upstream
- **`gosite.WithFuncs(template.FuncMap)`.** Merged after core's functions. A collision fails `Run`, so a site can never silently replace `safeHTML` or `assetURL`.
  - *Alternative: add avanxo's helpers to core.* Every site would get `dict` and `seq`, which is fine, but `year`, `assetW` and `assetH` are taste, and the next site would need yet another release.
- **CMS client:** `Submit`, `UpdateSubmission` and `FormSettings` (D7–D9).

### D6. Manual procedure first
The pilot writes MIGRATIONS.md "legacy -> thin" while it runs. A command comes after the second site shows which steps repeat.

### D7. Updating a submission goes through the addon
New `PATCH /api/forms/submissions/{id}` in `api.php`, next to the existing `DELETE`. It checks `forms/manage`. `Helper/Forms.php` gets `updateData($id, $fields, $recaptcha = null)`:
- It reads the entry and runs `sanitize()` on the fields, with the same limits as a new submission.
- It merges the fields into `data` and saves.
- It never calls `dispatch()`.

The core client sends `{"data": {...}, "recaptcha": {"token", "action"}}`, with the reCAPTCHA part optional. `cms/submission.go` in avanxo goes away.
- *Alternative: keep the content API.* It works, but it skips sanitizing and `forms/manage`, and every site would grow its own copy.

### D8. Field options in `formSettings`
New `fieldOptions` field of type `object` in `formSettings`: field name -> list of strings. `migrateSettingsModel()` adds it to an existing model.

New `GET /api/forms/settings/{form}` returns `{label, fieldOptions}` and nothing else, because the entry also holds webhook URLs and secrets. The site needs a token with read access to forms. The existing purge flow covers a choice change: saving `formSettings` is a content save, and the Webapp addon purges the site on content saves. The pilot checks this. If it does not hold, the Forms addon calls the purge itself.

avanxo reads `FormSettings(ctx, "diagnostico").FieldOptions["necesidad"]` in the home build. While that is empty it uses `dx_options` from `home`, so the page does not change before the owner copies the value. The field stays in the Home model until a later PR removes it and the fallback together (tracked in tasks).
- *Alternative: copy the value in a startup migration.* That writes Cockpit data, which the brief forbids.

### D9. reCAPTCHA in the addon
`formSettings` gains `recaptchaMinScore` (number) and `recaptchaActions` (tags). The secret is `RECAPTCHA_SECRET_KEY` in the CMS environment, read through `config.core.php` (`forms.recaptchaSecret`). It never lives in a Cockpit entry.

Verification runs in `handleSubmission()` before the rate limit counts the request, and in `updateData()` when a token is passed. The rules copy avanxo's current behaviour:
- A missing or rejected token is answered with 403 and `{"error": "recaptcha"}`.
- When Google is unreachable or answers with something unreadable, the request is accepted and logged.
- The timeout is 5 seconds.

For avanxo, `diagnostico-empresarial-lead` gets `recaptchaActions: [scan, lead]`. The scan submit creates the lead before it starts the scan, so the addon's check also guards the scan start. When `Submit` returns `cms.ErrRecaptcha`, the site stops and shows the same message as today. Any other `Submit` error keeps today's behaviour: it is logged and the scan goes on.

Order change: today reCAPTCHA is checked before domain validation and the per-IP scan limit, and after the migration it is checked after both, when the lead is created.
- **Effect:** an unverified request can now cause one DNS lookup and one increment of its own IP's counter.
- **Option to keep today's order:** create the lead first. But then a lead is stored for a domain that fails validation, which changes the data editors see. Accepted as is; the PR says so.

The site key (`RECAPTCHA_SITE_KEY`) and the template script stay in `site/` and `theme/`, because the browser needs them.

### D10. Mattermost wording
avanxo's `config.local.php` sets `'forms' => ['webhookColor' => '#F26A2E']`. The footer then shows the date only, as the local patch does now. Setting `webhookSiteName` would change the message, so it stays unset.

### D11. Code layout in the thin avanxo
- `main.go`: `gosite.Run(site.New(), gosite.WithTheme(theme()), gosite.WithFuncs(site.Funcs()))`.
- `site/`: `Site` with `Routes`, `TemplateData` (WhatsApp, reCAPTCHA site key), `Middleware` (none expected) and `OnPurge` (none: core purges every page). Handlers keep their names and their logic.
- **Cached pages** use `CachedRender`, which keys them by URL instead of `home_html` and the like. Purge clears them all, as today.
- **Uncached pages:** the htmx fragments, the scan poll and the screenshot proxy use `Render` or write their response directly, as today.
- `site/config.go` reads the site's own variables with the same defaults.
- `site/scan/`: the scan client, moved as is.

## Risks / Trade-offs

- **The body diff misses a change that is only visible in the browser** (JavaScript, CSS order) → the pilot also compares the `<head>` asset list and takes screenshots of the home page and one solution page in both builds.
- **`CachedRender` keys by URL, so a query string now creates its own cache entry.** Since 0.71.0 core normalizes the query and drops tracking parameters, and the stale copy only exists for URLs with no query. Accepted.
- **Coolify must build the CMS with `additional_contexts`.** Pirotecnia and aldu already deploy this way; the PR names it as a check.
- **The deploy is one step for app and CMS.** A CMS without the new Forms version answers the `PATCH` with 404 and the settings call with 404. To avoid a mixed state, the site treats a 404 from `FormSettings` as empty (fallback, D8), and logs a 404 from `UpdateSubmission` without failing the visitor's request, as today's update errors are.
- **Rollback** is a revert of the merge and a redeploy. The `scanlead` keys need the reverse rename, and the PR gives it.

## Migration Plan

1. gosite-cli PRs into `main`, in this order. Each has tests and docs.
   1. Site addons (D1).
   2. `WithFuncs` (D5).
   3. Forms: update, field options and reCAPTCHA (D7–D9), with the core client and `RECAPTCHA_SECRET_KEY` in the composes.
2. Versions 0.73.0, 0.74.0 and 0.75.0, one per PR (owner decision, 2026-11-17); only 0.75.0 is tagged and released. Minor versions, because each adds to the public API or the scaffold.
3. avanxo, in a sandbox copy (`GOSITE_HOME` and `GOSITE_WORKSPACE` redirected):
   1. Capture every route and header from the legacy build.
   2. Scaffold thin with the same project, module, ports, domains, flavor, storage, database and addons.
   3. Move the code, the theme, the site addons and the config.
   4. Run the checks of the `legacy-to-thin-migration` spec.
4. Branch `chore/thin-core` in `~/gosites/avanxo-dev` from `development`, and open a PR into `development` with the proof and the owner actions:
   - Coolify compose and CMS build.
   - `COCKPIT_SEC_KEY`.
   - `RECAPTCHA_SECRET_KEY` to the CMS.
   - The `formSettings` entries for both forms: choices, reCAPTCHA score and actions.
   - Cleanup of the old cache keys.
5. MIGRATIONS.md "legacy -> thin", written from what step 3 needed, ships in the next gosite release.

## Open Questions

- Does a save of `formSettings` purge the site's pages today? Checked in the pilot (D8).
- The `diagnostico` contact form does not use reCAPTCHA today. It stays that way unless the owner sets `recaptchaMinScore` for it.

## Pilot outcome (2026-11-17)

avanxo-website#43 (into `development`) on gosite 0.75.2. Changes to the decisions above, by the owner or forced by facts found during the pilot:

- **D4:** no `RENAMENX`. The legacy `scanlead:*` keys were never written: the Forms addon returned no submission ID before 0.75.0, so the link was always skipped. `State` also cannot read unprefixed keys. `scan:rate` moves with no copy, as planned.
- **D8:** `dx_options` stays page content. The `diagnostico` form shows a different list on each of 9 pages (home and desarrollo-web in their models, 7 in Go), and `fieldOptions` holds one list per form. `fieldOptions` and its endpoint stay in the addon for single-list forms; avanxo does not use them, so there is no owner data step and no fallback.
- **Sitemap:** core builds the sitemap from `seoPages` only. avanxo's two pages that were added in code (`/planes-digitales`, `/diagnostico-empresarial`) get `seoPages` entries (owner action) instead of a core hook.
- **Template data:** the theme keeps its flat map through a site function `flat`, and `pageKeys` makes core's startup probe pass. No core change.
- **Versions:** 0.73.0, 0.74.0, 0.75.0 (released together), then 0.75.1 and 0.75.2 (released together). These are the four thin template fixes listed in tasks 6.3.
- **Result:** 21 of 22 captured routes render the same body and head as the legacy build. `sitemap.xml` loses the two pages above until their entries exist.

