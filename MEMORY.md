# Project Memory

## Before every commit

1. **Version** — bump `src/VERSION` for any user-facing change.
2. **Docs** — CLI commands/flags changed → update `docs/index.html` (commands table) and `README.md` (usage).
3. **Scaffold paths** — file layout changed → update `docs/index.html` (folder tree), `README.md`, and the `MEMORY.md`/`ARCHITECTURE.md` templates in `cmd_create.sh`.

Skipping these desyncs the docs, the website and the installed binary.
`.githooks/pre-commit` enforces rule 1 (activate: `git config core.hooksPath .githooks`).

## Knowledge base

Reusable Cockpit CMS knowledge lives in `src/knowledge/`. Non-obvious behaviour, or
anything that must be re-applied after a container rebuild, goes there so every
project gets it.

## Scaffold defaults (do not regress)

- **Database**: models + entries in the shared MongoDB (`content.models.storage = database`); no local `storage/content/*.model.php`.
- **Memory**: CMS app memory in infra Redis (DB 1, per-project prefix) via `memory`; no `app.memory.sqlite`.
- **Uploads**: `STORAGE_ADAPTER=s3` (MinIO) by default; local disk is opt-in (`--storage local`).
- **`gosite create`**: prompts for addons, `--storage s3|local`, `--database mongodb|local`; `-y` takes defaults. The DB choice is recorded as `GOSITE_DATABASE` in `.gosite.env` so `sync` preserves it.
- **Mongo URI**: `buildMongoURI()` builds from components, adding `user:pass` only when both `MONGO_USER`/`MONGO_PASSWORD` are set; an explicit `MONGO_URI` wins.
- **Infra**: MinIO runs native TLS (mkcert certs mounted; Traefik backends `scheme=https` + `insecureskipverify`). `gosite infra up` self-heals a proxy that lost the shared network.

## Structure

Go app: `cmd/server/` (entry) + `internal/` (packages). Cockpit addons in `cockpit/addons/`, Dockerfiles in `deploy/`. Standard for all scaffolded projects.
