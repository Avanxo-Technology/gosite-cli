# gosite

A modular Bash CLI that manages local development environments and produces
Coolify-ready production files for a high-performance monolith:

**Go 1.25+ (Echo v5) + htmx + Alpine.js + Tailwind + Cockpit CMS**, with
**Redis cache-aside** in front of the CMS. Server-side HTML uses the standard
library's `html/template` - no code generation, no build step.

## Architecture

| Layer | Scope | Contents |
| --- | --- | --- |
| Shared infrastructure | One per machine | Traefik proxy + PostgreSQL + Redis on the `gosite-network` Docker network |
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
gosite doctor                 # verify go, air, docker, docker compose
gosite infra up               # gosite-network + Traefik, Postgres, Redis
gosite create my-site         # scaffold ~/gosites/my-site + issue its TLS cert
gosite start my-site          # app (air hot reload) + Cockpit
                              # -> https://my-site.test, https://cms.my-site.test
gosite logs my-site           # follow the logs
gosite list                   # projects, ports, container status, paths
gosite stop my-site
gosite remove my-site          # deletes containers, cert and the directory
gosite infra down
```

Every project command takes an optional project name. Omit it to act on the
project in the current directory; pass it to act on any project from anywhere.

### Workspace

Sites are created under `~/gosites` regardless of the current directory, so
they stay in one place instead of scattered across the filesystem. Override the
location with `GOSITE_WORKSPACE`, or pass `--here` to scaffold into the current
directory for a one-off:

```bash
gosite create my-site                        # -> ~/gosites/my-site
GOSITE_WORKSPACE=~/work gosite create other  # -> ~/work/other
gosite create scratch --here                 # -> ./scratch
```

### Local domains over HTTPS

Every project is served at `https://<name>.test` with its Cockpit at
`https://cms.<name>.test`, through the shared Traefik proxy. Certificates are
issued by [mkcert](https://github.com/FiloSottile/mkcert), whose CA the system
trusts, so browsers show a valid padlock with no warnings. Port 80 redirects
to 443. The mapped `localhost:<port>` stays available as a fallback.

Requirements (checked by `gosite infra status` and `gosite dns`):

```bash
brew install mkcert && mkcert -install      # trusted local CA

brew install dnsmasq                        # wildcard DNS for *.test
echo 'address=/.test/127.0.0.1' >> "$(brew --prefix)/etc/dnsmasq.conf"
sudo brew services restart dnsmasq
sudo mkdir -p /etc/resolver
echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/test
```

```bash
gosite dns          # verify *.test resolves to 127.0.0.1
```

The wildcard is what makes this zero-config per project: a new site works the
moment it starts, with no `/etc/hosts` edits. Each project gets one certificate
covering `<name>.test` and `*.<name>.test` — a wildcard matches a single label,
so a shared `*.test` certificate could not cover `cms.<name>.test`.

Traefik reads certificates from a watched directory, so adding a project never
restarts the proxy. Its dashboard is at `https://proxy.test`.

Traefik excludes containers whose health check is still `starting`, so a
freshly started Cockpit returns 404 through the proxy for a few seconds before
its route appears. That is expected — it avoids routing to a service that is
not ready yet.

Because dev now routes by Traefik labels exactly like `docker-compose.prod.yml`
does under Coolify, local and production differ only in hostnames and TLS
source.

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

### Removing a project

`gosite remove <name>` removes the project entirely: containers, volumes, local
images, its TLS certificate, its registry entry and its directory. It always
asks for confirmation first (skip with `-y`).

```bash
gosite remove my-site                # everything, including the code
gosite remove my-site --keep-source  # tear down the stack, keep the directory
```

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
    │   ├── config.sh             # workspace, network, ports, domains (env-overridable)
    │   ├── helpers.sh            # logging, validation, registry, docker helpers, dep checks
    │   └── tls.sh                # mkcert certificates + *.test DNS checks
    └── commands/
        ├── cmd_create.sh         # project scaffolding (Go, templates, Docker, compose)
        ├── cmd_infra.sh          # shared Traefik + Postgres + Redis lifecycle
        ├── cmd_dns.sh            # verify *.test resolution, print the fix
        ├── cmd_start.sh          # bring a project up with air hot reload
        ├── cmd_stop.sh           # stop a project's containers
        ├── cmd_logs.sh           # tail project logs (app/cms, follow, tail size)
        ├── cmd_cd.sh             # cd/path/shell-init - jump into a project
        ├── cmd_remove.sh         # full teardown incl. the source (--keep-source opts out)
        └── cmd_list.sh           # project inventory and status
```

## What `gosite create <name>` generates

```
my-site/
├── main.go                   # startup: config, dependencies, server
├── app.go                    # Config + App: every dependency, built once
├── router.go                 # every route and middleware, one screen
├── handlers.go               # what each route does
├── cache.go                  # cache-aside over Redis, written once
├── cms.go                    # the Cockpit API client
├── go.mod / go.sum
├── models/                   # data shapes: no Redis, no HTTP, no HTML
│   └── article.go
├── views/                    # markup, embedded with go:embed
│   ├── render.go             # parses every template at startup
│   ├── layout.html           # base document (Tailwind, htmx, Alpine)
│   ├── pages/home.html       # one file per page
│   └── components/           # reusable pieces, one per file
│       ├── card.html
│       ├── button.html
│       └── state.html
├── static/
├── .air.toml                 # hot reload: rebuild on .go/.html changes
├── Dockerfile                # PROD multi-stage: static binary -> alpine
├── Dockerfile.dev            # LOCAL: toolchain + air, source bind-mounted
├── docker-compose.yml        # LOCAL: mapped ports, external gosite-network
├── docker-compose.prod.yml   # COOLIFY: no host ports, Traefik labels, env-driven
├── .env / .env.example
├── .gosite.env               # project marker read by list/start/stop/remove
├── Makefile, README.md, .gitignore, .dockerignore
```

### Layout

One file per responsibility, read in the order `main.go` -> `app.go` ->
`router.go` -> `handlers.go`. `router.go` is the single source of truth for the
HTTP surface: nothing registers routes anywhere else. Data flows one way -
`cms.go` fetches from the Cockpit API into `models`, the handler hands those to
`views`, and the rendered HTML goes into the cache. Adding a page is one
template in `views/pages/`, one handler and one line in `router.go`.

The example ships two routes, `/` and `POST /cache/purge`, which is enough to
show the whole pattern without any code to delete.

### Pinned versions

Everything the generated project and the shared infra depend on is pinned and
overridable, so an upgrade is a deliberate change rather than a surprise:

| Component | Version | Override |
| --- | --- | --- |
| Echo | v5.3.1 (needs Go 1.25+) | edit `go.mod` |
| go-redis | v9.22.0 | edit `go.mod` |
| htmx / Alpine.js / Tailwind | 2.0.10 / 3.15.12 / 4.3.3 | edit `views/layout.html` |
| air | v1.67.4 | edit `Dockerfile.dev` |
| Traefik | v3.7 | `GOSITE_TRAEFIK_VERSION` |
| PostgreSQL | 18-alpine | `GOSITE_PG_VERSION` |
| Redis | 8-alpine | `GOSITE_REDIS_VERSION` |
| Cockpit | core-2.14.0 | edit the compose files |

`gosite infra up` refuses to start Postgres when the data volume was written by
a different major version, and prints the dump/restore steps instead of leaving
a container in a restart loop.

### Cache-aside flow

`GET /` reads `<project>:index_html` from Redis. The cached value is the fully
rendered page, so a hit skips the CMS call and the template render entirely; on
a miss it queries the Cockpit API, renders into a buffer, and `SET`s those exact
bytes with a 10-minute TTL. The mechanics live in one `Cache.HTML(key, render)`
helper, so caching another page is a single call rather than another copy of
the same Get/Set dance.
Redis failures are never fatal — the page still renders, just slower.
The `X-Cache` header reports `HIT`/`MISS`. `POST /cache/purge` (guarded by
`X-Api-Key: $COCKPIT_API_TOKEN`) lets Cockpit invalidate on publish.

Measured on the generated project: **cache hit 111µs vs 5.2ms miss**.
