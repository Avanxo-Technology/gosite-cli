## Context

A thin site is upgraded by hand today. The steps, as done for three sites on 2026-11-16:

1. Regenerate a copy, compare compose variable names before and after (`generate` deletes hand edits in generated files).
2. Bump `core:` in `gosite.yml`, `go get <core>@vX`, `go mod tidy`, `gosite generate`, compare again, `go build/vet/test`.
3. Revert machine-specific lines that `generate` wrote. Since 0.70.0 only one is left: the absolute `gosite-addons` path in the local `docker-compose.yml` (`thin.sh`, `__ADDONS_CONTEXT_DEV__` → `${GOSITE_ROOT}/addons`).
4. Build both production images under a sandbox tag (CMS with `--build-context gosite-addons=https://github.com/Avanxo-Technology/gosite-cli.git#core/vX:src/addons`), check the PHP version and the addons inside, remove them.
5. Read MIGRATIONS.md for the versions crossed.

Relevant facts:
- The CLI's version (`src/VERSION`) and the core module tag move together: every release tags `vX` and `core/vX` on one commit, and `generate` renders templates of the CLI's own version (`thin_core_version` = `GOSITE_VERSION`).
- Every compose call gosite makes for a site goes through `project_compose` in `src/lib/helpers.sh`.
- The updater installs only `src/`. MIGRATIONS.md is at the repository root, so an installed CLI does not have it.
- The production compose already takes the addons from GitHub at `core/vX` (`__ADDONS_CONTEXT_REMOTE__`); only the local compose uses the installation.

## Goals / Non-Goals

**Goals:**
- One command does every local step of a thin upgrade, and stops before changing anything when the upgrade would lose a site's own compose variable.
- The result is a working tree ready to review and commit: same files as the manual procedure, nothing machine-specific.
- The person upgrading sees the manual steps of the versions crossed.

**Non-Goals:**
- Git (branches, commits, PRs) and deploys. Decided by the owner.
- Choosing a target version (`--to`). The target is always the CLI's version; to go further, `gosite update` first.
- Legacy sites (#49).
- Coolify configuration (environment variables, base image re-pulls). The MIGRATIONS sections name them; the command does not do them.

## Decisions

**D1. Target = installed CLI version.** `generate` can only render the templates the CLI has, so any other target would pair one version's templates with another version's core. Alternative `--to X` (≤ CLI) rejected: more cases to validate, no current need.

**D2. Order: check in a copy, then change the site.**
1. Validate: thin site, Go and Docker present, versions (site < CLI).
2. Copy the site to a temporary directory (`mktemp -d`, with `.env` because `generate` reads secrets from it), set `core:`, run `thin_generate` there, compare compose variable names with the site's files. Stop (exit 1) when a name disappears, unless `--force`.
3. In the site: set `core:`, `go get github.com/Avanxo-Technology/gosite-cli/core@vX.Y.Z`, `go mod tidy`, `thin_generate`.
4. `go build ./...`, `go vet ./...`, `go test ./...`.
5. Images (unless `--no-images`).
6. MIGRATIONS sections, summary.
A `trap` removes the temporary copy on every exit. A failure in step 3 or later leaves the site's changed files in place (the user has git to compare and revert); the summary says which step failed. Alternative "roll back on failure" rejected: the command does not use git, and restoring files by hand is the kind of logic that fails silently.

**D3. Variable comparison.** Same rule as the manual step and as MIGRATIONS (→ 0.69.0): names matched by `^ +(- )?[A-Z_][A-Z0-9_]*[=:]` in each of `docker-compose.yml`, `docker-compose.qa.yml`, `docker-compose.prod.yml`; a name in the site's file and not in the rendered one is a loss. It compares names, not values (known limit, D7). The function lives in `thin.sh` so `generate` can use it later. The message points to `app_env:` (variables the app reads) and `docker-compose.override.yml` (local services).

**D4. Images.** Tags `gosite-upgrade/<project>-app:<version>` and `gosite-upgrade/<project>-cms:<version>`. App: `docker build -f deploy/Dockerfile .`. CMS: `docker build -f deploy/Dockerfile.cms --build-context gosite-addons=https://github.com/Avanxo-Technology/gosite-cli.git#core/vX.Y.Z:src/addons .`. Checks in the CMS image: `php -r 'echo PHP_VERSION;'` (reported) and one directory per addon in `gosite.yml` under the image's addons folder. Both images are removed in the exit `trap`. The build uses the remote context on purpose: it is what production builds, so a missing `core/vX` tag fails here and not in Coolify.

**D5. Machine-independent local compose.** `__ADDONS_CONTEXT_DEV__` renders `${GOSITE_ADDONS_DIR:?set GOSITE_ADDONS_DIR to the addons folder of your gosite installation, or run this through gosite}`. `project_compose` exports `GOSITE_ADDONS_DIR="${GOSITE_ROOT}/addons"`. Alternatives: keep the absolute path and have `upgrade` restore the committed line (rejected by the owner: the problem stays for every `generate`); `${GOSITE_ADDONS_DIR:-<fallback>}` (rejected: a wrong fallback builds a CMS without addons and fails later, less clearly). Cost: every `docker compose` call by hand on that file needs the variable, including `ps` and `logs`, because compose interpolates the whole file.

**D6. MIGRATIONS.md from the tag.** `curl -fsSL https://raw.githubusercontent.com/Avanxo-Technology/gosite-cli/vX.Y.Z/MIGRATIONS.md`, then print each `## → A.B.C` section with old < A.B.C ≤ new (compared with the existing `_versions_newer` in `src/lib/versions.sh`, also used for the site/CLI checks in step 1). On failure, print `https://github.com/Avanxo-Technology/gosite-cli/blob/vX.Y.Z/MIGRATIONS.md`. Alternative: ship MIGRATIONS.md in `src/` (rejected for now: moves a root document and changes the release recipe; reconsider if offline upgrades matter).

**D7. Output.** One `info` line per step, `ok`/`warn`/`err` as the other commands. A final summary: old → new version, steps passed, images checked or skipped, lost variables (with `--force`), and the reminder that nothing was committed or deployed.

## Risks / Trade-offs

- [Name comparison misses changed values] → A site that changed the value of a variable the template also sets loses that value silently. Mitigation: the summary tells the user to read `git diff` of the compose files; a value comparison can come later.
- [Network needed] → `go get`, the CMS addons context and MIGRATIONS.md need GitHub / the Go proxy. Mitigation: `--no-images` for the build; MIGRATIONS falls back to a link. `go get` has no fallback.
- [Fresh tag not yet in the Go proxy] → Seconds after a release, `go get` can cache "unknown revision". Mitigation: on that error, retry once with `GOPROXY=direct` and say so.
- [`:?` in the local compose] → `docker compose ps` by hand fails without the variable. Mitigation: the message says what to set; README documents it.
- [Partial upgrade on failure] → After step 3 the site's files are changed even if tests fail. Accepted (D2); the summary names the failed step.
- [Image build time] → Several minutes per upgrade. Mitigation: `--no-images`.

## Migration Plan

- Existing thin sites get `${GOSITE_ADDONS_DIR}` in their local compose on their next `generate` (or `upgrade`). Nothing to do by hand when they use `gosite start`.
- Release as a minor version (new command, changed generated file).

## Open Questions

- Should `gosite generate` also stop before deleting variables (shared function from D3)? Proposed: later, as its own change; this change only exposes the function.
