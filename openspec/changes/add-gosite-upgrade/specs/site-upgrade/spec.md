## ADDED Requirements

### Requirement: gosite upgrade takes a thin site to the CLI's version
`gosite upgrade [name]` SHALL take a thin site to the installed CLI's version by setting `core:` in `gosite.yml`, requiring the core module at that version in `go.mod` (`go get` and `go mod tidy`), and regenerating the generated files, and SHALL NOT run git commands, push images or deploy.

#### Scenario: Site one version behind
- **WHEN** the CLI is 0.71.0 and a thin site has `core: 0.69.0`, and a user runs `gosite upgrade <site>`
- **THEN** `gosite.yml` says `core: 0.71.0`, `go.mod` requires the core at `v0.71.0`, the generated files match what `gosite generate` writes for 0.71.0, and the git state of the site is unchanged apart from the modified files

#### Scenario: Site already at the CLI's version
- **WHEN** the site's `core:` equals the CLI's version
- **THEN** the command says so and changes nothing

#### Scenario: Site newer than the CLI
- **WHEN** the site's `core:` is newer than the CLI's version
- **THEN** the command changes nothing and tells the user to run `gosite update`

#### Scenario: Legacy site
- **WHEN** the project has no `gosite.yml`
- **THEN** the command changes nothing and points to MIGRATIONS.md

### Requirement: Upgrade stops before losing compose variables
`gosite upgrade` SHALL render the new generated files into a temporary copy before changing the site, SHALL compare the variable names of each compose file in the site with the rendered one, and SHALL stop without changing the site when a name would disappear, unless `--force` is given.

#### Scenario: Hand-added variable in a generated compose
- **WHEN** the site's `docker-compose.prod.yml` sets a variable that the new template does not have
- **THEN** the command lists that variable and its file, suggests `app_env:` in `gosite.yml` or `docker-compose.override.yml`, and exits non-zero with every file in the site unchanged

#### Scenario: Forced upgrade
- **WHEN** the same site is upgraded with `--force`
- **THEN** the upgrade runs and the lost variables are listed again at the end

#### Scenario: Temporary copy removed
- **WHEN** the command ends, whether it succeeded, stopped or failed
- **THEN** the temporary copy, including the copied `.env`, no longer exists

### Requirement: Upgrade verifies the site locally
After regenerating, `gosite upgrade` SHALL run `go build`, `go vet` and `go test` on the site, and, unless `--no-images` is given, SHALL build the production app and CMS images under a temporary tag, with the CMS addons context taken from `core/vX.Y.Z` on GitHub, and SHALL remove those images when it ends.

#### Scenario: Tests fail after the upgrade
- **WHEN** `go test` fails on the upgraded site
- **THEN** the command shows the failure, leaves the upgraded files in place for the user to fix, and exits non-zero

#### Scenario: Images built and removed
- **WHEN** the upgrade runs without `--no-images`
- **THEN** both images build, the command reports the CMS image's PHP version and that it contains the addons listed in `gosite.yml`, and no image with the temporary tag remains

#### Scenario: Images skipped
- **WHEN** the upgrade runs with `--no-images`
- **THEN** no image is built and the summary says that the images were not checked

### Requirement: Upgrade shows the manual steps of the versions it crosses
At the end, `gosite upgrade` SHALL print the MIGRATIONS.md sections for every version after the site's old version up to and including the new one, read from the new version's tag on GitHub, and SHALL print the MIGRATIONS.md link instead when the file cannot be fetched.

#### Scenario: Crossing a version with a manual step
- **WHEN** a site goes from 0.69.0 to 0.71.0
- **THEN** the output includes the "→ 0.70.0", "→ 0.70.1" and "→ 0.71.0" sections, including the `COCKPIT_SEC_KEY` step

#### Scenario: No network for MIGRATIONS.md
- **WHEN** MIGRATIONS.md cannot be fetched
- **THEN** the command prints its URL at the new version's tag and still exits zero if every other step passed
