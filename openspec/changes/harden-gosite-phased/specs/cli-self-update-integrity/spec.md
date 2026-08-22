## ADDED Requirements

### Requirement: Self-update verifies what it installs

`gosite update` SHALL verify the integrity of the downloaded archive against a checksum published by the release before replacing any installed file. Verification failure SHALL abort the update with the installation untouched.

#### Scenario: Checksum matches

- **WHEN** the downloaded archive's digest equals the published checksum
- **THEN** the update proceeds

#### Scenario: Checksum mismatch

- **WHEN** the digest differs from the published checksum
- **THEN** the update aborts with an error naming both digests
- **AND** the installed files are left untouched

#### Scenario: Checksum unavailable

- **WHEN** no checksum can be retrieved for the requested reference
- **THEN** the update aborts
- **AND** the error explains that `--allow-unverified` is required to proceed anyway

#### Scenario: Explicit opt-out

- **WHEN** the operator passes `--allow-unverified`
- **THEN** the update proceeds after printing a prominent warning

### Requirement: Update source is not environment-controlled

The repository `gosite update` downloads from SHALL be fixed in the source. It SHALL NOT be overridable through an environment variable. Redirecting the update to another repository SHALL require an explicit command-line flag.

#### Scenario: Environment variable ignored

- **WHEN** `GOSITE_REPO` is set in the environment and `gosite update` runs
- **THEN** the update downloads from the built-in repository
- **AND** the ignored variable is reported

#### Scenario: Explicit repository override

- **WHEN** the operator passes `--repo <owner>/<name>`
- **THEN** that repository is used
- **AND** the non-default source is named in the confirmation prompt

### Requirement: Failed updates leave a working installation

The installed tree SHALL only be replaced once the new version has been staged and verified. If replacement fails partway, the previous installation SHALL be restored.

#### Scenario: Replacement fails midway

- **WHEN** copying the new files fails after the old tree was removed
- **THEN** the previous version is restored from the staged backup
- **AND** the error reports that the installation was rolled back

#### Scenario: New version fails to run

- **WHEN** the replaced binary cannot execute `gosite version`
- **THEN** the previous version is restored
- **AND** the update reports failure

#### Scenario: Successful update cleans up

- **WHEN** the update completes and the new version runs
- **THEN** the staged backup and temporary files are removed
