## ADDED Requirements

### Requirement: Doctor audits security configuration without changing it

`gosite doctor` SHALL inspect the registered projects and the shared infrastructure for deviations from the secure defaults and report them. It SHALL NOT modify any file, container or configuration as part of the audit.

Each finding SHALL name the project, the setting, the observed value, the risk in one line, and the exact command that would remediate it.

#### Scenario: Audit is read-only

- **WHEN** `gosite doctor` runs
- **THEN** no project file, infrastructure file or container is modified

#### Scenario: Project without proxy trust configured

- **WHEN** a project's Cockpit configuration does not set `forms.trustedProxies`
- **THEN** the audit reports that the Forms rate limit applies globally rather than per visitor
- **AND** it names `gosite sync` as the remediation

#### Scenario: Deployed project without a purge token

- **WHEN** a project's environment file has an empty `COCKPIT_API_TOKEN`
- **THEN** the audit reports the purge endpoint as unauthenticated in a non-development deployment

#### Scenario: Wildcard CORS in a project

- **WHEN** a project's Forms configuration allows any origin
- **THEN** the audit reports the public receiver as open to every origin

#### Scenario: Infrastructure exposed beyond loopback

- **WHEN** the shared infrastructure publishes Mongo or Redis on a non-loopback address
- **THEN** the audit reports the unauthenticated datastore as network-reachable

#### Scenario: Clean installation

- **WHEN** no deviation is found across the infrastructure and the registered projects
- **THEN** the audit reports that the security checks passed
- **AND** the command exits zero

#### Scenario: Exit status usable in automation

- **WHEN** at least one finding is reported and the audit runs with a strictness flag
- **THEN** the command exits non-zero

#### Scenario: Unreachable project directory

- **WHEN** a registered project's directory no longer exists
- **THEN** it is reported as unavailable and skipped
- **AND** the audit continues with the remaining projects
