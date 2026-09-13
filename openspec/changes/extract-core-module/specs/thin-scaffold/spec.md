## ADDED Requirements

### Requirement: gosite create generates a thin site
`gosite create` SHALL generate `main.go`, `site/`, `theme/` (layout, pages, partials for the chosen flavor), `static/`, `gosite.yml` and a `go.mod` requiring the core module at the CLI's matching version, and SHALL NOT copy core Go packages or gosite's Cockpit addons into the project.

#### Scenario: Fresh site builds and runs
- **WHEN** a user runs `gosite create demo -y` and `gosite start demo`
- **THEN** the site builds, serves the home page from the CMS, and its tree has no `internal/cms`, `internal/cache` or `cockpit/addons/Blog`

#### Scenario: Existing CLI options preserved
- **WHEN** a user passes `--storage`, `--database`, `--addons` or `--no-addons`
- **THEN** the choices are written to `gosite.yml` with the same meaning they have today

### Requirement: gosite.yml is the site's declarative configuration
`gosite.yml` SHALL record the project name, module path, core version, flavor, ports, domains, storage adapter, database choice and addons, and SHALL replace `.gosite.env` as the source that `gosite generate` reads for thin sites.

#### Scenario: Generate preserves choices
- **WHEN** `gosite generate` runs on a thin site created with `--storage local`
- **THEN** generated files still use local storage

### Requirement: Generated files are regenerated and overridable
`gosite generate` SHALL work only on thin sites (a `gosite.yml` is present), SHALL regenerate compose files, Dockerfiles and `cockpit/config.core.php` from `gosite.yml` on every run, and SHALL never modify `docker-compose.override.yml` or `cockpit/config.local.php`, which the generated files include last, and SHALL only overwrite a file that is absent or carries gosite's generated-file header.

#### Scenario: Local override survives generate
- **WHEN** a user adds a service to `docker-compose.override.yml` and runs `gosite generate`
- **THEN** the override is unchanged and the service still starts with the site

#### Scenario: New core config default
- **WHEN** a core release adds a default to `config.core.php` (for example the Forms `trustedProxies` block)
- **THEN** the site receives it on the next `gosite generate` without editing `config.local.php`

#### Scenario: Legacy project refused
- **WHEN** `gosite generate` runs in a project without `gosite.yml`
- **THEN** it changes nothing and points to MIGRATIONS.md

#### Scenario: Hand-edited generated file
- **WHEN** a generated file has lost its generated-file header
- **THEN** `gosite generate` leaves it untouched and names it, telling the user to move the change to the override file
