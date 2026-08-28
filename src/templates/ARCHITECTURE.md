# __PROJECT__ - architecture

Reference for humans and AI assistants working on this project. `MEMORY.md` is
the short version; this file is the detail behind it.

## Stack

| Layer | Choice | Why |
| --- | --- | --- |
| HTTP | Echo v5 | Small, fast, standard-library shaped |
| Markup | `html/template` | Standard library, no code generation |
| Interactivity | htmx + Alpine.js | HTML over the wire; no SPA, no build step |
| CMS | Cockpit | Headless, editors get an admin UI |
| Cache | Redis | Keeps the CMS off the request path |
| Deploy | Docker + Coolify | Same compose format locally and in production |

## Layout

```
cmd/server/          Entry point (package main).
  main.go            Startup: read config, build the app, start the server.
  app.go             Composition root: build every dependency once.
  router.go          Every route and middleware. The whole HTTP surface.
internal/            Application packages (not importable by external code).
  config/            Environment settings, read exactly once.
  handlers/          One file per route.
    handlers.go      Deps + the receiver the handlers hang off.
    response.go      How this app replies.
    home.go          GET /
    purge.go         POST /cache/purge
    health.go        GET /healthz
  cache/             Cache-aside over Redis, written once.
  cms/               The Cockpit API client. The only package that calls the CMS.
  views/             Markup, embedded with go:embed.
    render.go        Parses every template at startup.
    layout.html      Base document.
    pages/           One file per page.
    components/      Reusable pieces, one per file.
  app/               App struct, NewApp, NewRouter (wiring).
cockpit/             Cockpit CMS configuration.
  config.php         Production config (baked into Dockerfile.cms).
  addons/            Cockpit addons (four built-ins + optional Forms/Replica).
deploy/              Dockerfiles for production, dev, and CMS images.
static/              Assets served at /static.
.gosite/             Bookkeeping written by the CLI, not by you.
  manifest.tsv       Hash of every file gosite wrote, so an upgrade can tell
                     an untouched file from one you hand-edited.
```

Dependency direction is one way: `internal/config` <- `internal/cache`/
`internal/cms` <- `internal/handlers` <- `internal/app` <- `cmd/server/main`.
Views import nothing from the app. Keep it that way: it is what stops markup
changes from breaking the cache and vice versa.

## Echo v5

v5 is not v4. The differences that bite:

| v4 | v5 |
| --- | --- |
| `func(c echo.Context) error` (interface) | `func(c *echo.Context) error` (struct pointer) |
| `c.Response()` returns `*echo.Response` | returns `http.ResponseWriter` |
| `echo.NewHTTPError(code, any...)` | `echo.NewHTTPError(code, string)` |
| `e.Shutdown(ctx)` | removed - `Start` handles signals and graceful shutdown |
| `middleware.Logger()` | `middleware.RequestLogger()` |
| Go 1.22 | Go 1.25 minimum |

Startup uses `echo.StartConfig{GracefulTimeout: ...}.Start(ctx, e)`, which
stops accepting connections when the context is cancelled and drains in-flight
requests. Do not add a manual shutdown.

Response helpers: https://echo.labstack.com/guide/response/

## Responses

Handlers reply through the helper in `internal/handlers/response.go`:

```go
return h.reply(c).Page(html, cached)                      // HTML + X-Cache header
return h.reply(c).Text(http.StatusOK, "purged")           // plain text
return h.reply(c).JSON(http.StatusOK, payload)            // JSON
return h.reply(c).Fail(http.StatusBadGateway, "...", err) // logs err, returns a safe message
```

`Fail` logs the real error with the request path and returns only the public
message, so internal detail never reaches a client. It is a thin layer over
Echo's own helpers - they still do the writing.

## Caching

`GET /` is served from Redis under `__PROJECT__:home_html` with a 10 minute
TTL. The cached value is the **fully rendered page**, so a hit skips the CMS
call and the template execution entirely.

The mechanics live in `internal/cache/cache.go` as one helper:

```go
html, cached, err := h.Cache.HTML(ctx, key, func() ([]byte, error) {
    // only runs on a miss
})
```

Cache another page by calling it with a different key. Do not reimplement
Get/Set in a handler.

Concurrent misses of the same key are coalesced with single-flight: exactly one
render runs and the others wait and share its bytes, so an expired or purged
key under load never becomes a stampede against Cockpit. The `SET` is issued
with a background context, so the caller that happened to trigger the render
disconnecting does not stop the cache from being warmed for everyone else.

