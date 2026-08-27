# __PROJECT__ - project memory

Read this first, then read `ARCHITECTURE.md` before changing anything. It
covers the layout, the rules that are easy to get wrong, the Echo v5 API
differences, how Cockpit and the cache work, and the `gosite` commands.

## What this is

A Go monolith that serves server-rendered HTML: **Echo v5** for routing,
**html/template** for markup, **htmx** and **Alpine.js** on the client,
**Cockpit** as the CMS and **Redis** as a page cache in front of it.
There is no JavaScript build step and no SPA.

## Facts

| | |
| --- | --- |
| Go module | `__MODULE__` |
| Local URL | https://__DOMAIN__ (also http://localhost:__APP_PORT__) |
| Cockpit admin | https://__CMS_DOMAIN__ (also http://localhost:__CMS_PORT__) |
| Redis | shared container `__REDIS_HOST__` on the `__NETWORK__` Docker network |
| CMS database | MongoDB (shared `__MONGO_HOST__` container locally, own MongoDB in production) |
| Cache key | `__PROJECT__:home_html`, TTL 10 minutes |
| Cache behaviour | single-flight on misses; `/cache/purge` re-warms in the background |
| CMS addons | five built-ins + optional Forms/Blog/Replica in `cockpit/addons/` (from gosite's addon library) |
| Managed by | the `gosite` CLI - see ARCHITECTURE.md for the commands |

## Reading order

`cmd/server/main.go` -> `internal/app/` -> `internal/handlers/`

## Rules that are easy to get wrong

1. **Echo v5, not v4.** Handlers take `*echo.Context`, `c.Response()` returns
   `http.ResponseWriter`, `echo.NewHTTPError(code, string)` takes a string, and
   there is no `e.Shutdown`. Do not copy v4 snippets from the web.
2. **Every route is registered in `internal/app/router.go`.** An optional
   feature that ships its own routes appends to `mountFeatures` from its own
   file (`router_blog.go`), so installing one never rewrites this file - but
   the call is still visible here. Nothing else registers
   routes anywhere else.
3. **Handlers reply through `h.reply(c)`** (`internal/handlers/response.go`),
   never by writing headers by hand.
4. **Views get finished data.** No Redis, no HTTP and no CMS calls inside
   `internal/views/`.
5. **The page is cached.** After changing anything that affects the rendered
   HTML, purge: `curl -X POST -H "X-Api-Key: $COCKPIT_API_TOKEN" https://__DOMAIN__/cache/purge`
   Otherwise you will be looking at a stale page for up to 10 minutes.
6. **No build step.** Do not add npm, a bundler or a framework. htmx and
   Alpine are loaded from a CDN in `internal/views/layout.html`.
7. **Templates are embedded** with `go:embed`, so a new file under
   `internal/views/` only ships if it matches the embed patterns in
   `internal/views/render.go`.
8. **Data model lives in the database.** Content schemas (singletons,
   collections, fields) are defined in the Cockpit admin UI and stored in
   MongoDB. No migration files or SQL schemas exist in this repo - add fields
   in Cockpit, then render them in the template with a fallback.
9. **Every image attribute in a content model must be type `asset`.** Define
   image fields as type `asset` (not `image`), so the value is the full asset
   object (`path`, `url`, ...) that the `assetURL` helper renders with
   `{{assetURL (index .Content "field")}}`. The `image` type does not give
   `assetURL` what it needs - a model with images is only correct when each
   image attribute is an `asset`.

## Common tasks

| Task | Do this |
| --- | --- |
| Add a route | one file in `internal/handlers/`, one line in `internal/app/router.go` |
| Add a page | drop a template in `internal/views/pages/`; it registers itself by filename |
| Add a component | file in `internal/views/components/`, call `{{template "name" .}}` |
| Change content | edit it in Cockpit, then purge the cache |
| Read the logs | `gosite logs __PROJECT__` |
| Restart | `gosite restart __PROJECT__` (air already reloads code) |

## Cockpit addons

Cockpit loads `cockpit/addons/` as first-class modules. Locally the container
mounts the folder; in production `deploy/Dockerfile.cms` bakes them (plus
`cockpit/config.php`) into the image, because relative bind mounts do not
resolve to the repo checkout in Coolify.

### Built-ins (always installed)

- **AssetsUpload** - `POST /api/assets/upload` (multipart form, `api-key`
  header, optional `folder` field). The REST-equivalent of the admin uploader;
  the app uses it to push files into the CMS.
- **ModelManager** - content-model CRUD over the REST API: `GET /api/models`,
  `POST /api/models/save` (body `model` with `name` + `type` of collection /
  singleton / tree), `POST /api/models/remove` (body `name`). Lets the app
  create and evolve content schemas without the admin UI.
- **CloudStorage** - S3-compatible asset storage, active only when
  `STORAGE_ADAPTER=s3` (MinIO in dev, AWS/R2/Backblaze in prod). Uploads and
  thumbnails are served from `S3_PUBLIC_URL`. The local `#uploads` mount is
  intentionally NOT redirected to S3: core's thumbnail pipeline
  (`makeAssetLocalAvailable()`) writes and re-reads that mount from disk, so
  redirecting it 404s every generated thumbnail.

All three authenticate with the same `api-key` header (`$COCKPIT_API_TOKEN`) as
the content API. Render a CMS asset in a template with the `assetURL` helper
(see `internal/views/render.go`): `{{assetURL (index .Content "field_name")}}`
resolves against `S3_PUBLIC_URL` when S3 is on, otherwise against the local
`/storage/uploads` proxy, and renders empty when the editor has not filled the
field in.

### Optional (opt-in at scaffold time)

- **Forms** - inbox-style manager for website form submissions, with anti-spam,
  CSV export and notifications.
- **Replica** - content replication between Cockpit instances (push/pull,
  multiple targets, mirror/merge).

Choose the optional ones when creating (`--addons "Forms Replica"`, or
`--no-addons` to skip). After the first login grant the permissions
`forms/manage` and `replica/manage` in Settings > Roles.

**API key role binding:** the Cockpit API key (`COCKPIT_API_TOKEN` in `.env`)
must be bound to a role that has `replica/manage` and content read permissions.
Without this, `GET /api/replica/manifest` returns 403 and falls back to
transport=core (entries only, no assets or models). When creating the token in
the Cockpit admin, assign it to the `api` role (or a role with those
permissions), not "No role".

### Managing addons

All addons come from gosite's addon library (`src/addons/`), so updating gosite
keeps every future scaffold current. Update or add addons later with:

```bash
gosite sync --addons
```

`sync` overwrites the addons in place and clears the Cockpit module cache. In
production the module cache lives in the persistent `cockpit-storage` volume, so
after a deploy that ships new or updated addons, clear
`storage/cache/modules.cache.php` once inside the cms container (the image
rebuild ships the files; the stale cache is what hides them).
