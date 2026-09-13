## ADDED Requirements

### Requirement: Sites start through gosite.Run
The core SHALL provide `gosite.Run(app App) error`, which loads configuration, connects Redis, builds the CMS client, cache, SEO, analytics and renderer, registers core routes and the site's routes, and serves with graceful shutdown.

#### Scenario: Minimal site
- **WHEN** a site's `main.go` calls `gosite.Run` with an `App` whose `Routes` registers `GET /`
- **THEN** the server answers `/`, and also `/healthz`, `/robots.txt`, `/sitemap.xml`, `/llms.txt` and `POST /cache/purge` without site code for them

#### Scenario: Misconfigured environment fails at boot
- **WHEN** Redis is unreachable at startup
- **THEN** `gosite.Run` returns an error before accepting connections

### Requirement: App interface with optional extensions
The `App` interface SHALL require only `Routes(r Router)`; additional behaviour SHALL be opted into by implementing optional interfaces detected at startup: middleware, extra template data per page, and a purge hook.

#### Scenario: Optional interface not implemented
- **WHEN** an `App` implements only `Routes`
- **THEN** the site runs with core defaults and no error

#### Scenario: Purge hook
- **WHEN** an `App` implements the purge hook and an editor triggers a site-wide purge
- **THEN** core purges its cache keys and then calls the hook once

### Requirement: Core features can be disabled without code edits
Each core route or feature (sitemap, robots, llms, analytics, consent) SHALL be disableable through a `gosite.Run` option or `gosite.yml`, and a site route registered on the same path SHALL take precedence over the core route.

#### Scenario: Site replaces robots.txt
- **WHEN** a site registers `GET /robots.txt` in `Routes`
- **THEN** requests to `/robots.txt` are served by the site handler

### Requirement: App state is isolated from the cache namespace
The core SHALL keep cache keys under `<project>:cache:` and SHALL provide `State()` on the `Router` handed to `Routes`, a Redis accessor scoped to `<project>:app:`, and no purge operation SHALL delete keys outside `<project>:cache:`.

#### Scenario: Purge keeps app state
- **WHEN** a site stores a key through `State()` and a site-wide purge runs
- **THEN** the key still exists with its TTL unchanged

### Requirement: Cockpit client is the only content source
Core and site code SHALL read CMS content only through the core Cockpit REST client, and the core module SHALL NOT contain or expose a direct MongoDB content reader.

#### Scenario: Site needs a collection
- **WHEN** a site handler needs entries of a Cockpit collection
- **THEN** it obtains them from the client returned by `CMS()` on the `Router`