`POST /cache/purge` re-renders the page in the background before it responds,
so the next request after an editor publishes finds a warm cache rather than
paying for the cold path.

The `X-Cache` response header reports `HIT` or `MISS` - check it before
concluding a change did not work:

```bash
curl -sD- -o /dev/null https://__DOMAIN__/ | grep -i x-cache
```

A Redis failure is never fatal: the page still renders, just slower.

### Purging

```bash
curl -X POST -H "X-Api-Key: $COCKPIT_API_TOKEN" https://__DOMAIN__/cache/purge
```

The button on the page does the same thing over htmx. Outside development the
endpoint fails closed: without `COCKPIT_API_TOKEN` configured it answers **503**
(a warning is logged at startup naming the variable), with a wrong token it
answers 401 - so set the token in production or purging stays off. Point a
Cockpit publish webhook at this URL so editors do not wait out the TTL.

## Cockpit CMS

The admin is at https://__CMS_DOMAIN__.

Locally Cockpit connects to the shared MongoDB container (`__MONGO_HOST__`), the
same way it connects to the shared Redis - no per-project database container is
needed. In production `cockpit/config.php` is baked in and points Cockpit at
the MongoDB service in the compose stack. Uploads and cache stay on the
`cockpit-storage` volume; content moves into MongoDB.

### Data model

Content is stored in MongoDB as documents. Singletons and collections are
defined in the Cockpit admin UI at https://__CMS_DOMAIN__/settings/blueprints.
`cms/cms.go` fetches them via the REST API:

```go
content := h.CMS.Singleton(ctx, "home") // GET /api/content/item/home
```

When the schema changes (new fields, new collections, new singletons), the
change happens in the database - no migration file or code change is needed
unless the template needs to render the new data. Add a fallback in the
template until the content exists:

```
{{with .Content.new_field}}{{.}}{{else}}default{{end}}
```

| Kind | Endpoint |
| --- | --- |
| Singleton | `/api/content/item/<name>` |
| Collection | `/api/content/items/<name>` |

Both authenticate with an `api-key` header, set from `COCKPIT_API_TOKEN`.

`cms.Content` is a `map[string]any`, so a template can read
`{{.Content.headline}}` without a struct existing. Once a model settles, define
a struct in `cms` and decode into it.

When Cockpit is unreachable or the item does not exist, the client returns
empty content and logs a warning; the template falls back to its own copy. That
is why a fresh project renders before any content exists.

### Updating content

1. Open https://__CMS_DOMAIN__ and sign in.
2. Create or edit the item (a `home` singleton with `headline` and `intro`
   fields drives the starter page).
3. Purge the cache, or wait up to 10 minutes.

To add a field: add it in Cockpit, then read it in the template with a fallback
(`{{with .Content.field}}{{.}}{{else}}default{{end}}`).

### Addons

The CMS container mounts `cockpit/addons/` into `/var/www/html/addons`, which
Cockpit core loads as first-class modules (bootstrap.php includes it in
`modulesPaths`). Every scaffold ships with three built-in addons and, when opted
in at scaffold time, two optional ones. All of them come from gosite's addon
library (`src/addons/`), so `gosite addons add` pulls newer versions into an
existing project.

#### Built-ins (always installed)

- **AssetsUpload** - `POST /api/assets/upload` (multipart, `api-key` header,
  optional `folder` field). REST upload for the CMS; mirrors the admin
  uploader. See `src/addons/AssetsUpload/bootstrap.php`.
- **ModelManager** - content-model CRUD over the REST API:
  `GET /api/models` (list), `POST /api/models/save` (`model` body with `name`
  + `type` = collection/singleton/tree), `POST /api/models/remove` (`name`
  body). ACL-guarded (`content/:models/manage`). The app uses it to create or
  evolve content schemas without the admin UI. See
  `src/addons/ModelManager/bootstrap.php`.
- **CloudStorage** - S3/S3-compatible storage for assets, active only when
  `STORAGE_ADAPTER=s3` (MinIO in dev; AWS S3 / R2 / Backblaze in prod).
  Config lives in the `cloudStorage` block of `cockpit/config.php` and follows
  the Cockpit Pro shape. Generated thumbnails are served from `uploads://thumbs`
  so they stay browser-reachable; the local `#uploads` mount is deliberately
  NOT redirected to S3 because core's thumbnail pipeline
  (`makeAssetLocalAvailable()`) copies to and re-reads from that disk mount,
  and redirecting it 404s every thumbnail. See
  `src/addons/CloudStorage/bootstrap.php`.

