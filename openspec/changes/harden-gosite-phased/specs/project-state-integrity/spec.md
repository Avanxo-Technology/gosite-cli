## ADDED Requirements

### Requirement: Mutations of CLI state files are serialized and atomic

Every read-modify-write of `projects.tsv` and `ports.tsv` SHALL execute while holding an exclusive lock scoped to that file, and SHALL be published by an atomic rename from a temporary file on the same filesystem.

Locking SHALL work on macOS, where `flock(1)` is not present by default.

#### Scenario: Concurrent registrations

- **WHEN** two `gosite create` runs register different projects at the same time
- **THEN** the registry ends up containing both entries

#### Scenario: Interrupted write

- **WHEN** a write is interrupted before completion
- **THEN** the state file retains its previous complete contents
- **AND** no partial file is left in its place

#### Scenario: Lock held by a dead process

- **WHEN** a lock was left behind by a process that no longer exists
- **THEN** the lock is reclaimed after a bounded timeout
- **AND** the reclamation is logged in verbose mode

#### Scenario: Lock contention resolves

- **WHEN** a second process requests a lock currently held
- **THEN** it waits until the lock is released rather than proceeding unsynchronized
- **AND** it fails with a clear message if the wait exceeds the timeout

### Requirement: Reading the registry does not mutate it

Listing projects SHALL be a read-only operation. Pruning entries whose directories no longer exist SHALL only happen through an explicit, lock-protected maintenance path — never as a side effect of a read.

#### Scenario: Listing projects

- **WHEN** `gosite list` runs
- **THEN** the registry file is not rewritten
- **AND** entries whose directory is missing are shown as unavailable rather than dropped

#### Scenario: Two concurrent listings

- **WHEN** two `gosite list` runs execute simultaneously
- **THEN** both print the full set of registered projects
- **AND** the registry file is unchanged afterwards

#### Scenario: Explicit pruning

- **WHEN** the maintenance path runs and a registered directory no longer exists
- **THEN** that entry is removed under lock
- **AND** the removal is reported

#### Scenario: Read of an absent registry

- **WHEN** no registry file exists yet
- **THEN** the listing reports no projects and creates nothing

### Requirement: Port selection and reservation are one atomic operation

Choosing a free host port and recording its reservation SHALL happen inside a single critical section, so that two concurrent project creations cannot select the same port.

#### Scenario: Concurrent project creation

- **WHEN** two `gosite create` runs allocate ports simultaneously
- **THEN** each project receives a distinct app port and a distinct CMS port

#### Scenario: Port range exhausted

- **WHEN** no port in the configured range is free
- **THEN** creation fails with an error naming the range
- **AND** no partial reservation is left behind

#### Scenario: Reservation released on removal

- **WHEN** a project is removed
- **THEN** its reserved ports become available to a subsequent creation

#### Scenario: Failed creation does not leak a reservation

- **WHEN** project creation fails after ports were reserved
- **THEN** the reservation is released before the command exits
