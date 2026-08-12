# gosite

> **⚠️ Experimental** — This project is in active development and is not
> recommended for production use. If you choose to use it in production, you do
> so at your own risk.

A modular Bash CLI that manages local development environments and produces
Coolify-ready production files for a high-performance monolith:

**Go 1.25+ (Echo v5) + htmx + Alpine.js + Cockpit CMS**, Tailwind optional, with
**Redis cache-aside** in front of the CMS. Server-side HTML uses the standard
library's `html/template` - no code generation, no build step.

## Architecture

| Layer | Scope | Contents |
| --- | --- | --- |
| Shared infrastructure | One per machine | Traefik proxy + Redis on the `gosite-network` Docker network |
| Per project | One per site | Its own Go app container (air hot reload) + its own Cockpit container |

Projects never define Redis. They attach to `gosite-network` as an **external**
network and reach it by container name (`gosite-redis`) on its in-network port.
Cockpit uses its file-backed database locally, so development needs no database
container at all; production brings its own MongoDB.

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
gosite infra up               # gosite-network + Traefik and Redis
gosite create my-site         # scaffold ~/gosites/my-site + issue its TLS cert
gosite start my-site          # app (air hot reload) + Cockpit
                              # -> https://my-site.test, https://cms.my-site.test
gosite logs my-site           # follow the logs
gosite list                   # projects, ports, container status, paths
gosite open my-site           # open in Finder (macOS)
gosite restart my-site         # recreate containers (--build to rebuild)
gosite stop my-site
gosite remove my-site          # deletes containers, cert and the directory
gosite sync my-site            # re-apply gosite's templates to an existing project
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

### Styling

Tailwind CSS is included by default, loaded from a CDN so local development
needs no build step. `--no-tailwind` swaps it for a small `static/styles.css`:

```bash
gosite create my-site                 # Tailwind utility classes
gosite create my-site --no-tailwind   # semantic classes + static/styles.css
```

The generated markup differs between the two on purpose. With Tailwind the
components carry utility classes; without it they carry semantic class names
(`panel`, `page-header`, `button`) styled by a stylesheet that uses custom
properties and supports dark mode. Neither mode leaves classes that do nothing,
so the output is clean either way. The choice is recorded in `.gosite.env`.

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

### Asset storage

Asset uploads can live in an S3-compatible bucket instead of on disk. By
default each project uses local storage (`STORAGE_ADAPTER=local`); the shared
infrastructure runs a `MinIO` service, and the CMS image ships Cockpit's
Flysystem S3 adapter, so switching environments is one variable:

```bash
# .env (dev) — already points at the shared gosite-minio
STORAGE_ADAPTER=s3
S3_URL=http://gosite-minio:9000
S3_BUCKET=assets
S3_REGION=us-east-1
S3_KEY=minioadmin
S3_SECRET=minioadmin
S3_PUBLIC_URL=https://minio.test/assets   # browser-reachable base for asset URLs

# production (Coolify dashboard) — any S3-compatible provider
STORAGE_ADAPTER=s3
S3_URL=https://s3.us-east-1.amazonaws.com   # or Backblaze, etc.; leave unset for AWS virtual-hosted
S3_BUCKET=my-site-assets
S3_REGION=us-east-1
S3_KEY=AKIA...
S3_SECRET=...
S3_PUBLIC_URL=https://cdn.example.com/my-assets
```

With `S3_PUBLIC_URL` set, CMS assets (including generated thumbnails, served
from `uploads://thumbs`) load directly from the bucket, CDN-style. Templates
render them through the `assetURL` helper registered by
`internal/views/render.go` — `{{assetURL (index .Content "field_name")}}` —
which resolves against `S3_PUBLIC_URL` when S3 is on and against the local
`/storage/uploads` proxy otherwise, so markup never needs a fallback.

MinIO is routed through the shared Traefik proxy like the projects: the S3 API
at `https://minio.test` and the console at `https://minio-console.test` (both
with the mkcert certificate, so the browser trusts them). Plain-HTTP fallbacks
stay on ports `9002`/`9003`. It starts with the shared infrastructure via
`gosite infra up`. Set `STORAGE_ADAPTER=local` (or leave it unset) to keep files
in `cockpit-storage/uploads` as before — backward compatible.

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

### AI context files

Every project ships a `MEMORY.md` and an `ARCHITECTURE.md`, written for an
assistant reading the repo cold. `MEMORY.md` is short: what the project is, its
URLs and cache key, the reading order, and the rules that are easy to get wrong
(Echo v5 is not v4; every route lives in `router.go`; the page is cached, so
purge after changing it; no build step). `ARCHITECTURE.md` is the reference
behind it — the v4-to-v5 API differences, the caching helper, the Cockpit
endpoints and how to update content, htmx/Alpine conventions, the `gosite`
commands, environment variables and the Coolify deploy.

