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
| Shared infrastructure | One per machine | Traefik proxy + Redis + MongoDB + MinIO on the `gosite-network` Docker network |
| Per project | One per site | Its own Go app container (air hot reload) + its own Cockpit container |

Projects never define Redis, MongoDB or MinIO. They attach to
`gosite-network` as an **external** network and reach the shared services by
container name (`gosite-redis`, `gosite-mongo`, `gosite-minio`) on their
in-network ports. Cockpit stores its content models and entries in MongoDB and
its app memory on the infra Redis (DB 1), so nothing project-wide is written to
local files; production brings its own MongoDB and Redis inside the compose
stack.

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
gosite doctor                 # toolchain check + security audit of projects & infra (--strict fails on findings)
gosite infra up               # gosite-network + Traefik and Redis
gosite create my-site         # scaffold ~/gosites/my-site + issue its TLS cert
gosite start my-site          # app (air hot reload) + Cockpit
                              # -> https://my-site.test, https://cms.my-site.test
gosite logs my-site           # follow the logs
gosite list                   # projects, ports, container status, paths (--prune cleans the registry)
gosite open my-site           # open in Finder (macOS)
gosite restart my-site         # recreate containers (--build to rebuild)
gosite stop my-site
gosite remove my-site          # deletes containers, cert and the directory
gosite sync my-site            # re-apply gosite's templates to an existing project
gosite addons add Blog my-site # install an addon into a project that already exists
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

