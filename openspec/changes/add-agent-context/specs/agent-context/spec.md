## ADDED Requirements

### Requirement: AGENTS.md is the single instruction file
This repository and every site that `gosite create` generates SHALL have an `AGENTS.md` at the root holding the project's agent rules and layout, and SHALL NOT have a `MEMORY.md`.

#### Scenario: New thin site
- **WHEN** a user runs `gosite create demo -y`
- **THEN** `demo/AGENTS.md` exists with the project name and domains filled in, and `demo/MEMORY.md` does not exist

#### Scenario: New legacy site
- **WHEN** a user runs `gosite create demo --legacy -y`
- **THEN** `demo/AGENTS.md` exists, contains the flavor-specific section, and `demo/MEMORY.md` does not exist

### Requirement: CLAUDE.md imports AGENTS.md
Every `AGENTS.md` SHALL have a `CLAUDE.md` next to it whose first line is `@AGENTS.md` and whose remaining content covers only Claude Code-specific tools.

#### Scenario: Claude Code loads the rules
- **WHEN** Claude Code starts in a generated site
- **THEN** the content of `AGENTS.md` is part of its loaded context through the import

#### Scenario: No duplicated rules
- **WHEN** a rule appears in `AGENTS.md`
- **THEN** it does not also appear in `CLAUDE.md`

### Requirement: Instruction file size budget
`AGENTS.md` SHALL stay under 120 lines in this repository and under 80 lines in a generated site, and SHALL point to longer documents instead of including them.

#### Scenario: Budget enforced by test
- **WHEN** the test suite runs
- **THEN** it fails if the repository `AGENTS.md` or a freshly generated site's `AGENTS.md` exceeds its line budget

### Requirement: Search exclusions
The repository `AGENTS.md` SHALL name the paths agents must not search unless the task is about them, including `services/medusa/node_modules` and `CHANGELOG.md`, and SHALL NOT carry a per-note knowledge index.

#### Scenario: Exclusions present, no index
- **WHEN** the test suite runs
- **THEN** the repository `AGENTS.md` names `services/medusa/node_modules` and `CHANGELOG.md`, and has no table row per knowledge note

### Requirement: No skills shipped
This repository and generated sites SHALL NOT ship gosite skills under `.claude/skills/` or `.opencode/skills/`; knowledge is read on demand with `gosite docs`.

#### Scenario: New site has no gosite skills
- **WHEN** a user runs `gosite create demo -y`
- **THEN** `demo/.claude/skills/` does not exist

### Requirement: Project rules in AGENTS.md
The repository `AGENTS.md` SHALL state the rules on prompt injection found in files, verifying by executing in a sandbox, never running commands against real infrastructure or real sites, checking where each setting comes from on local and production, no tombstone comments or tests, the language rule (chat replies and PR titles, descriptions and comments MAY be in Spanish; code, comments, docs, instruction files, OpenSpec files and commit messages SHALL be in English), and PR proof.

#### Scenario: Rules present
- **WHEN** a reviewer reads the repository `AGENTS.md`
- **THEN** each listed rule appears once, in one or two lines

#### Scenario: Spanish PR, English change
- **WHEN** an agent opens a PR for a change
- **THEN** the PR title and description may be in Spanish, and every changed file and commit message is in English

### Requirement: PR proof
Pull requests in this repository SHALL include proof in a Proof section of the PR template: text proof inside a collapsible `<details>` block, and images or videos attached with `gh pr create|edit|comment --attach '<file>#<caption>'`.

#### Scenario: Agent with an older gh
- **WHEN** the local `gh` is older than 2.99.0
- **THEN** the PR body lists each media file and the exact `gh pr comment <n> --attach` command for the user to run

#### Scenario: Text proof
- **WHEN** the proof is command output
- **THEN** it is in a `<details>` block in the PR body or a comment, not an image
