## ADDED Requirements

### Requirement: gosite docs lists knowledge topics
`gosite docs` with no argument SHALL print one line per note in the installed CLI's `src/knowledge/`: the topic (file name without `.md`) and the note's first heading.

#### Scenario: List topics
- **WHEN** a user runs `gosite docs`
- **THEN** the output has one line per knowledge note, sorted by topic, and the exit code is 0

### Requirement: gosite docs prints one topic
`gosite docs <topic>` SHALL print the note's content unchanged to standard output, and for an unknown topic SHALL print an error and the topic list to standard error and exit with a non-zero code.

#### Scenario: Known topic
- **WHEN** a user runs `gosite docs medusa-admin-api`
- **THEN** the output is byte-identical to `src/knowledge/medusa-admin-api.md`

#### Scenario: Unknown topic
- **WHEN** a user runs `gosite docs nope`
- **THEN** stderr names the unknown topic and lists the valid ones, and the exit code is non-zero

### Requirement: gosite docs works in thin and legacy sites
`gosite docs` SHALL work from any directory, including thin and legacy sites, without a Go toolchain or network access, and SHALL NOT start, stop or modify containers or files.

#### Scenario: Legacy site
- **WHEN** a user runs `gosite docs` inside a legacy site
- **THEN** it prints the same topic list as anywhere else

### Requirement: Version mismatch is visible
When run inside a site whose recorded gosite or core version differs from the CLI's version, `gosite docs <topic>` SHALL print one line to standard error naming both versions before the note.

#### Scenario: Site behind the CLI
- **WHEN** a thin site's `gosite.yml` records core `0.54.0` and the CLI is `0.57.0`
- **THEN** stderr shows one line naming both versions, and stdout is the note unchanged
