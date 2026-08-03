# gosite

A modular Bash CLI that manages local development environments and produces
Coolify-ready production files for a high-performance monolith:

**Go 1.22+ (Echo) + htmx + Alpine.js + Templ + Cockpit CMS**, with **Redis
cache-aside** in front of the CMS.

## Architecture

| Layer | Scope | Contents |
| --- | --- | --- |
| Shared infrastructure | One per machine | PostgreSQL + Redis on the `gosite-network` Docker network |
| Per project | One per site | Its own Go app container (air hot reload) + its own Cockpit container |

Projects never define Postgres or Redis. They attach to `gosite-network` as an
**external** network and reach the shared services by container name
(`gosite-postgres`, `gosite-redis`) on their in-network ports.

## Install

One line, straight from GitHub — installs per user into `~/.local`, no sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/Avanxo-Technology/gosite-cli/main/install.sh | bash
```

Or from a clone:

```bash
git clone git@github.com:Avanxo-Technology/gosite-cli.git
cd gosite-cli && ./install.sh
```

Then check the toolchain:

```bash
gosite doctor
```

### Install modes

| Command | Modules | Binary | sudo |
| --- | --- | --- | --- |
| `./install.sh` (default) | `~/.local/share/gosite` | `~/.local/bin/gosite` | no |
| `./install.sh --system` | `/usr/local/share/gosite` | `/usr/local/bin/gosite` | yes |

Either way the installer copies `src/` into the share directory and symlinks
`<share>/gosite/src/main.sh` to `<bin>/gosite` (`chmod +x`), so `gosite` runs
from any directory. `main.sh` resolves the symlink chain to find its own
modules. If the bin directory is not on your `PATH`, the installer prints the
exact line to add to your shell profile.

When piped from `curl` the script has no `src/` beside it, so it downloads the
repository tarball to a temp directory and installs from there — you never need
`curl | sudo bash`.

### Install options

| Variable / flag | Default | Purpose |
| --- | --- | --- |
| `--system` / `--user` | `--user` | Machine-wide vs per-user install |
| `GOSITE_PREFIX` | `~/.local` or `/usr/local` | Custom install prefix |
| `GOSITE_REF` | `main` | Install a branch or release tag |
| `GOSITE_REPO` | `Avanxo-Technology/gosite-cli` | Install from a fork |

```bash
# pin a release tag
curl -fsSL https://raw.githubusercontent.com/Avanxo-Technology/gosite-cli/main/install.sh | GOSITE_REF=v0.1.0 bash

# machine-wide
curl -fsSL https://raw.githubusercontent.com/Avanxo-Technology/gosite-cli/main/install.sh | bash -s -- --system
```

**Update**: re-run the install command; it replaces the installed modules in
place. **Uninstall**: `rm -rf ~/.local/share/gosite ~/.local/bin/gosite`
(prefix `sudo` and use `/usr/local` for a system install).

## Usage

```bash
gosite doctor                 # verify go, templ, air, docker, docker compose
gosite infra up               # create gosite-network + shared Postgres/Redis
gosite create my-site         # scaffold ./my-site
gosite start my-site          # app (air hot reload) + Cockpit
gosite logs my-site           # follow the logs
gosite list                   # projects, ports, container status, paths
gosite stop my-site
gosite remove my-site [--purge]
gosite infra down
```

Every project command takes an optional project name. Omit it to act on the
project in the current directory; pass it to act on any project from anywhere.

### Logs

```bash
gosite logs                   # current project, app + cms, follows
gosite logs my-site app       # only the Go container
gosite logs my-site cms -n 50 # last 50 lines of Cockpit
gosite logs my-site --no-follow
```

### Jumping into a project

A child process cannot change its parent shell's directory, so `gosite cd`
needs a small shell function. Enable it once:

```bash
echo 'eval "$(gosite shell-init)"' >> ~/.zshrc   # or ~/.bashrc
```

```bash
gosite cd my-site             # jumps into the project directory
gosite path my-site           # prints the absolute path (scriptable)
```

Without the shell integration, `gosite cd` explains the setup and prints the
path; `cd "$(gosite path my-site)"` always works.

### Project registry

Projects are indexed in `~/.gosite/projects.tsv` (`<name>\t<path>`) when they
are created or started, which is how `cd`, `logs`, `start`, `stop` and `remove`
resolve a project by name from any directory. The index is self-healing:
entries whose directory no longer exists are dropped on read, and `gosite list`
picks up any unindexed project below the current directory (a fresh clone, for
example).

## Repository layout

```
gosite-cli/
├── install.sh                    # installer: remote bootstrap, copy, symlink
├── README.md
└── src/
    ├── main.sh                   # global entrypoint: symlink resolution, colors, flags
    ├── dispatcher.sh             # command router (case statement), usage text
    ├── lib/
    │   ├── config.sh             # network, ports, registry, service names (env-overridable)
    │   └── helpers.sh            # logging, validation, registry, docker helpers, dep checks
    └── commands/
        ├── cmd_create.sh         # project scaffolding (Go, Templ, Docker, compose, env)
        ├── cmd_infra.sh          # shared Postgres + Redis lifecycle
        ├── cmd_start.sh          # bring a project up with air hot reload
        ├── cmd_stop.sh           # stop a project's containers
        ├── cmd_logs.sh           # tail project logs (app/cms, follow, tail size)
        ├── cmd_cd.sh             # cd/path/shell-init - jump into a project
        ├── cmd_remove.sh         # full teardown (+ optional --purge of the source)
        └── cmd_list.sh           # project inventory and status
```

## What `gosite create <name>` generates

```
my-site/
├── main.go                   # Echo + go-redis v9 cache-aside (10m TTL) + Templ
├── go.mod / go.sum
├── templates/
│   ├── index.templ           # Layout + Index (hx-get, x-data) + ArticleList fragment
│   └── models.go             # Article type shared with main
├── static/
├── .air.toml                 # hot reload: templ generate + rebuild on .go/.templ
├── Dockerfile                # PROD multi-stage: templ generate -> static binary -> alpine
├── Dockerfile.dev            # LOCAL: toolchain + air, source bind-mounted
├── docker-compose.yml        # LOCAL: mapped ports, external gosite-network
├── docker-compose.prod.yml   # COOLIFY: no host ports, Traefik labels, env-driven
├── .env / .env.example
├── .gosite.env               # project marker read by list/start/stop/remove
├── Makefile, README.md, .gitignore, .dockerignore
```

### Strict environment separation

| | `docker-compose.yml` (local) | `docker-compose.prod.yml` (Coolify) |
| --- | --- | --- |
| Build | `Dockerfile.dev` (air) | `Dockerfile` (multi-stage, static binary on alpine) |
| Ports | mapped to localhost | none — Traefik routes by label |
| Source | bind-mounted, hot reload | baked into the image |
| Config | `.env` file | env vars set in the Coolify UI |
| Datastores | shared `gosite-network` containers | `REDIS_URL` / `DATABASE_URL` from Coolify |

### Cache-aside flow

`GET /articulos` (htmx target) reads `<project>:articles:v1` from Redis.
On a hit it decodes and renders in microseconds; on a miss it queries Cockpit,
`SET`s the JSON with a 10-minute TTL, and renders the same Templ component.
Redis failures are never fatal — the CMS is queried directly, just slower.
The `X-Cache` header reports `HIT`/`MISS`. `POST /cache/purge` (guarded by
`X-Api-Key: $COCKPIT_API_TOKEN`) lets Cockpit invalidate on publish.

Measured on the generated project: **MISS 406ms → HIT 328µs**.