Both are generated with the project's real values filled in — module path,
domains, ports, cache key — so nothing in them is a placeholder to correct.

### Removing a project

`gosite remove <name>` removes the project entirely: containers, volumes, local
images, its TLS certificate, its registry entry and its directory. It always
asks for confirmation first (skip with `-y`).

```bash
gosite remove my-site                # everything, including the code
gosite remove my-site --keep-source  # tear down the stack, keep the directory
```

### Syncing templates into an existing project

The templates that `create` writes are single-sourced: the compose files, the
Cockpit config and the build files (`deploy/Dockerfile*`, `.air.toml`,
`.dockerignore`) live in `src/lib/templates.sh`, and every addon ships in
`src/addons/`. `gosite sync` re-applies those same sources to a project that
already exists, without touching your work — it reads the project's
`.gosite.env` marker, so it always renders the exact values the project was
created with. This is how an existing site picks up gosite updates.

```bash
gosite sync my-site              # compose + config.php + build files + addons + .env keys
gosite sync my-site --compose    # re-render docker-compose(.prod).yml, config.php, deploy/ build files
gosite sync my-site --addons     # refresh addons present, or --addons "Forms Replica"
gosite sync my-site --env        # add keys missing from .env (never overwrites)
gosite sync my-site --build      # ...then rebuild the local images
gosite sync --list-addons        # show the addon library
```

`.env` merging only appends keys that the template has and the project lacks;
existing values — including `COCKPIT_SEC_KEY` — are never overwritten. After an
addon sync, Cockpit's module cache is cleared so the refreshed addons register
on the next boot.

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
    │   ├── templates.sh          # shared template writers (compose, env, addons) for create + sync
    │   └── tls.sh                # mkcert certificates + *.test DNS checks
    └── commands/
        ├── cmd_create.sh         # project scaffolding (Go, templates, Docker, compose)
        ├── cmd_sync.sh           # re-apply gosite's templates to an existing project
        ├── cmd_infra.sh          # shared Traefik + Redis lifecycle
        ├── cmd_dns.sh            # verify *.test resolution, print the fix
        ├── cmd_start.sh          # bring a project up with air hot reload
        ├── cmd_stop.sh           # stop a project's containers
        ├── cmd_restart.sh        # recreate containers (--build)
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
├── go.mod / go.sum
├── config/                   # environment settings, read exactly once
├── handlers/                 # one file per route
│   ├── handlers.go           # deps + the receiver they hang off
│   ├── response.go           # how this app replies (thin layer over Echo)
│   ├── home.go               # GET /
│   ├── purge.go              # POST /cache/purge
│   └── health.go             # GET /healthz
├── cache/                    # cache-aside over Redis, written once
├── cms/                      # the Cockpit API client
├── cockpit/config.php        # points Cockpit at MongoDB (production only)
├── views/                    # markup, embedded with go:embed
│   ├── render.go             # parses every template at startup
│   ├── layout.html           # base document (styles, htmx, Alpine)
│   ├── pages/home.html       # one file per page
│   └── components/           # reusable pieces, one per file
│       └── button.html
├── static/
├── .air.toml                 # hot reload: rebuild on .go/.html changes
├── Dockerfile                # PROD multi-stage: static binary -> alpine
├── Dockerfile.dev            # LOCAL: toolchain + air, source bind-mounted
├── docker-compose.yml        # LOCAL: mapped ports, external gosite-network
├── docker-compose.prod.yml   # COOLIFY: no host ports, Traefik labels, env-driven
├── .env / .env.example
├── .gosite.env               # project marker read by list/start/stop/remove
├── MEMORY.md                 # AI entry point: facts, rules, common tasks
├── ARCHITECTURE.md           # the reference MEMORY.md points at
├── Makefile, README.md, .gitignore, .dockerignore
```

### Layout

One file per responsibility, read in the order `main.go` -> `app.go` ->
`router.go` -> `handlers/`. Handlers live in their own package, one file per
route, so that file never becomes a dumping ground as the app grows.
`router.go` is the single source of truth for the HTTP surface: nothing
registers routes anywhere else. Data flows one way - `cms` fetches from the
Cockpit API, a handler hands that to `views`, and the rendered HTML goes into
`cache`.

The example is deliberately one page with no data model: `cms.Content` is a
map, so a template reads `{{.Content.headline}}` with nothing to define up
front, and a field the CMS has not supplied falls back to copy in the template.
Add a struct in `cms` once the shape of your content settles. Adding an endpoint is one file in `handlers/` and one
line in `router.go`; adding a page is one template in `views/pages/`.

Handlers reply through a small `Response` helper - a thin layer over [Echo's
response helpers](https://echo.labstack.com/guide/response/) that adds the
`X-Cache` header and, in `Fail`, logs the real error while returning only a
message safe to show a client.

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
| Redis | 8-alpine | `GOSITE_REDIS_VERSION` |
| Cockpit | core-2.14.0 | edit the compose files |

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
