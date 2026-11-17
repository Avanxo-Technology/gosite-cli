## 1. Machine-independent local compose (D5)

- [x] 1.1 `src/templates-thin/generated/docker-compose.yml`: CMS `gosite-addons` context becomes `${GOSITE_ADDONS_DIR:?...}`; drop `__ADDONS_CONTEXT_DEV__` from `_thin_render` in `src/lib/thin.sh`
- [x] 1.2 `project_compose` in `src/lib/helpers.sh` exports `GOSITE_ADDONS_DIR="${GOSITE_ROOT}/addons"`
- [x] 1.3 bats: generated local compose has no absolute path and is identical for two different `GOSITE_ROOT` values; `docker compose config` fails without the variable with a message naming it
- [x] 1.4 Prove on a copy of `~/gosites/analytics-draft-v2`: generate, `docker compose config` through `project_compose` resolves the addons path; the CMS image builds with the addons (local build, image removed after)

## 2. Shared helpers in thin.sh (D3)

- [x] 2.1 `thin_compose_var_names <file>`: prints the variable names of a compose file (the regex in D3), sorted, unique; same output on BSD and GNU tools
- [x] 2.2 `thin_lost_compose_vars <site-dir> <rendered-dir>`: prints `<file>\t<name>` for every name in the site's compose files that the rendered ones lack
- [x] 2.3 `thin_set_core_version <gosite.yml> <version>`: rewrites the `core:` line only
- [x] 2.4 bats for the three functions (including a compose with no variables and a missing file)

## 3. gosite upgrade command (D1, D2, D4, D6, D7)

- [x] 3.1 `src/commands/cmd_upgrade.sh` with usage (`gosite upgrade [name] [--force] [--no-images]`), flag parsing and project resolution as `generate`
- [x] 3.2 Step 1 checks: thin site, `go` and `docker` present, versions with `_versions_newer` (same → nothing to do; site newer → `gosite update`)
- [x] 3.3 Step 2: temporary copy (with `.env`), `core:` set, `thin_generate` there, `thin_lost_compose_vars`; stop with the list unless `--force`; `trap` removes the copy on every exit
- [x] 3.4 Step 3 in the site: `thin_set_core_version`, `go get <core>@vX.Y.Z` (retry once with `GOPROXY=direct` on "unknown revision"), `go mod tidy`, `thin_generate` with the same output as `gosite generate`
- [x] 3.5 Step 4: `go build ./...`, `go vet ./...`, `go test ./...`; on failure report the step and exit non-zero, leaving files in place
- [x] 3.6 Step 5 (unless `--no-images`): build app and CMS images under `gosite-upgrade/` tags, CMS with the remote addons context at `core/vX.Y.Z`; report PHP version; check one addon directory per `gosite.yml` addon; remove images in the `trap`
- [x] 3.7 Step 6: fetch MIGRATIONS.md at `vX.Y.Z`, print the `## → A.B.C` sections with old < A.B.C ≤ new; on fetch failure print the URL
- [x] 3.8 Summary (D7), including lost variables when forced and "nothing committed or deployed"
- [x] 3.9 Dispatcher entry and help line in `src/dispatcher.sh`

## 4. Tests

- [x] 4.1 `tests/upgrade.bats` (no Docker, no network): legacy refused; same version refused; site newer refused; lost variable stops with the site unchanged and no temporary copy left; `--force` continues past the check (stub `go`/`docker`/`curl` on `PATH`)
- [x] 4.2 MIGRATIONS section selection from a fixture file (0.69.0 → 0.71.0 prints 0.70.0, 0.70.1, 0.71.0 and nothing else)
- [ ] 4.3 shellcheck clean; full `bats tests/` green on macOS; CI green on Linux

## 5. Prove on a sandbox site (no real site)

- [x] 5.1 Copy of `~/gosites/analytics-draft-v2` (core 0.54.0) in the scratchpad: `gosite upgrade` with images; capture the output for the PR
- [x] 5.2 Same copy with a hand-added variable in `docker-compose.prod.yml`: the command stops and the copy is unchanged (compare checksums before/after)
- [x] 5.3 After 5.1: `git diff --stat` of the copy matches the manual procedure (gosite.yml, go.mod, go.sum, generated files only) and no `gosite-upgrade/` image remains

## 6. Docs and release

- [x] 6.1 `README.md` usage, `docs/index.html` commands table
- [x] 6.2 MIGRATIONS.md: "Upgrading a thin site" points to `gosite upgrade`; note on `GOSITE_ADDONS_DIR` for hand-run compose
- [x] 6.3 Scaffold `AGENTS.md`/`ARCHITECTURE.md` templates in `cmd_create.sh` if they describe the manual upgrade (checked: they do not)
- [x] 6.4 `src/VERSION` minor bump (number confirmed by the owner), CHANGELOG