Every project includes a CSS reset ([`@aprinciple/modern-reset`](https://github.com/aprinciple/modern-reset))
via CDN. Tailwind CSS is offered as an interactive prompt during creation
(enabled by default, answer **n** for plain CSS):

```bash
gosite create my-site                 # Tailwind utility classes
gosite create my-site --no-tailwind   # semantic classes + static/styles.css
```

`gosite create` also asks two questions (both answerable with a flag to skip the
prompt): where uploaded assets live (`--storage s3|local`, default **s3** /
MinIO) and where content lives (`--database mongodb|local`, default
**mongodb** / the shared infra). Everything else defaults automatically, and
`-y/--yes` accepts all defaults.

```bash
gosite create my-site                      # prompts; defaults: tailwind + s3 + mongodb
gosite create my-site --no-tailwind        # plain CSS
gosite create my-site --storage local      # uploads on disk, no MinIO
gosite create my-site --database local     # self-contained mongolite storage
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
# .env (dev) — already points at the shared gosite-minio (native TLS)
STORAGE_ADAPTER=s3
S3_URL=https://gosite-minio:9000
S3_BUCKET=assets
S3_REGION=us-east-1
S3_KEY=minioadmin
S3_SECRET=minioadmin
S3_VERIFY=false                    # local MinIO uses a self-signed mkcert cert
S3_PUBLIC_URL=https://minio.test/assets   # browser-reachable base for asset URLs

# production (Coolify dashboard) — any S3-compatible provider
STORAGE_ADAPTER=s3
S3_URL=https://s3.us-east-1.amazonaws.com   # or Backblaze, etc.; leave unset for AWS virtual-hosted
S3_BUCKET=my-site-assets
S3_REGION=us-east-1
S3_KEY=AKIA...
S3_SECRET=...
S3_VERIFY=true                     # only set false for self-signed endpoints
S3_PUBLIC_URL=https://cdn.example.com/my-assets
```

With `S3_PUBLIC_URL` set, CMS assets (including generated thumbnails, served
from `uploads://thumbs`) load directly from the bucket, CDN-style. Templates
render them through the `assetURL` helper registered by
`internal/views/render.go` — `{{assetURL (index .Content "field_name")}}` —
which resolves against `S3_PUBLIC_URL` when S3 is on and against the local
`/storage/uploads` proxy otherwise, so markup never needs a fallback.

MinIO serves **native TLS**: `gosite infra up` issues an mkcert certificate
(covering the container hostname, `minio.test`, `minio-console.test` and
`localhost`) and mounts it into the container, so CMS-to-MinIO traffic is HTTPS
too. It is also routed through the shared Traefik proxy like the projects: S3
API at `https://minio.test`, console at `https://minio-console.test` (the same
certificate, so the browser trusts them). Plain-HTTP fallbacks stay on ports
`9002`/`9003`. Because the mkcert cert is not in the CMS container's trust
store, local projects set `S3_VERIFY=false`. It all starts with
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

The templates that `create` writes are single-sourced: every generated file
(compose files, Cockpit config, build files, the Go application, docs) is a
real file under `src/templates/`, and every addon ships in `src/addons/`.
`gosite sync` re-renders those same sources into a project that already
exists, without touching your work — it reads the project's `.gosite.env`
marker, so it always renders the exact values the project was created with.
This is how an existing site picks up gosite updates.

```bash
gosite sync my-site              # compose + config.php + build files + addons + .env keys
gosite sync my-site --compose    # re-render docker-compose.yml, config.php, deploy/ build files
gosite sync my-site --addons     # refresh addons present, or --addons "Forms Blog Analytics Replica"
gosite sync my-site --app        # bring internal/ and static/ up to the current templates
gosite sync my-site --env        # add keys missing from .env (never overwrites)
gosite sync my-site --report     # drift report: nothing is written
gosite sync my-site --report --strict   # ...exit non-zero when there is drift (CI gate)
gosite sync my-site --compose-prod --force  # the ONLY way docker-compose.prod.yml is rewritten
gosite sync my-site --build      # ...then rebuild the local images
```

`--app` is the one mode that touches your application sources (`internal/`, `static/`), which is why it is opt-in.
The manifest guard still decides file by file: scaffolding you never opened is
refreshed, anything you edited is preserved and reported. A project scaffolded
long ago needs it before it can take an addon that ships application pages.

### SEO and the Webapp addon

Every project ships one built-in addon, `Webapp`. It owns the site-wide
defaults that have to exist before a site has any content, and it absorbs the
infrastructure that used to live in six separate addons (asset uploads, model
CRUD, S3 storage, asset path normalisation, cache purging, starter content).

Two content models drive it, both created on first admin load:

- **`webapp`** (singleton) — favicon, site name, site URL, language, default
  title, description and image, author, publisher and logo, X/Twitter handle,
  `robots.txt`, `llms.txt` and JSON-LD.
- **`seoPages`** (collection) — the same fields per path, plus `canonical`
  and `noIndex`. A path here overrides the defaults for that page only.

The application turns them into the document head and four routes:

| Route | Source |
| --- | --- |
| `/robots.txt` | the `robotsTxt` field, verbatim |
| `/llms.txt` | the `llmText` field, verbatim |
| `/favicon.ico` | redirect to the favicon asset |
| `/sitemap.xml` | `seoPages` minus `noIndex`, plus what mounted features contribute |

Both `canonical` and `sitemap.xml` need **Site URL** set in the singleton, and
neither falls back to the request host: behind a proxy or on a preview domain
that would publish the wrong origin, so the tag is omitted and the route 404s
until an editor fills the field in. Leave JSON-LD empty and the app emits a
minimal `WebSite` block built from the other defaults; write your own and it is
used untouched.

### Addons in an existing project

Adding an addon to a project made months ago has its own command, so it does
not mean remembering that `sync` has a flag for it:

```bash
gosite addons list my-site        # the library, and what this project has
gosite addons add Blog my-site    # install: CMS half + application pages
gosite addons remove Blog my-site # uninstall (content in the database is kept)
```

Installing only ever **adds** files. An addon that ships application pages
wires itself from a file of its own, so your `router.go` is never rewritten,
and a page template you have edited is preserved and reported rather than
overwritten (`--force` takes the template version).

Addons are baked into the CMS image, and an addon with application pages is
compiled into the app binary, so both have to be rebuilt — restarting shows
neither:

```bash
gosite restart my-site --build
```

Two guarantees make sync safe to run blindly:

- **`docker-compose.prod.yml` is yours.** No sync mode ever writes it — that
  file carries your production overrides (extra services, replicas,
  healthchecks), so sync only reports its drift, structurally, with `yq`
  (normalized textual diff without it). The single exception is the explicit
  `--compose-prod --force` above, which first copies the current file to a
  timestamped `.bak` beside it and prints the backup path.
- **Hand-edited files are preserved.** Every file gosite writes is recorded
  in the project's `.gosite/manifest.tsv` with its hash at write time. On
  sync, a file that still matches its recorded hash is refreshed from the
  current template; one that differs was edited by hand, so it is kept and
  reported (re-apply with `--force`). Files that vanished are restored.
  Projects created before the manifest existed adopt one from their current
  contents on the first sync — that first pass writes nothing but the
  manifest itself and shows the drift report instead.

`.env` merging only appends keys that the template has and the project lacks;
existing values — including `COCKPIT_SEC_KEY` — are never overwritten. After an
addon sync, Cockpit's module cache is cleared so the refreshed addons register
on the next boot.

### Project registry

Projects are indexed in `~/.gosite/projects.tsv` (`<name>\t<path>`) when they
are created or started, which is how `cd`, `logs`, `start`, `stop` and `remove`
resolve a project by name from any directory. Reading the index never
rewrites it: entries whose directory no longer exists are reported as
`unavailable` (by `gosite list` and `gosite doctor`) and stay in the file
until you prune them explicitly with `gosite list --prune`. `gosite list`
also picks up any unindexed project below the current directory (a fresh
clone, for example).

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
    │   ├── helpers.sh            # logging, validation, registry, locking, ports, dep checks
    │   ├── templates.sh          # placeholder substitution + template-tree renderer (create + sync)
    │   ├── manifest.sh           # per-project manifest of gosite-managed files (drift detection)
    │   └── tls.sh                # mkcert certificates + *.test DNS checks
    ├── templates/                # the project sources as REAL files (design D8):
    │   ├── cmd/server/main.go    #   rendered by copy + literal __PLACEHOLDER__ substitution
    │   ├── internal/...          #   (Go app, views, compose, Dockerfiles, docs)
    │   ├── dotenv                #   becomes .env; named so no .gitignore can hide it
    │   ├── addons/blog/          #   application half of an addon, overlaid on opt-in
    │   └── flavors/{tailwind,plain}/  # styling variants, overlaid per project
    └── commands/
        ├── cmd_create.sh         # project scaffolding from the template tree
        ├── cmd_sync.sh           # re-apply templates safely (manifest guard, drift report)
        ├── cmd_addons.sh         # install/remove addons in an existing project
        ├── cmd_infra.sh          # shared Traefik + Redis lifecycle
        ├── cmd_dns.sh            # verify *.test resolution, print the fix
        ├── cmd_start.sh          # bring a project up with air hot reload
        ├── cmd_stop.sh           # stop a project's containers
        ├── cmd_restart.sh        # recreate containers (--build)
        ├── cmd_logs.sh           # tail project logs (app/cms, follow, tail size)
        ├── cmd_cd.sh             # cd/path/shell-init - jump into a project
        ├── cmd_remove.sh         # full teardown incl. the source (--keep-source opts out)
        ├── cmd_list.sh           # project inventory and status (--prune cleans the registry)
        └── cmd_doctor.sh         # toolchain check + read-only security audit (--strict)
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
│   ├── health.go             # GET /healthz
│   ├── robots.go             # GET /robots.txt      (from the webapp singleton)
│   ├── llms.go               # GET /llms.txt        (from the webapp singleton)
│   ├── favicon.go            # GET /favicon.ico     (redirect to the asset)
│   └── sitemap.go            # GET /sitemap.xml     (built at request time)
├── seo/                      # resolves meta tags: defaults -> seoPages -> page
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

## Security posture

`gosite doctor --strict` audits every project and the shared infrastructure
against the secure defaults and exits non-zero on findings — run it in CI or
before a deploy. The invariants it checks (and that gosite enforces by
default): purge endpoint fail-closed without a token, Forms rate limiting
with correct client identity behind the proxy, CORS fail-closed, shared
datastores bound to loopback, personal-data retention bounded.

### Accepted risks

Two operator secrets are stored in plaintext inside the CMS database, and
that is an accepted trade-off rather than an oversight:

- **Replica** keeps peer API keys in its target configuration, and **Forms**
  keeps each form's `webhookSecret` in the `formSettings` collection. Anyone
  with database access already has the content these secrets protect, so
  encrypting them would only add a key-management problem, not protection.
  Both are masked in admin output. The compensating control is the loopback
  binding of the datastores above: keep the database unreachable from the
  network and the plaintext storage stays an internal detail.
