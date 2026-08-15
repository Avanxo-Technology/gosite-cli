# Project Memory

## BEFORE EVERY COMMIT — Checklist

1. **Version bump** — If anything user-facing changed, bump `VERSION` in `src/VERSION`
2. **Website sync** — If CLI commands/flags changed, update `docs/index.html` (commands table) and `README.md` (usage section)
3. **Generated structure** — If file paths in the scaffold changed, update `docs/index.html` (folder tree), `README.md`, and the generated `MEMORY.md`/`ARCHITECTURE.md` templates in `cmd_create.sh`

If you skip any of these, the docs, the website, and the installed binary will be out of sync.

The pre-commit hook in `.githooks/pre-commit` enforces rule 1 automatically —
it rejects commits that change source files without bumping `src/VERSION`.

To activate the hook: `git config core.hooksPath .githooks`

## Knowledge Base

Reusable Cockpit CMS knowledge lives in `src/knowledge/`. When you discover a
non-obvious behaviour or a change that must be re-applied after container rebuilds,
add a file there so it is available to every project.

## Current scaffold defaults (do not regress)

- **Database**: content models + entries go to the shared MongoDB
  (`content.models.storage = database`). No local `storage/content/*.model.php`
  files.
- **Memory**: CMS app memory goes to the infra Redis (DB 1, per-project prefix)
  via the `memory` config. No local `app.memory.sqlite`.
- **Uploads**: `STORAGE_ADAPTER=s3` is the create default (MinIO). Local disk is
  opt-in (`--storage local`).
- **`gosite create`** prompts for addons, uploads storage (`--storage s3|local`)
  and database (`--database mongodb|local`). `-y` accepts defaults; the DB
  choice is recorded as `GOSITE_DATABASE` in the `.gosite.env` marker so `sync`
  preserves it.
- **Mongo URI in the app**: `buildMongoURI()` builds from components and only
  includes `user:pass` when both `MONGO_USER`/`MONGO_PASSWORD` are set; a set
  `MONGO_URI` wins.
- **Infra**: MinIO runs native TLS (mkcert certs mounted; Traefik backends
  `scheme=https` + `insecureskipverify`). `gosite infra up` self-heals a proxy
  that lost the shared network.

## Scaffold Structure

Go app lives in `cmd/server/` (entry point) + `internal/` (packages). Cockpit addons in `cockpit/addons/`. Dockerfiles in `deploy/`. This is the standard layout for all scaffolded projects.
