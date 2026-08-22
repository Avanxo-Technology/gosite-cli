## ADDED Requirements

### Requirement: Generated project sources live as real files

The Go, YAML, PHP and Markdown content that gosite writes into a new project SHALL be stored as versioned files under `src/templates/`, carrying their true file extensions, rather than embedded in shell heredocs.

Rendering SHALL consist of copying a template tree and substituting `__PLACEHOLDER__` tokens, with no shell interpretation of the template content.

#### Scenario: Template files are real sources

- **WHEN** the template for the application entrypoint is inspected
- **THEN** it is a `.go` file that `gofmt` can parse

#### Scenario: Rendering a project

- **WHEN** `gosite create` renders the template tree for a project
- **THEN** every `__PLACEHOLDER__` token is replaced with the project's resolved value
- **AND** the produced tree is identical to what the previous heredoc implementation produced, modulo the intended fixes of this change

#### Scenario: Unresolved placeholder is caught

- **WHEN** a rendered file still contains a `__PLACEHOLDER__` token after substitution
- **THEN** creation fails naming the file and the token

#### Scenario: Template content is inert

- **WHEN** a template file contains shell metacharacters, backticks or `$` sequences
- **THEN** they are written through literally

#### Scenario: Single source for create and sync

- **WHEN** both `gosite create` and `gosite sync` render the same managed file for the same inputs
- **THEN** the result is byte-identical

### Requirement: Templates are verifiable in isolation

The template tree SHALL be checkable without creating a project: its Go files SHALL be formattable and vettable, and its YAML and PHP SHALL be parseable, after substituting a fixture set of placeholder values.

#### Scenario: Formatting check

- **WHEN** the fixture-rendered Go templates are checked with `gofmt -l`
- **THEN** no file is listed

#### Scenario: Static analysis

- **WHEN** the fixture-rendered Go module is vetted
- **THEN** `go vet` reports no findings

#### Scenario: Configuration parsing

- **WHEN** the fixture-rendered compose files are parsed as YAML and the Cockpit configuration is linted with `php -l`
- **THEN** both succeed
