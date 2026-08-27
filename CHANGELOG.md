# Changelog

## 0.45.4 — the website caught up

### Changed

- **`docs/index.html` and `README.md` now describe what gosite actually does.**
  The site still said every project shipped *four* built-in addons (it is six),
  had no card for `CachePurge` or `StarterContent`, and — the one that cost
  real debugging time — claimed addons were "bind-mounted in dev, baked into
  the production image". They are baked into the image in **both**, which is
  why adding one needs a rebuild rather than a restart. That is now stated
  where somebody looking for it would read it.

  Also documented: `gosite addons`, `gosite sync --app`, the `router_blog.go` /
  `internal/blog/` files an opt-in addon adds, and that `gosite start` registers
  the API key but no longer creates content models.

## 0.45.3 — a new project brings its own home singleton

### Fixed

- **A fresh project could answer 502 on its front page.** The application reads
  a `home` singleton, and when the CMS has none it returned
  `502 could not load the page` — even though the templates carry fallback text
  written for exactly that case.

  Two separate problems, both fixed:

  **The singleton was created from the CLI, over HTTP, after boot.** `gosite
  start` waited up to 90s for the REST API, registered an API key and POSTed to
  `/api/models/save` with retries. That depends on the CMS being up, on a token
  existing and on timing — and when any of those was untrue it failed silently.
  Combined with 0.45.1's missing `.env` (no token), it failed silently a lot.

  A new built-in `StarterContent` addon creates the model from inside Cockpit
  instead: no network, no token, idempotent, and it cannot half-succeed. It is
  the approach Forms and Blog already use for their own models, and it rebuilds
  the model registry cache so the model is visible on non-debug environments. A
  `home` model that already exists is never touched, fields included. `gosite
  start` still registers the API key; it no longer creates models.

  **A missing model was treated like a broken CMS.** The client now reports
  `ErrNotFound` separately, so "nobody has created this yet" renders the
  template's fallbacks with a 200, while an unreachable or failing CMS is still
  a 502. The fallback page is deliberately not cached, so real content appears
  the moment somebody writes it rather than a TTL later. An existing but empty
  singleton is treated the same way.

### Upgrading

New projects need nothing. For an existing project:

```bash
gosite sync <project>          # installs the StarterContent addon
gosite sync <project> --app    # the 502-instead-of-fallbacks fix
gosite restart <project> --build
```

## 0.45.2 — a newly installed addon now actually appears in Cockpit

### Fixed

- **An addon installed into an existing project stayed invisible in the CMS
  panel**, with its files sitting correctly inside the container the whole time.

  Cockpit records which addons exist in `storage/cache/modules.cache.php` and
  rebuilds that list only when its own version or env directory changes —
  never when an addon appears. gosite knew this and cleared the cache on
  install, but at the wrong moment, and the timing made things worse rather
  than better:

  1. `addons add` copies the addon to the host and clears the cache
  2. the CMS is still running the **old image**, which has no such addon, and
     regenerates the cache from it — a stale list, written right then
  3. `--build` finally puts the addon in the image
  4. the container comes up, finds a cache that is still "valid" by Cockpit's
     rule, and reuses it — never seeing the addon

  Clearing before the rebuild does not just fail to help; it guarantees a stale
  list gets written and then survives. The clear now happens as the container
  comes up (`gosite start` and `gosite restart`), which is the only point where
  the image and the cache are guaranteed to agree. Cockpit rebuilds the list on
  the first request.

  This was not new with the blog — Forms and Replica had the same exposure
  whenever they were added to a project after creation.

### Upgrading

For a project whose addon is not showing:

```bash
gosite restart <project>
```

## 0.45.1 — the .env template was never shipped

### Fixed

