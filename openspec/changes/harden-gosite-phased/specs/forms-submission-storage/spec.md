## ADDED Requirements

### Requirement: Submission queries do not scale with collection size

Listing the known forms, deriving a form's columns and counting submissions SHALL be answered by database-side aggregation rather than by iterating documents in PHP. No code path SHALL load an unbounded page of submissions into memory to compute a summary.

#### Scenario: Form list with a large collection

- **WHEN** the submissions collection holds far more documents than any page size and the admin screen requests the form list
- **THEN** the counts are computed by aggregation
- **AND** the number of documents transferred to PHP does not grow with the collection size

#### Scenario: Counts are accurate

- **WHEN** a form has a known number of submissions
- **THEN** the reported count equals that number, with no page-size ceiling

#### Scenario: Column derivation is bounded

- **WHEN** the screen derives the column set for a form
- **THEN** it inspects a bounded, documented sample
- **AND** the sample size is stated in the interface

#### Scenario: Forms with settings but no submissions

- **WHEN** a form is configured but has never received a submission
- **THEN** it appears in the list with a count of zero

### Requirement: Personal data in submissions has a retention policy

The IP address and user agent recorded with each submission SHALL be subject to a configurable retention period, after which they are cleared while the submission itself is retained. Storing them at all SHALL be configurable.

#### Scenario: Retention period elapses

- **WHEN** a submission is older than the configured retention period and the maintenance path runs
- **THEN** its `ip` and `userAgent` fields are cleared
- **AND** the rest of the submission is preserved

#### Scenario: Collection disabled

- **WHEN** personal-data collection is disabled in the configuration
- **THEN** new submissions are stored with empty `ip` and `userAgent`
- **AND** rate limiting still functions

#### Scenario: Retention disabled

- **WHEN** the retention period is configured as unlimited
- **THEN** no field is cleared
- **AND** the audit reports that submissions retain personal data indefinitely

#### Scenario: Default is documented

- **WHEN** a project is scaffolded
- **THEN** its configuration carries an explicit retention value with a comment explaining it
