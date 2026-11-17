## Why

Every client site except three is still legacy: its Go core, addons, composes, Dockerfiles and `cockpit/config.php` are copies of `src/templates`, so each gosite release is a hand merge per site. The 0.53.0 -> 0.65.5 upgrade of avanxo-dev and lnequipos-v2 cost a file-by-file comparison against every tag, three composes merged by hand and a hand port of `CacheKeyPrefix()` (#47). Thin sites upgrade with `gosite upgrade` (0.72.0). This change defines how a legacy site becomes thin, proves it on avanxo-dev, and adds what core and the scaffold lack for that site. Brief: issue #49.

## What Changes

- **Thin sites can have their own Cockpit addons.** A site's addons live in `cockpit/site-addons/<Name>/`. When that folder exists, the generated `deploy/Dockerfile.cms` also copies it into the CMS image. `gosite generate` never writes in it, and refuses a site addon with the same name as a gosite addon. This reverses the core design decision "every addon lives in gosite, no `cockpit/site-addons/`".
- **Core gains two public API additions** (`core/CORE_API.md`, minor version):
  - `gosite.WithFuncs(template.FuncMap)`: the site's template functions. A name that core already defines makes `Run` fail at startup.
  - `(*cms.Client).Submit(ctx, cms.Submission)`: posts a submission to the Forms addon and returns the entry ID.
- **Everything a site does with forms goes through the Forms addon.** avanxo now writes `formSubmissions` through the generic content API, keeps a form's choices in its Home model, verifies reCAPTCHA in its own Go code, and has a local patch in the addon. The addon gains:
  - `PATCH /api/forms/submissions/{id}`: merges fields into a submission's data. It needs an API token with `forms/manage`, sanitizes like a submission, and never notifies. Core's client gains `UpdateSubmission`.
  - **Field options per form** in `formSettings` (`fieldOptions`, field name -> list of choices), read through `GET /api/forms/settings/{form}`. That endpoint returns only `label` and `fieldOptions`, never notification or secret fields. Core's client gains `FormSettings`.
  - **reCAPTCHA v3 verification on submit** for a form whose `formSettings` sets `recaptchaMinScore`. The secret comes from the CMS environment (`RECAPTCHA_SECRET_KEY`). A rejected token answers 403 with `"error": "recaptcha"`. `Submit` in core's client carries the token.
  - The Mattermost colour comes from `webhookColor` in `config.local.php`, which 0.68.1 already supports. avanxo's local patch goes away.
- **A documented legacy -> thin procedure** in MIGRATIONS.md. It is manual; there is no `gosite migrate` command yet.
- **Pilot: avanxo-dev migrated to thin** in one PR in `avanxo-website` against `development`:
  - The site code moves to `site/` on the public API.
  - The templates move to `theme/`.
  - Casos, Home and Nosotros move to `cockpit/site-addons/`.
  - The site-specific config moves to `config.local.php` and `gosite.yml` `app_env:`.
  - The unprefixed Redis keys `scanlead:*` are moved into `State()` at startup.
  - Visitors and editors see no change, apart from one fix: avanxo's current `POST /cache/purge` accepts any request in production when `COCKPIT_API_TOKEN` is empty, and core's purge answers 503 instead.
- Not in this change:
  - Migrating the other legacy sites. Each follows the procedure in its own PR.
  - lnequipos-v2's direct MongoDB reader (D3 of #49).
  - Deploys.
  - Changes to Cockpit data.

## Capabilities

### New Capabilities
- `legacy-to-thin-migration`: the procedure and the checks that prove a legacy site became thin with no visible change, and how live Redis state is carried over.

- `forms-site-api`: what a site can do with forms through the Forms addon: submit with reCAPTCHA, update a submission, read a form's public settings.

### Modified Capabilities
- `thin-scaffold`: generated files support site-owned Cockpit addons in `cockpit/site-addons/`.
- `app-extension-api`: sites register template functions through `WithFuncs`, and the CMS client can submit a form.

## Impact

- **gosite-cli.** Released before the avanxo PR as their own PRs:
  - `src/templates-thin/generated/deploy/Dockerfile.cms` and the generate code in `src/lib/thin.sh` (site addons).
  - `core/gosite.go` and `core/internal/views` (`WithFuncs`).
  - `core/cms` (`Submit`, `UpdateSubmission`, `FormSettings`).
  - `src/addons/Forms`: `api.php`, `Helper/Forms.php` (field options, reCAPTCHA, update) and README.
  - The generated composes and `config.core.php` (`RECAPTCHA_SECRET_KEY` reaches the CMS).
  - `core/CORE_API.md`, MIGRATIONS.md, README, `docs/index.html` (scaffold folder tree), and the `AGENTS.md`/`ARCHITECTURE.md` templates in the scaffold.
  - Tests in bats and Go.
- **avanxo-website:** the whole repository layout changes: `internal/` and `cmd/` are replaced by `main.go`, `site/` and `theme/`. Only the code moves; the content does not change. The composes become generated files.
- **Deploy (owner action, listed in the PR):**
  - Coolify reads the new composes, which use `additional_contexts` for the CMS image.
  - `COCKPIT_SEC_KEY` is required (0.70.0).
  - The site variables move to `app_env:`.
  - Old cache keys expire on their own or are deleted once with a SCAN.
  - `RECAPTCHA_SECRET_KEY` moves from the app to the CMS service.
  - The owner copies the diagnostico choices from Home into `formSettings`. This change does not modify Cockpit data, and until the copy is done the site falls back to Home's `dx_options`.
- **Risk:** the pilot is the largest legacy site, with about 9,000 lines of Go and 51 templates. The "no visible change" check is a body diff of every route before and after.