- **`gosite create` did not write `.env`, and `gosite sync` failed outright**
  with `cp: .../src/templates/.env: No such file or directory`.

  `src/templates/.gitignore` is a template — it is copied into generated
  projects so their `.env` stays out of git. But it sits inside the template
  directory, so **git applied it to gosite's own repository too**, silently
  ignoring `src/templates/.env`. The file existed on the machine it was written
  on and nowhere else: never committed, absent from every release tarball,
  missing from every installed copy.

  Three symptoms, one cause. Without `.env` a new project also had no
  `COCKPIT_API_TOKEN`, so `gosite start` skipped seeding the Cockpit API key
  and the application authenticated with an empty key — which is why a key
  created by hand in the CMS appeared not to work.

  The template is now stored as `dotenv` and written as `.env` on copy, the
  same mapping `gosite.env` → `.gosite.env` already used, so no gitignore
  pattern can match it again. The rendered fixture now asserts that `.env`
  reaches the project, which turns a recurrence into a failing test.

- **The cache-purge button rendered in production.** `home.html` included it
  unconditionally; `IsDev` was passed to the template and never read. The
  button posts without a token, which the purge endpoint accepts only in
  development, so in production it showed every visitor a control that answers
  401. It is now behind `{{if .IsDev}}`, with a test asserting both directions.

### Changed

- **`.env.example` now defaults to `APP_ENV=development`.** It is a local
  development starting point and nothing else: the production compose sets
  `APP_ENV` itself and declares no `env_file`, and `.env` is gitignored, so
  neither file ever reaches a server.

### Upgrading

This affects every project, not only ones using the blog: no `gosite sync`
worked without it. Update gosite, then per project:

```bash
gosite sync <project> --env    # creates .env when missing, adds missing keys
gosite start <project>         # seeds the Cockpit API key from it
```

## 0.45.0 — a blog every site shares

### Added

- **New `Blog` addon**, opt-in like `Forms` and `Replica`, but the first one
  that installs an application half as well as a CMS half.

  **In the CMS.** Four models created on first admin load: `blogs`,
  `blogPosts`, `blogCategories`, `blogAuthors`, grouped under *Blog*. Several
  blogs per site are **data, not schema** — a blog is an entry in `blogs` and an
  article references it, so every project runs the same models and a fix here
  is a fix everywhere. Names are prefixed on purpose: `categories` is a name a
  client will want for their own content, and because installation skips a
  model that already exists the collision would have been silent.

  Slugs are derived from the title, transliterated (`Diseño Gráfico` →
  `diseno-grafico`) and unique **within their blog**, so `/noticias/novedades`
  and `/casos/novedades` can both exist. Cockpit's own `meta.unique` cannot
  express that — it runs an `$or` across the whole collection — so the scoped
  check lives in the addon. A blog slug that collides with a path the scaffold
  serves (`static`, `healthz`, `api`, …) is refused at save time.

  The byline is the article's author reference, falling back to the
  `blogAuthors` entry linked to the Cockpit account that created it. Writing
  your own blog needs no author picked; publishing for a client still lets you
  choose. Only display fields ever leave the addon — never an account's e-mail.

  An admin screen at `/blog` shows what Cockpit's generic editor cannot: each
  article's real address on the public site, plus a manual cache purge.

  **In the application.** Pages at `/{blog}` and `/{blog}/{slug}`, paginated,
  with canonical URLs and Open Graph tags, in both template flavors. Drafts are
  unreachable by construction: Cockpit's read API overwrites `filter._state`
  and never serves an unpublished entry, so nothing here has to filter them.

- **New `gosite addons` command.** Installing an addon into a project that
  already exists was possible before (`gosite sync --addons`), but only if you
  knew `sync` had a flag for it. It is now a command of its own:

  ```bash
  gosite addons list [project]        # the library, and what the project has
  gosite addons add Blog [project]    # install
  gosite addons remove Blog [project] # uninstall
  ```

  Addon names are matched against gosite's library, so the project can be given
  in any position. The implementation is the same one `sync --addons` uses -
  the command is a front door, not a second code path. Removal deletes the
  addon's files, including its application half, and deliberately leaves the
  content it created in the database: dropping models and entries is a data
  decision, not an install one.

