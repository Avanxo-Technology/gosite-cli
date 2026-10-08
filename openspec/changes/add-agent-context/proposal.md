## Why

Agent sessions (Claude Code, OpenCode, omp) spend most of their tokens rebuilding context that gosite already has written down. No repository — neither this one nor any generated site — has an instruction file that the tools load automatically: `MEMORY.md` is loaded by none of them. The Cockpit and Medusa knowledge notes in `src/knowledge/` exist only in this repository, so an agent working in a site reads core source, the module cache or 19 KB of `ARCHITECTURE.md` to answer questions those notes already answer. In this repository, `find`/`grep` through the shell walk the 698 MB `services/medusa/node_modules`.

## What Changes

- **BREAKING (context files only):** `MEMORY.md` is renamed to `AGENTS.md` in this repository, in both scaffolds (`src/templates-thin/scaffold/`, `src/templates/`) and in the flavor parts. No runtime behaviour changes.
- Add a `CLAUDE.md` shim next to every `AGENTS.md`: one `@AGENTS.md` import plus a short section for Claude Code-only tools (subagents, cross-session messaging, scratchpad).
- Add project rules to `AGENTS.md`: prompt-injection handling, verify by executing in a sandbox, never run commands against real infra or real sites, setting-source check (local vs production), no tombstone comments or tests, language (chat replies and PR text may be Spanish; every change, including commit messages, is English), PR proof.
- Add a new command `gosite docs [topic]` that lists or prints the notes in `src/knowledge/` of the installed CLI. It works the same in thin and legacy sites.
- Add a PR template with a proof section: text proof in a collapsible block, images and videos through `gh … --attach` (gh ≥ 2.99.0).
- Track `AGENTS.md`, `CLAUDE.md`, `.claude/skills/` and `.opencode/commands/` in this repository (the root `.gitignore` ignores everything not whitelisted).
- Add a `MIGRATIONS.md` entry that moves an existing site to the new context files, and roll it out to every site after release.

- No knowledge index and no skills in the context loaded on every turn: measured on 2026-10-08, they made agents dig deeper and raised token use (see `baseline.md` and design.md D9). The notes stay reachable on demand through `gosite docs`.

## Capabilities

### New Capabilities
- `agent-context`: the instruction files (`AGENTS.md`, `CLAUDE.md`) that this repository and every generated site ship, their size budget, and the rules they carry.
- `knowledge-docs`: the `gosite docs` command — listing and printing knowledge notes for agents and people, in thin and legacy sites.

### Modified Capabilities
- `thin-scaffold`: the scaffold writes `AGENTS.md` and `CLAUDE.md` instead of `MEMORY.md`.

## Impact

- `src/commands/` — new `cmd_docs.sh`; `src/dispatcher.sh` (command and help); `cmd_create.sh`, `src/lib/templates.sh`, `tools/extract_templates.py` (MEMORY.md → AGENTS.md).
- Templates: `src/templates-thin/scaffold/`, `src/templates/`, `src/templates/flavors/*/MEMORY.md.part`.
- Repository root: `AGENTS.md` (from `MEMORY.md`), `CLAUDE.md`, `.claude/skills/`, `.github/pull_request_template.md`, `.gitignore`.
- Docs: `README.md`, `docs/index.html`, `MIGRATIONS.md`, `CHANGELOG.md`, `src/VERSION` (0.57.0).
- Tests: bats tests for `gosite docs` and for the files a new site gets.
- Sites: aga-growth-dev, aldu-dev, avanxo-dev, ba-pow, gmaq-dev, gremco-dev, lnequipos-v2, soyarnold-dev — one scoped PR each after release. The sandboxes analytics-draft and analytics-draft-v2 are used for verification first.
- Outside the repo (user level, not part of the release): personal style rules in `~/.config/opencode/AGENTS.md`, imported by `~/.claude/CLAUDE.md`.
