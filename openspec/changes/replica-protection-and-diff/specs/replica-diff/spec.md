## ADDED Requirements

### Requirement: Diff classifies every entry in five states
`replica:diff <target> [model]` and the admin Compare view SHALL compare the local and remote entries of each model in scope and SHALL put each entry in exactly one state: `only-here`, `newer-here`, `newer-there`, `only-there` or `same`. The diff SHALL write nothing on either side.

#### Scenario: Entry created locally
- **WHEN** an entry exists locally and not on the target
- **THEN** the diff lists it as `only-here`

#### Scenario: Entry deleted locally
- **WHEN** an entry exists on the target and not locally
- **THEN** the diff lists it as `only-there`

#### Scenario: Identical entries
- **WHEN** an entry has the same content on both sides
- **THEN** the diff lists it as `same`

#### Scenario: Nothing is written
- **WHEN** a diff runs against a target
- **THEN** no entry, definition, id map pair or asset changes on either side, and the log records the diff as read-only

### Requirement: Content decides sameness, timestamps decide direction
Two entries SHALL be `same` when the hashes of their normalised content are equal, whatever their timestamps. When the hashes differ, a peer target SHALL use `_modified` to choose `newer-here` or `newer-there`. A core target SHALL report the difference as `newer-here` with a note that the remote stamps its own timestamps.

#### Scenario: Re-saved without changes
- **WHEN** an entry was saved again locally with no field changed, so only `_modified` differs
- **THEN** the diff lists it as `same`

#### Scenario: Remote edited later on a peer
- **WHEN** a field differs and the remote `_modified` is newer
- **THEN** the diff lists it as `newer-there`

#### Scenario: Key order differs
- **WHEN** both sides hold the same fields in a different key order
- **THEN** the diff lists the entry as `same`

### Requirement: Core targets are matched through the id map
For a core target the diff SHALL match a local entry to its remote entry through the id map, and SHALL say that unpublished remote entries cannot be seen.

#### Scenario: Mapped entry
- **WHEN** a local entry has an id map pair to a remote entry with equal content
- **THEN** the diff lists it as `same`

### Requirement: Protected models are shown, not compared as writable
The diff SHALL mark a model that is protected on the destination as protected, and SHALL not offer its entries for a push.

#### Scenario: Protected destination model
- **WHEN** the destination protects `seoPages`
- **THEN** the diff shows `seoPages` as protected and the Compare view offers no push for it

### Requirement: Push a selection of entries
`replica:push <target> <model> --ids=<id,...>` and the Compare view SHALL send only the selected entries of one model, with the same mode, dry-run, id map and protection rules as a full push. An id that does not exist locally SHALL be reported and SHALL not stop the others.

#### Scenario: Two entries pushed
- **WHEN** a user runs `replica:push staging posts --ids=a1,b2`
- **THEN** only entries `a1` and `b2` of `posts` are sent, and the result counts only those two

#### Scenario: Unknown id
- **WHEN** `--ids` contains an id that is not in the local model
- **THEN** the result reports `unknown id <id>` and the other ids are still pushed

#### Scenario: Ids without a model
- **WHEN** a user passes `--ids` without a model argument
- **THEN** the command fails with a message that `--ids` needs a model

### Requirement: The dry-run plan reports identical entries
The dry-run plan SHALL use the diff's sameness rule and report identical entries as `same` instead of `would update`.

#### Scenario: Dry run over unchanged content
- **WHEN** a dry-run push runs and nothing changed since the last push
- **THEN** every entry is reported as `same` and the plan shows zero updates
