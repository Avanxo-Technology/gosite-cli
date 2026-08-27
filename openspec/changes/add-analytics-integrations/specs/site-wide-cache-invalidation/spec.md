## ADDED Requirements

### Requirement: A change to what every page shares invalidates every page

Content that appears in the layout SHALL invalidate the whole project's cached
pages when it changes, not only the area the edit belongs to.

Cache invalidation currently assumes an edit affects one part of the site: the
home page purges itself, and a feature owning its own keys purges its own. That
assumption does not hold for anything in the layout, which is on every page.

#### Scenario: An integration is added

- **WHEN** an integration is stored and enabled
- **THEN** no cached page continues to be served without it — the home page and
  every other page alike

#### Scenario: A key is corrected

- **WHEN** a configuration value is edited
- **THEN** every page serves the corrected value without waiting out a cache
  window

#### Scenario: An integration is disabled

- **WHEN** an integration is disabled
- **THEN** no cached page continues to serve it

### Requirement: A feature must not silently ignore a model it does not know

A feature that owns cached pages SHALL NOT assume that a model it does not
recognise is irrelevant to it. A model that is not its own may still change
what its pages contain.

#### Scenario: An unrecognised model that changes the layout

- **WHEN** a model no feature claims is saved, and it affects the layout
- **THEN** the feature's pages are invalidated rather than left stale

#### Scenario: An unrecognised model that changes nothing shared

- **WHEN** a model is saved that no page reads
- **THEN** cached pages may be kept, so a purge stays cheap for edits that
  cannot have changed anything

### Requirement: Purging remains authenticated and fail-closed

Widening what a purge invalidates SHALL NOT weaken its authentication. An
unauthenticated purge request SHALL be refused, and a missing token SHALL NOT
be treated as "no authentication required".

#### Scenario: Unauthenticated purge

- **WHEN** a purge is requested without valid credentials
- **THEN** it is refused and nothing is purged

#### Scenario: Token not configured

- **WHEN** no purge token is configured in a non-development environment
- **THEN** the endpoint refuses the request rather than purging

### Requirement: A site-wide purge is not a cache flush

Purging a project's pages SHALL be scoped to that project. It SHALL NOT clear
keys belonging to other projects sharing the same cache backend.

#### Scenario: Several projects on the shared cache

- **WHEN** one project's pages are purged
- **THEN** another project's cached pages are untouched
