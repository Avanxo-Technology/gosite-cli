## ADDED Requirements

### Requirement: Core is a public versioned Go module
The gosite core SHALL be published as a public Go module, released with semantic version tags, that contains every package a site previously received under `internal/` (app wiring, cms client, cache, seo, views, analytics/consent, core handlers).

#### Scenario: Site depends on core
- **WHEN** a thin site is built
- **THEN** its `go.mod` requires the core module at a tagged version and the site tree contains no copy of core source

#### Scenario: Upgrade by version bump
- **WHEN** a site changes the required core version to a newer minor or patch release and runs `go mod tidy`
- **THEN** the site builds and renders without any edit to `site/`, `theme/` or `gosite.yml`

### Requirement: Public API surface is explicit
The core module SHALL expose only the packages and identifiers documented in `CORE_API.md`; everything else SHALL live under the module's `internal/` directory so sites cannot import it.

#### Scenario: Importing an internal package
- **WHEN** site code imports a core package under `internal/`
- **THEN** the Go toolchain refuses the build

### Requirement: Deprecation before removal
The core SHALL NOT remove or change the meaning of a public identifier, template slot, view-model field or `gosite.yml` key in a minor or patch release; it SHALL first keep it working for at least one minor release while logging a deprecation warning once at startup that names the replacement.

#### Scenario: Deprecated slot still used
- **WHEN** a theme calls a template slot marked deprecated
- **THEN** the page renders as before and the server logs one warning naming the replacement slot

#### Scenario: Removal requires a major version
- **WHEN** a deprecated identifier is removed
- **THEN** the removal ships in a new major version with an entry in the module changelog
