## Why

A thin site upgrades by changing one version, but nothing in the CLI does it. `gosite update` updates the CLI only, and `gosite generate` rewrites the generated files without touching `core:` or `go.mod`. Each site upgrade is a manual list of steps (MIGRATIONS.md and the upgrade notes of the 0.69.0 rollout): bump the core, `go get`, `go mod tidy`, `generate`, compare the compose variables that `generate` would delete, revert a machine-specific path, build and test, build the production images and look inside them, read the MIGRATIONS sections in between. Three sites were upgraded this way on 2026-11-16, and every one had a hand edit that `generate` would have deleted.

## What Changes

- **New command `gosite upgrade [name]`** for thin sites. It takes the site to the installed CLI's version and runs every local step:
  1. Refuses a legacy site, a site already at that version, and a site newer than the CLI.
  2. Renders the new generated files into a temporary copy and compares the variable names of each compose file. If a variable the site has would disappear, it lists them and stops before changing anything (`--force` continues).
  3. Sets `core:` in `gosite.yml`, runs `go get <core>@vX.Y.Z` and `go mod tidy`, then `gosite generate`.
  4. Runs `go build`, `go vet` and `go test` on the site.
  5. Builds the production app and CMS images under a temporary tag (CMS with the remote addons context at `core/vX.Y.Z`), checks them, and removes them. `--no-images` skips this step.
  6. Prints the MIGRATIONS.md sections between the old and the new version, which name the manual steps (for example `COCKPIT_SEC_KEY` in 0.70.0).
- The command does nothing with git and deploys nothing.
- **The local `docker-compose.yml` no longer contains a path of the machine that generated it.** The CMS `gosite-addons` build context becomes `${GOSITE_ADDONS_DIR}`, which gosite exports for every compose call it makes. Running `docker compose` by hand without the variable fails with a message that names it.
- Legacy sites are out of scope (#49).

## Capabilities

### New Capabilities
- `site-upgrade`: `gosite upgrade` takes a thin site to the installed CLI's version, with the safety checks and the local verification above.

### Modified Capabilities
- `thin-scaffold`: generated files no longer depend on the machine that generated them (new requirement; the existing ones do not change).

## Impact

- New `src/commands/cmd_upgrade.sh`, dispatcher entry and help line.
- `src/lib/thin.sh`: the compose variable comparison moves into a function shared by `upgrade` (and usable by `generate`); the `__ADDONS_CONTEXT_DEV__` placeholder becomes `${GOSITE_ADDONS_DIR}`.
- `src/lib/helpers.sh`: `project_compose` exports `GOSITE_ADDONS_DIR`.
- `src/templates-thin/generated/docker-compose.yml` (local compose).
- Tests: new `tests/upgrade.bats`; `tests/thin.bats` for the compose change.
- Docs: `README.md` (usage), `docs/index.html` (commands table), MIGRATIONS (how to upgrade a thin site now), `AGENTS.md` template in the scaffold if it names the manual steps.
- Needs network at run time: the Go module proxy (or GitHub) for `go get`, GitHub for the CMS image's addons context and for MIGRATIONS.md.
- Needs Go and Docker on the machine, as `gosite start` already does.
