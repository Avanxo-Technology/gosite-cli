## ADDED Requirements

### Requirement: Every page carries the integrations, without any handler passing them

The integrations SHALL reach the templates without being threaded through each
handler's data, so a page added later cannot silently lose its tracking.

#### Scenario: A page nobody thought about

- **WHEN** a new page is added and its handler passes only its own data
- **THEN** that page still renders the configured integrations

#### Scenario: Existing pages

- **WHEN** the home page and a blog article are rendered
- **THEN** both carry the same integrations

### Requirement: Scripts render into the head and the body

The component SHALL offer a head block and a body block, and each provider
SHALL decide which it needs. An editor SHALL NOT have to know that a provider
requires markup in two places.

#### Scenario: A provider needing both

- **WHEN** a provider requires a script in the head and a fallback in the body
- **THEN** both appear, from one entry

#### Scenario: A provider needing only the head

- **WHEN** a provider requires only a head script
- **THEN** nothing is emitted into the body for it

#### Scenario: No integrations configured

- **WHEN** no integration is enabled for this environment
- **THEN** neither block emits anything — no empty script tags, no empty
  configuration block

### Requirement: Keys reach the browser as data, never as code

Configuration values SHALL be delivered as data for a script to read, and SHALL
NOT be interpolated into JavaScript source. No inline executable script SHALL
be required to configure the integrations.

#### Scenario: A value containing script syntax

- **WHEN** a configuration value contains quotes or a closing script tag
- **THEN** nothing executes: the value is inert data, and reading it fails
  harmlessly at worst

#### Scenario: Content Security Policy

- **WHEN** the site is served with a policy forbidding inline script execution
- **THEN** the integrations still load

### Requirement: Loading order is deterministic

The core, the plugins and the initialisation SHALL execute in a defined order.
Initialisation SHALL NOT run before the core and the plugins it references are
available.

#### Scenario: Slow network

- **WHEN** the core takes longer than usual to arrive
- **THEN** initialisation still runs after it, not before

### Requirement: No event is lost to initialisation timing

An integration SHALL report itself ready only once it can actually accept
events, so events raised early are delivered rather than dropped.

#### Scenario: An event raised immediately on page load

- **WHEN** the page raises an event before the provider has finished loading
- **THEN** the event reaches the provider once it is ready

#### Scenario: A provider that never loads

- **WHEN** a provider's script is blocked or fails to load
- **THEN** the page still works, other providers still receive their events,
  and nothing is reported as delivered that was not

### Requirement: The site works when the CMS has nothing to say

Missing, empty or unreachable integration data SHALL NOT prevent a page from
rendering. Analytics is never the reason a visitor sees an error.

#### Scenario: No integrations stored

- **WHEN** the collection is empty
- **THEN** pages render normally with no analytics

#### Scenario: CMS unreachable while rendering

- **WHEN** the integrations cannot be read
- **THEN** the page still renders, and the failure is logged rather than shown

### Requirement: The core is pinned

The third-party library SHALL be loaded from a pinned version. A floating
version SHALL NOT be used, because it would let an upstream change take effect
on every client site with no deployment.

#### Scenario: Upstream publishes a new major version

- **WHEN** the library publishes a release
- **THEN** the sites keep serving the version they were deployed with, until
  the pinned version is changed deliberately

### Requirement: Provider plugins live in the base

The plugins SHALL ship with gosite's templates rather than being written per
project, so a fix reaches every project through the normal sync path and a
project that has customised one is told rather than overwritten.

#### Scenario: Fixing a plugin

- **WHEN** a plugin is corrected in gosite and a project syncs its application
  sources
- **THEN** that project receives the corrected plugin

#### Scenario: A project customised a plugin

- **WHEN** a project has edited a plugin and syncs
- **THEN** the edit is preserved and reported, consistent with how sync treats
  every file it manages