All three authenticate with the same `api-key` header (`$COCKPIT_API_TOKEN`)
as the content API.

#### Optional (opt-in)

- **Forms** - public `POST /forms/api/submit` receiver (anti-spam honeypot +
  rate limit), per-form admin screen, CSV export, mail/webhook notifications.
  Its behaviour is configured in the `forms` block of `cockpit/config.php`; see
  below, because three of those settings deny requests by default.
- **Replica** - content sync between Cockpit instances: targets, push/pull,
  mirror/merge, dry runs, CLI, activity log.

Grant `forms/manage` and `replica/manage` in Settings > Roles after first login.

##### Forms configuration

```php
'forms' => [
    'trustedProxies'          => 1,
    'personal_data_retention' => 7776000,  // 90 days
    'collect_personal_data'   => true,
    // 'allowed_origins'      => ['https://www.example.com'],
],
```

**`allowed_origins` is unset, so cross-origin submissions are blocked.** This is
the first thing to check when a form posted from another domain fails: the
browser reports a CORS error and nothing reaches the CMS. List your site's
origin(s) here. `['*']` opens the receiver to every origin and has to be written
out explicitly - it is never the default.

**`trustedProxies` is the number of reverse-proxy hops in front of the CMS**, and
every gosite project has exactly one (Traefik). The rate limiter takes the client
address that many entries from the **right** of `X-Forwarded-For`, never the
leftmost one, which any client can forge. Set it to `0` only for a deployment
with no proxy at all. Get this wrong and every visitor shares one rate-limit
bucket, so one bot locks out every real lead.

**The rate limit fails closed.** If the memory backend (Redis) cannot be reached,
a submission is rejected with **503** and a `Retry-After` header - not 429, which
would claim a limit was hit. Setting both `throttle` and `dailyLimit` to `0` for
a form disables the limit outright and skips the backend entirely; that is the
supported way to choose availability over abuse control.

**`ip` and `userAgent` are personal data.** They are cleared once a submission
passes `personal_data_retention`, and setting `collect_personal_data` to `false`
stops storing them at all (rate limiting keeps working). Retention is enforced by
a maintenance run, not by a background timer - schedule it, or the value above is
a stated policy rather than an applied one.

**API key role binding:** the Cockpit API key (`COCKPIT_API_TOKEN` in `.env`)
must be bound to a role with `replica/manage` and content read permissions. The
Replica addon's `GET /api/replica/manifest` returns 403 without this, falling
back to transport=core (entries only, no assets or models). Assign the token to
the `api` role (or a custom role with those permissions), not "No role".

#### Serving CMS assets

`internal/views/render.go` registers an `assetURL` helper:
`{{assetURL (index .Content "field_name")}}`. It takes the Cockpit asset object
(a map with a `path`) and returns a browser-reachable URL based on
`config.AssetBaseURL` (`S3_PUBLIC_URL` when `STORAGE_ADAPTER=s3`, otherwise the
local `/storage/uploads` proxy that router.go serves). An unfilled field renders
as an empty string, so markup never depends on a fallback copy. `toJSON` is also
available for feeding a value to Alpine `x-data` (it returns a string, which
`html/template` escapes safely in the attribute).

#### Managing addons

Addons are plain directories, so an addon is added by dropping its folder into
`cockpit/addons/` or running `gosite addons add <name>` and recreating the
CMS container.
In non-debug mode Cockpit caches the module list in
`storage/cache/modules.cache.php`; `gosite addons add` clears it, and the container
must restart because opcache holds the compiled bootstrap.

## htmx and Alpine

- **htmx** issues the requests: `hx-get`, `hx-post`, `hx-target`, `hx-swap`.
  A handler answers with an HTML **fragment**, not JSON.
- **Alpine** handles local UI state only: `x-data`, `x-show`, `x-text`,
  `@click`. Use `x-cloak` on anything that would flash before Alpine loads.
- Both are CDN `<script>` tags in `internal/views/layout.html`. Vendor them into
  `/static` before production so the site does not depend on a third party and
  a CSP can be tightened.

Rule of thumb: if the server can render it, let the server render it. Reach for
Alpine only for state that never needs to touch the server.

## Templates

`internal/views/render.go` parses each page as `layout.html` + `pages/<name>.html`
+ `components/*.html` at startup, and panics on a malformed template - so a
broken template fails the deploy, not the first request.

Adding a page:

