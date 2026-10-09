## MODIFIED Requirements

### Requirement: gosite create generates a thin site
`gosite create` SHALL generate `main.go`, `site/`, `theme/` (layout, pages, partials for the chosen flavor), `static/`, `gosite.yml`, a `go.mod` requiring the core module at the CLI's matching version, and the agent context files `AGENTS.md` and `CLAUDE.md`, and SHALL NOT copy core Go packages or gosite's Cockpit addons into the project, nor write a `MEMORY.md`.

#### Scenario: Fresh site builds and runs
- **WHEN** a user runs `gosite create demo -y` and `gosite start demo`
- **THEN** the site builds, serves the home page from the CMS, and its tree has no `internal/cms`, `internal/cache` or `cockpit/addons/Blog`

#### Scenario: Existing CLI options preserved
- **WHEN** a user passes `--storage`, `--database`, `--addons` or `--no-addons`
- **THEN** the choices are written to `gosite.yml` with the same meaning they have today

#### Scenario: Agent context files present
- **WHEN** a user runs `gosite create demo -y`
- **THEN** `AGENTS.md` and `CLAUDE.md` exist, and `MEMORY.md` and `.claude/skills/` do not