- **New `gosite sync --app`.** Every other sync mode promises never to touch
  your Go code, and that promise is worth keeping by default. But gosite's own
  scaffolding lives in `internal/` too — the cache, the CMS client, the
  renderer, the router seam — so a project scaffolded a year ago could not
  install an addon that calls into scaffolding it does not have.

  `--app` brings `internal/` up to the current templates behind the same
  manifest guard as everything else: a file byte-identical to what gosite wrote
  is refreshed, a file you edited is preserved and reported. Handler code you
  wrote survives; plumbing you never opened catches up. Files an addon
  installed are not touched here — refresh those with `gosite addons add`.

- **`gosite addons add` refuses an install that would break the build.** An
  addon's pages call into the project's own Go code, which gosite never
  rewrites. Installing into a project without those seams used to succeed and
  leave a project that did not compile. It now checks first and names every
  file and the exact thing missing from it, installing nothing. Requirements
  are declared by the addon (`REQUIRES`), not hard-coded in the CLI.

### Changed

- **The CMS client can read collections.** `internal/cms` gained `Items` and
  `First` with filter, sort, pagination, projection and populate. Both of
  Cockpit's response shapes decode to one result type — it returns a bare array
  normally but `{data, meta}` when `skip` and `limit` are both present, and
  reading that wrapper as a list yields entries with no `_id`. Reads always
  send both parameters, which makes the shape deterministic and is also the
  only way to get `meta.total`.
- **Cache invalidation can address a group of keys.** A blog is many keys where
  the home page was one, and publishing an article changes its blog's index as
  well as its own page. `CachePurge` now tells the app *what* changed, so the
  app drops that blog and leaves other blogs and the home page cached. The body
  is additive — an older app ignores it and behaves exactly as before — and the
  endpoint's fail-closed authentication from 0.43.0 is unchanged.
- **Page templates register themselves.** Every file under
  `internal/views/pages/` becomes a page named after the file; adding a page no
  longer means editing `render.go`.
- **Optional features mount from their own file.** `router.go` declares a
  `mountFeatures` seam and calls it in plain sight; an addon appends to it from
  a file of its own. Installing a feature into an existing project therefore
  adds files and never rewrites `router.go`, which projects edit by hand and
  `sync` deliberately preserves.

### Fixed

- `gosite sync --list-addons` was documented in the command's help but never
  wired into its argument parser, so it was treated as a project name and
  failed with "Unknown project '--list-addons'".

### Upgrading

Existing projects need their application sources brought up to date first,
because the blog's pages call into scaffolding older scaffolds do not have:

```bash
gosite sync <project> --app       # refreshes internal/, preserves what you edited
gosite addons add Blog <project>  # refuses with a precise list if anything is still missing
gosite restart <project> --build  # both halves are compiled/baked in
``` It only adds files —
a blog page you have edited is preserved and reported, `--force` takes the
template version. Because the addon changes both halves, **rebuild the CMS
image and the application**; restarting is not enough.

## 0.44.0 — replicated models become visible on the destination

### Fixed

- **Replica wrote models that nobody could see.** `applyModels()` stored
  incoming model definitions correctly in the destination database, but
  `Content\Helper\Model` caches every definition under the `content.models`
  memory key and only bypasses that cache when debug is on. On any non-debug
  destination the registry kept describing the world as it was: the REST API
  answered `Model <name> not found` and a consuming app read the singleton as
  empty, while the definition sat correct in the database the whole time.

  `applyModels()` now rebuilds the registry after a successful write. The
  rebuild is best-effort — the data is already stored and the next request
  rebuilds it anyway — so a failure is reported in the run's messages instead
  of failing the replication.

  This affected every gosite project replicating a new model to a non-debug
  target, and stayed hidden for so long precisely because development runs with
  debug on, which rebuilds the registry on every request and masks it
  completely.

  The behaviour is documented in `src/knowledge/cockpit-model-registry-cache.md`
  for every code path that writes model definitions outside the admin UI.

  Replica is baked into the CMS image (`Dockerfile.cms COPY`), so projects need
  a **CMS rebuild**, not a restart.

