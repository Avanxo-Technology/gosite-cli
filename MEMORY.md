# Project Memory

## BEFORE EVERY COMMIT — Checklist

1. **Version bump** — If anything user-facing changed, bump `GOSITE_VERSION` in `src/main.sh`
2. **Website sync** — If CLI commands/flags changed, update `docs/index.html` (commands table) and `README.md` (usage section)
3. **Generated structure** — If file paths in the scaffold changed, update `docs/index.html` (folder tree), `README.md`, and the generated `MEMORY.md`/`ARCHITECTURE.md` templates in `cmd_create.sh`

If you skip any of these, the docs, the website, and the installed binary will be out of sync.

## Scaffold Structure

Go app lives in `cmd/server/` (entry point) + `internal/` (packages). Cockpit addons in `cockpit/addons/`. Dockerfiles in `deploy/`. This is the standard layout for all scaffolded projects.