1. `internal/views/pages/about.html` defining `{{define "content"}}`.
2. Register it in `NewRenderer`: `"about": page("about")`.
3. A handler that renders `"about"`, and a line in `internal/app/router.go`.

Templates are embedded, so only files matching the `go:embed` patterns in
`render.go` ship in the binary.

## gosite commands

The `gosite` CLI manages this project. Run from anywhere with the project name,
or from inside the directory without it.

| Command | What it does |
| --- | --- |
| `gosite start __PROJECT__` | Start the app (air hot reload) and Cockpit |
| `gosite stop __PROJECT__` | Stop the containers |
| `gosite restart __PROJECT__` | Recreate the containers; `--build` rebuilds the image |
| `gosite logs __PROJECT__` | Follow both containers; `app` or `cms` to pick one |
| `gosite logs __PROJECT__ app -n 50 --no-follow` | Last 50 lines, no follow |
| `gosite list` | Every project, its ports and container status; `--prune` drops entries whose directory is gone |
| `gosite cd __PROJECT__` | Jump to the directory (needs `eval "$(gosite shell-init)"`) |
| `gosite path __PROJECT__` | Print the directory, for scripts |
 | `gosite remove __PROJECT__` | Delete everything; `--keep-source` keeps the code |
 | `gosite infra up` / `down` / `status` | Shared Traefik, Redis, Mongo and MinIO (datastores bound to loopback) |
| `gosite dns` | Check that `*.test` resolves to 127.0.0.1 |
| `gosite doctor` | Check the local toolchain, then audit this project and the infrastructure against the secure defaults (read-only) |

**How this project gets upgraded.** gosite records the hash of every file it
writes in `.gosite/manifest.tsv`. Comparing those hashes against the files on
disk tells you exactly which ones somebody here edited — that list is what a
gosite upgrade must merge rather than overwrite. There is no command that does
it for you: the procedure lives in `MIGRATIONS.md` in the gosite repo.

`docker-compose.prod.yml` was never gosite's to write. It is the file teams edit
by hand, and nothing in gosite renders it into an existing project.

Editing a `.go` or `.html` file rebuilds automatically through air in about
three seconds - no restart needed. Restart for `.env`, compose or Dockerfile
changes.

If a request 404s right after a start, Cockpit is still failing its health
check: Traefik does not route to a container until it is healthy.

## Environment

Read once in `internal/config/config.go`; never call `os.Getenv` in a handler.

| Variable | Local default | Production |
| --- | --- | --- |
| `PORT` | 8080 | set by Coolify |
| `REDIS_URL` | `redis://__REDIS_HOST__:__REDIS_PORT__/0` | a Coolify Redis service |
| `COCKPIT_URL` | `http://__PROJECT__-cms:80` | the deployed Cockpit |
| `COCKPIT_API_TOKEN` | in `.env` | **mandatory** - the cache-purge endpoint refuses (503) without it |
| `S3_KEY` / `S3_SECRET` | generated per installation, shared with the local MinIO | the bucket's real credentials |
| `S3_VERIFY` | `false` - the local MinIO uses a self-signed mkcert certificate | unset, so TLS verification stays **on** |

`.env` is local only and gitignored. Production values come from the Coolify
UI.

The local MinIO credentials are generated once per machine and kept in the
gosite infra directory - they are not the `minioadmin` default, so do not
hardcode them anywhere. `S3_VERIFY=false` exists solely for the mkcert
certificate in development; never carry it into production, where it would
disable certificate checking against the real bucket.

## Deployment

`docker-compose.yml` is local only: mapped ports, source bind-mounted, air.
`docker-compose.prod.yml` is what Coolify uses: no host ports, Traefik labels,
every value from the environment, and the multi-stage `deploy/Dockerfile`
producing a static binary on Alpine.

The production stack is self-contained: it brings its own MongoDB and Redis, so
Coolify only supplies domains and secrets.

Push to Git, point a Coolify Docker Compose resource at
`docker-compose.prod.yml`, and set `SERVICE_FQDN_APP`, `SERVICE_FQDN_CMS`,
`COCKPIT_API_TOKEN`, `COCKPIT_SEC_KEY`, `MONGO_USER` and `MONGO_PASSWORD`.
`COCKPIT_API_TOKEN` is mandatory in production: the cache-purge endpoint fails
closed (503) in any non-development environment without it.

## Conventions

- Comments explain **why**, not what the next line does.
- Errors are logged where they happen and returned as a safe message.
- No global state; dependencies are passed through `handlers.Deps`.
- No JavaScript build step. Ever.