## 0.43.1 — the Forms config block actually applies

### Fixed

- **The entire `forms` block of `cockpit/config.php` was inert.** The addon
  read its five settings through `config/forms/...`, but `bootstrap.php` builds
  the app with `new Lime\App($config)`, so the config file's top-level keys sit
  at the ROOT of the registry — `forms/...`. All five lookups returned `null`
  and silently fell back to the built-in defaults: `trustedProxies` (every
  submission stored the proxy's IP instead of the visitor's),
  `personal_data_retention` (the 90-day ip/userAgent clearing never applied),
  `collect_personal_data` (collection could not be turned off),
  `allowed_origins` (the public receiver's CORS ignored the list) and the
  deprecated `trustProxy` alias. Reads now go through a `config()` helper that
  tries the root key first and keeps the nested path as a fallback.

  Two notes for existing installations: the addon is baked into the CMS image
  (`Dockerfile.cms COPY`), so this needs a **CMS rebuild** — restarting is not
  enough. And because the retention sweep never ran, existing projects may hold
  IPs and user agents older than their configured window; the first time the
  Forms screen is opened after the rebuild, the daily sweep runs and purges
  them.

## 0.43.0 — templates as real files, submission storage, quality gates

### Note before upgrading (data-affecting)

- **Forms submissions now have a personal-data retention policy.** The `ip`
  and `userAgent` fields of stored submissions are cleared 90 days after
  submission (everything else in the submission is preserved). The window and
  the collection itself are configurable in `cockpit/config.php`:
  `personal_data_retention` (seconds, `0` = keep indefinitely — flagged by
  `gosite doctor`) and `collect_personal_data` (`false` = never store them;
  the rate limit is unaffected, it reads the client address at request time).
  The clearing runs automatically at most once a day when the Forms screen is
  opened. Projects that need the old behaviour must set
  `'personal_data_retention' => 0` before upgrading the addon.

### Changed

- Every generated project file (Go application, views, compose files,
  Dockerfiles, `.env`, docs) is now a real file under `src/templates/` with
  its true extension, rendered by literal `__PLACEHOLDER__` substitution —
  no shell interpretation of template content, ever. `create` and `sync`
  render from the same source and produce byte-identical output; a render
  that leaves a token unresolved fails loudly, naming file and token.
  The template tree is verified in CI (`gofmt`, `go vet`, YAML parse,
  `php -l`) without creating a project.
- Forms admin screen: submission counts now come from a single
  database-side aggregation (exact, regardless of collection size; the old
  count was computed in PHP and capped at 10 000 documents), and forms
  configured but never submitted appear with a count of zero. Column
  derivation inspects a bounded sample (200 newest submissions), stated in
  the interface.
- `gosite update` verifies the downloaded release against the published
  checksum, stages the new tree, backs up the previous installation and
  rolls it back if the new binary does not run. `GOSITE_REPO` from the
  environment is ignored (reported); `--repo <owner>/<name>` is the explicit
  override. Branch installs require `--allow-unverified`.
- New quality gates: shellcheck (severity `warning`) over `src/**`, a
  Docker-free bats suite covering the registry, port allocation, locking and
  project resolution (including the Phase 2 concurrency cases), a template
  fixture job, and an end-to-end smoke job (`create → build → start →
  healthz`) with guaranteed cleanup. The pre-commit hook runs the fast lint
  subset (~0.5 s).

## 0.42.0 — state integrity and a safe update path for existing projects

### Added

- `gosite sync --report`: per-file drift report between a project and the
  current templates — identical / modified / missing, plus a structural
  (`yq`) comparison of the production compose that classifies keys the
  template would add, values that differ, and project-only keys. Read-only;
  `--strict` makes it exit non-zero on drift so it can gate a pipeline.
- Per-project manifest (`.gosite/manifest.tsv`): every file gosite writes is
  recorded with its hash at write time. Sync refreshes files that still
  match, preserves and reports hand-edited ones (unless `--force`), restores
  deleted ones, and never adopts local edits into the manifest. Projects
  from before the manifest adopt one from their current contents on the
  first sync — that pass writes nothing but the manifest and shows the drift
  report instead.
- State handling hardened: all registry/port writes go through a portable
  `mkdir`-based lock (bounded wait, orphan reclamation, trap-driven
  release) and atomic `mktemp`+`mv` publication. Port selection and
  reservation are one indivisible critical section, so concurrent creates
  can never pick the same port; failed creates release their reservation.
  Reading the registry never rewrites it — vanished projects are reported as
  `unavailable` and pruned only by `gosite list --prune`.
- `gosite doctor` now audits every registered project and the shared
  infrastructure against the secure defaults (missing Forms proxy trust,
  empty purge token, wildcard CORS, datastores published beyond loopback,
  unlimited personal-data retention), read-only, with the exact remediation
  command per finding. `--strict` exits non-zero when there are findings.

### Changed

- **`docker-compose.prod.yml` is now read-only for gosite.** No sync mode
  writes it; drift is reported and the human decides. The only write path is
  the explicit `gosite sync --compose-prod --force`, which first copies the
  current file to a timestamped `.bak` beside it.

## 0.41.0 — security hardening of the fail-open paths

### BREAKING

- **`POST /cache/purge` is no longer public.** Without
  `COCKPIT_API_TOKEN` set (outside development) the endpoint answers
  **503** instead of purging; with a wrong token it answers 401. A deployed
  site that relied on the unauthenticated purge will stop purging until the
  variable is set — that is the point: the endpoint was silently open on
  every deployment that lacked the variable. Set `COCKPIT_API_TOKEN` in the
  environment (the `.env` template ships the key) and redeploy; the
  comparison is constant-time. `gosite doctor` detects the empty-token
  condition and names the variable.
- **MongoDB, Redis and MinIO now bind to 127.0.0.1 only.** The shared
  infrastructure's datastores are unauthenticated; binding them to all
  interfaces made them reachable from the network. Host tools that connect
  through `localhost` keep working unchanged. If something on your LAN
  genuinely needs them, set `GOSITE_BIND_ADDRESS=0.0.0.0` (the CLI warns)
  and recreate with `gosite infra up`. Legacy `minioadmin` installations are
  detected and rotated instructions are printed; new installs get generated
  credentials persisted under `~/.gosite/infra/` (mode 0600).

### Changed

- Forms anti-abuse: client identity for the rate limiter is taken from the
  right of `X-Forwarded-For` according to the configured
  `forms.trustedProxies` hops (default 1 behind Traefik), never the
  leftmost (client-forgeable) entry. The legacy boolean `trustProxy` is
  still honoured as `trustedProxies: 1` with a deprecation notice. When the
  memory backend is down, submissions fail closed with 503 + `Retry-After`
  instead of skipping the rate limit. CORS on the public receiver fails
  closed: without `allowed_origins` configured, no cross-origin header is
  emitted.

### Accepted risks

- The **Replica** addon stores peer API keys in plaintext in its target
  configuration (MongoDB), and the **Forms** addon stores the per-form
  `webhookSecret` in plaintext in the `formSettings` collection. Both are
  operator-controlled secrets in a database that also holds the content
  itself; protecting them would mean a key vault with its own secret
  management. Accepted: anyone with database access already has the content
  these secrets protect. Masked in admin output; do not expose the database
  to untrusted parties (see the loopback binding above).
