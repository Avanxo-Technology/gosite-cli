## ADDED Requirements

### Requirement: Shared datastores bind to loopback only

The shared infrastructure SHALL publish MongoDB, Redis and MinIO host ports on `127.0.0.1` rather than on every interface. Only the Traefik entrypoints (80/443) SHALL remain bound to all interfaces, since serving the local domains is their purpose.

The bind address SHALL be overridable through `GOSITE_BIND_ADDRESS` for operators who deliberately need LAN access.

#### Scenario: Default infrastructure bring-up

- **WHEN** `gosite infra up` runs with no overrides
- **THEN** the Mongo, Redis and MinIO port mappings are prefixed with `127.0.0.1:`
- **AND** the datastores are unreachable from another host on the same network

#### Scenario: Services still reachable inside the network

- **WHEN** a project container resolves `gosite-mongo` on the shared Docker network
- **THEN** the connection succeeds, because container-to-container traffic does not use the published host ports

#### Scenario: Operator opts into LAN exposure

- **WHEN** `GOSITE_BIND_ADDRESS` is set to `0.0.0.0`
- **THEN** the published ports bind to every interface
- **AND** `gosite infra up` prints a warning naming the unauthenticated services now exposed

#### Scenario: Existing infrastructure is migrated

- **WHEN** `gosite infra up` runs against an infrastructure created before this change
- **THEN** the compose file is regenerated with loopback bindings
- **AND** the affected containers are recreated

### Requirement: MinIO credentials are generated per installation

The shared MinIO SHALL NOT use fixed `minioadmin` credentials. Credentials SHALL be generated once at first `infra up`, persisted in the infrastructure directory with owner-only permissions, and reused on subsequent runs.

#### Scenario: First infrastructure bring-up

- **WHEN** `gosite infra up` runs and no credential file exists
- **THEN** a random root user and password are generated and written to the infra directory with mode `0600`

#### Scenario: Subsequent bring-ups

- **WHEN** `gosite infra up` runs and a credential file already exists
- **THEN** the stored credentials are reused
- **AND** MinIO is not recreated on account of credentials

#### Scenario: Projects receive the generated credentials

- **WHEN** a project is created or synced
- **THEN** its `.env` receives the generated `S3_KEY` and `S3_SECRET` values rather than the `minioadmin` literals

#### Scenario: Pre-existing installation keeps working

- **WHEN** infrastructure created before this change is brought up and its MinIO volume already holds data under the old credentials
- **THEN** gosite detects the legacy credentials, keeps using them, and prints how to rotate them

### Requirement: TLS verification toward S3 is not disabled by default

`S3_VERIFY` SHALL default to enabled. The generated project configuration SHALL only disable it for the local development endpoint, and the production template SHALL never carry a disabling value.

#### Scenario: Production project configuration

- **WHEN** a production environment file is rendered
- **THEN** it contains no `S3_VERIFY=false`

#### Scenario: Local development against mkcert MinIO

- **WHEN** a development project targets the local MinIO
- **THEN** `S3_VERIFY=false` is present with a comment naming the mkcert certificate as the reason
