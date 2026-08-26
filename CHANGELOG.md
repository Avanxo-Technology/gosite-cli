# Changelog

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
