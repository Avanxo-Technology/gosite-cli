## ADDED Requirements

### Requirement: Shell sources are linted

Every shell source under `src/` SHALL pass `shellcheck` at a severity level agreed in the design, enforced in continuous integration.

#### Scenario: Clean sources

- **WHEN** the lint job runs against sources with no findings at or above the configured severity
- **THEN** the job passes

#### Scenario: Regression introduced

- **WHEN** a change introduces a finding at or above the configured severity
- **THEN** the job fails naming the file, line and rule

#### Scenario: Deliberate suppression

- **WHEN** a specific finding is suppressed with an inline directive carrying a justification comment
- **THEN** the job passes

### Requirement: Behavioural tests for CLI state handling

The state-handling logic — registry, port reservation, locking and project resolution — SHALL be covered by automated tests that run without Docker.

#### Scenario: Test suite runs hermetically

- **WHEN** the suite runs with the gosite home and workspace pointed at temporary directories
- **THEN** it passes without touching the developer's real `~/.gosite`
- **AND** it requires no running Docker daemon

#### Scenario: Concurrency regression is caught

- **WHEN** a change removes the locking around a state file mutation
- **THEN** the concurrency test fails

#### Scenario: Tests run in CI

- **WHEN** a pull request is opened
- **THEN** the suite runs and its result gates the merge

### Requirement: End-to-end smoke test

Continuous integration SHALL create a project from the templates, build it, start it, and verify its health endpoint, so that a broken template is caught before release.

#### Scenario: Smoke test succeeds

- **WHEN** the smoke job creates a project, builds the images and starts the stack
- **THEN** the application health endpoint returns success within the configured timeout

#### Scenario: Broken template caught

- **WHEN** a template change makes the generated Go module fail to compile
- **THEN** the smoke job fails at the build step

#### Scenario: Environment cleaned up

- **WHEN** the smoke job finishes, whether it passed or failed
- **THEN** the created project, containers, volumes and network are removed

### Requirement: Pre-commit hook and CI agree

The pre-commit hook SHALL run a fast subset of the same checks CI enforces, and SHALL NOT enforce a rule that CI does not. Its checks SHALL remain overridable for local work in progress.

#### Scenario: Hook and CI consistency

- **WHEN** a commit passes the pre-commit hook
- **THEN** it does not fail CI on a check the hook claims to cover

#### Scenario: Hook stays fast

- **WHEN** the hook runs on a typical staged change set
- **THEN** it completes within the budget agreed in the design

#### Scenario: Override available

- **WHEN** a developer commits with the documented override
- **THEN** the commit proceeds and CI remains the authority
