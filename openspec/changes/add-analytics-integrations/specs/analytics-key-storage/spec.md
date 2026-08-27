## ADDED Requirements

### Requirement: The addon self-installs its collection

The Analytics addon SHALL create its content model on first admin load without
manual setup, and SHALL NOT overwrite a model that already exists.

#### Scenario: Fresh installation

- **WHEN** an administrator opens the Cockpit admin for the first time after the
  addon is installed
- **THEN** the collection exists with its declared fields, and no manual step
  was required

#### Scenario: A model of the same name already exists

- **WHEN** the project already has a model of that name
- **THEN** the addon leaves it untouched, fields included

#### Scenario: The model is visible to the API

- **WHEN** the model is created on an environment running with debug off
- **THEN** the REST API returns it rather than answering "model not found"

### Requirement: One entry per integration

Each entry SHALL identify its provider, carry that provider's configuration,
and say whether it is enabled. Adding an integration SHALL be adding an entry,
with no schema change.

#### Scenario: Adding an integration

- **WHEN** an editor adds an entry naming a provider and its configuration
- **THEN** the site serves that provider's script without any release

#### Scenario: Providers need different configuration

- **WHEN** one entry is a provider needing a single id and another needs a key
  and a host
- **THEN** both are storable without adding fields for either

#### Scenario: Disabling without deleting

- **WHEN** an entry is disabled
- **THEN** the site stops serving that provider, and the configuration is still
  there to re-enable

### Requirement: Only providers the site can render are selectable

The provider SHALL be chosen from a fixed set — the providers the application
has a plugin for — rather than typed freely. A provider the site cannot render
SHALL NOT be storable.

#### Scenario: Known provider

- **WHEN** an editor picks a provider from the list
- **THEN** the entry saves and the site renders it

#### Scenario: Unknown provider

- **WHEN** an editor tries to store a provider the application has no plugin
  for
- **THEN** the save is refused, naming the problem — rather than saving an
  entry that silently never renders

### Requirement: Keys are validated on save

Each provider's configuration SHALL be checked against the shape that provider
uses, so a mistyped key is caught at the moment it is entered rather than
discovered later as missing data.

#### Scenario: Well-formed key

- **WHEN** an editor saves a key matching its provider's documented format
- **THEN** the entry saves

#### Scenario: Malformed key

- **WHEN** an editor saves a key that cannot be valid for that provider
- **THEN** the save is refused with a message naming the expected shape

#### Scenario: Characters that would be dangerous in a script

- **WHEN** a value contains quotes, angle brackets or backslashes
- **THEN** it is refused at save time, independently of any escaping the
  application does when rendering

### Requirement: An entry declares where it applies

Each entry SHALL say which environments it applies to, so development traffic
does not reach a client's production analytics account.

#### Scenario: Production-only entry in development

- **WHEN** an entry applies to production and the site runs in development
- **THEN** the site does not load that provider

#### Scenario: Entry that applies everywhere

- **WHEN** an entry applies to every environment
- **THEN** the site loads it in development too

### Requirement: The admin screen shows what is live

The addon SHALL provide an admin screen listing the integrations with their
provider, whether they are enabled, and where they apply, gated by a permission
exposed in Settings > Roles.

#### Scenario: Reviewing integrations

- **WHEN** an administrator opens the screen
- **THEN** each integration's provider, state and environments are visible
  without opening each entry

#### Scenario: Permission enforced

- **WHEN** a user without the permission requests the screen
- **THEN** the request is refused and no integration data is returned
