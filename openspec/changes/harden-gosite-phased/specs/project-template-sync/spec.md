## ADDED Requirements

### Requirement: Production compose is never written without explicit force

`gosite sync` SHALL treat `docker-compose.prod.yml` as owned by the project, not by gosite. No sync mode, including the default no-flag invocation and `--compose`, SHALL write that file.

Overwriting it SHALL require the explicit `gosite sync --compose-prod --force` invocation, which SHALL first copy the existing file to a timestamped backup beside it.

#### Scenario: Default sync

- **WHEN** `gosite sync` runs on a project whose production compose differs from the current template
- **THEN** `docker-compose.prod.yml` is left byte-for-byte unchanged
- **AND** the drift is reported

#### Scenario: Compose sync flag

- **WHEN** `gosite sync --compose` runs
- **THEN** the development compose and the Cockpit config are re-rendered
- **AND** `docker-compose.prod.yml` is still left unchanged

#### Scenario: Explicit forced overwrite

- **WHEN** `gosite sync --compose-prod --force` runs
- **THEN** the existing file is copied to `docker-compose.prod.yml.<timestamp>.bak`
- **AND** the file is re-rendered from the current template
- **AND** the backup path is printed

#### Scenario: Force without the compose-prod flag

- **WHEN** `gosite sync --force` runs without `--compose-prod`
- **THEN** the production compose is still not written

### Requirement: Drift reporting

`gosite sync --report` SHALL describe how a project diverges from the current templates without writing anything to the project.

For each managed file the report SHALL classify it as identical, drifted, or missing, and for the production compose it SHALL additionally list the keys the template would add, the keys whose values differ, and the keys present only in the project.

#### Scenario: Report is read-only

- **WHEN** `gosite sync --report` runs
- **THEN** no file inside the project is created, modified or deleted

#### Scenario: Project matching the templates

- **WHEN** every managed file matches what the current templates would render
- **THEN** the report states the project is up to date
- **AND** the command exits zero

#### Scenario: Drifted production compose

- **WHEN** the production compose lacks a key the template introduces and carries a service the template does not define
- **THEN** the report lists the missing key as an addition and the extra service as project-local
- **AND** it prints the exact command that would apply the change

#### Scenario: Report exit status signals drift

- **WHEN** any managed file has drifted and `--report` is combined with a strictness flag
- **THEN** the command exits non-zero, so it can gate a pipeline

### Requirement: Addons and base scaffolding refresh safely

`gosite sync` SHALL refresh the Cockpit addon library and the base scaffolding of an existing project. Before overwriting any file, it SHALL detect whether that file was modified locally relative to the version gosite last wrote, and SHALL preserve local modifications unless forced.

Gosite SHALL record a manifest of the files it manages, with their content hashes at write time, inside the project.

#### Scenario: Unmodified managed file

- **WHEN** an addon file matches the hash gosite recorded when it wrote it
- **THEN** the file is replaced with the current version without prompting

#### Scenario: Locally modified managed file

- **WHEN** an addon file differs from the recorded hash
- **THEN** the file is left in place
- **AND** it is reported as locally modified with the command to override

#### Scenario: New addon requested

- **WHEN** `gosite sync --addons "Forms"` runs on a project without that addon
- **THEN** the addon is installed
- **AND** its files are added to the manifest

#### Scenario: Project predating the manifest

- **WHEN** a project has no manifest because it was created before this change
- **THEN** a manifest is generated from the current file contents
- **AND** no file is overwritten during that first run

#### Scenario: Removed managed file

- **WHEN** a file gosite previously wrote no longer exists in the project
- **THEN** it is restored from the template
