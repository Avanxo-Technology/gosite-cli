# __PROJECT__

Go (Echo + htmx + Alpine.js + Templ) + Cockpit CMS monolith, with
Redis cache-aside in front of the CMS.

## Structure

One file per responsibility. Handlers live in their own package, one file per
route, so the file never becomes a dumping ground as the app grows:

```
cmd/server/          Entry point (package main).
  main.go            Startup: read config, build the app, start the server.
  app.go             Composition root: build every dependency once.
  router.go          Every route and middleware. The whole HTTP surface.
internal/            Application packages (not importable by external code).
  config/            Environment settings, read exactly once.
  handlers/          One file per route.
    handlers.go      Deps + the receiver they hang off.
    response.go      How this app replies (see below).
    home.go          GET /
    purge.go         POST /cache/purge
    health.go        GET /healthz
  cache/             Cache-aside over Redis, written once.
  cms/               The Cockpit API client. The only package that calls the CMS.
  views/             Markup, embedded with go:embed.
    render.go        Parses every template at startup.
    layout.html      Base document (styles, htmx, Alpine).
    pages/           One file per page.
    components/      Reusable pieces, one per file.
  app/               App struct, NewApp, NewRouter (wiring).
cockpit/             Cockpit CMS configuration.
  config.php         Production config (baked into Dockerfile.cms).
  addons/            Cockpit addons (four built-ins + optional Forms/Replica).
deploy/              Dockerfiles for production, dev, and CMS images.
static/              Assets served at /static.
```

Reading order: `cmd/server/main.go` -> `internal/app/` -> `internal/handlers/`.

Adding an endpoint is one file in `internal/handlers/` and one line in
`internal/app/router.go`. Adding a page is one template in
`internal/views/pages/`. Nothing else changes.

Data flows one way: `internal/cms` fetches from Cockpit, a handler passes that
to `internal/views`, and the rendered HTML goes into `internal/cache`.

The example is deliberately one page with no data model. Add a struct in
`internal/cms` once the shape of your content settles; until then
`cms.Content` is a map, so a template can read `{{.Content.headline}}` without
anything to define first.

## Responses

Handlers reply through the small `Response` helper in `handlers/response.go`
rather than repeating the same bookkeeping:

```go
return h.reply(c).Page(html, cached)                       // HTML + X-Cache header
return h.reply(c).Text(http.StatusOK, "purged")            // plain text
return h.reply(c).Fail(http.StatusBadGateway, "...", err)  // log + safe message
```

It is a thin layer over [Echo's own response helpers][echo-response] -
`Context.HTMLBlob`, `Context.String` and `Context.JSON` do the actual writing.
What it adds is the cache header and, in `Fail`, logging the real error while
returning only a message that is safe to show a client.

[echo-response]: https://echo.labstack.com/guide/response/

## Routes

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | The page, served from the Redis cache |
| POST | `/cache/purge` | Invalidate the cache (htmx button + Cockpit webhook) |
| GET | `/healthz` | Liveness, checks Redis |

## Cockpit

`internal/cms/cms.go` calls `GET $COCKPIT_URL/api/content/item/home` with an
`api-key` header. Create a `home` singleton in the Cockpit admin with
`headline` and `intro` fields and the page renders them.

Until it exists the request fails, the client returns empty content and logs
why, and the template falls back to the copy written into
`internal/views/pages/home.html` - so a fresh project renders on the first run
instead of an error page.

Collections live at `/api/content/items/<name>` if you need a list later.

When the data model changes (new fields, new collections) the change goes into
MongoDB through the Cockpit admin UI. No migration files or code changes are
needed unless the template needs to render the new data.

## Addons

Locally the CMS container mounts `cockpit/addons/`; in production
`deploy/Dockerfile.cms` bakes `cockpit/config.php` and `cockpit/addons/` into
the image. Every scaffold ships with four built-ins (asset upload API, model
manager, S3 storage, asset path fix) and the optional addons chosen at scaffold time
(`--addons "Forms Replica"`, `--no-addons` to skip):

- **Forms** — inbox-style manager for website form submissions: public receiver
  endpoint with anti-spam, an admin screen, CSV export and notifications.
- **Replica** — content replication between Cockpit instances: push/pull,
  multiple targets, mirror/merge conflict handling, dry runs and a CLI.

After first login, grant `forms/manage` and `replica/manage` in Settings >
Roles. To update the addons or add more:

```bash
gosite sync --addons            # refresh built-ins + any optional addons already present
gosite sync --addons Forms      # install or replace a single optional addon
```

## Local development

```bash
gosite infra up      # shared Traefik + Redis on __NETWORK__
gosite start         # app (air hot reload) + Cockpit
```

| Service | URL |
| --- | --- |
| App | http://localhost:__APP_PORT__ |
| Cockpit | http://localhost:__CMS_PORT__ |

Editing any `.go` or `.html` file (including a single component) triggers an
air rebuild in about 3 seconds. Templates are embedded with `go:embed`, so the
production image is a single self-contained binary.

## Caching

`GET /` is served from Redis (key `<project>:index_html`, TTL 10m). The cached
value is the *fully rendered page*, so a hit skips the CMS call and the
template render entirely. The `X-Cache` response header reports `HIT` or
`MISS`.

The purge button on the page posts to `/cache/purge`; point a Cockpit publish
webhook at the same route (header `X-Api-Key: $COCKPIT_API_TOKEN`) so editors
never wait out the TTL. Outside development the endpoint fails closed: no
configured token means 503, a wrong token means 401.

The mechanics live in `cache.go` as a single `Cache.HTML(key, render)` helper,
so caching another page is one call, not another copy of the same Get/Set
dance.

## Production (Coolify)

`docker-compose.prod.yml` publishes no host ports and takes every value from
the environment. In Coolify: create a Docker Compose resource from this repo,
select `docker-compose.prod.yml`, then set `SERVICE_FQDN_APP`,
`SERVICE_FQDN_CMS`, `COCKPIT_API_TOKEN`, `COCKPIT_SEC_KEY`, `MONGO_USER` and
`MONGO_PASSWORD`. The stack brings its own MongoDB and Redis.
`COCKPIT_API_TOKEN` is mandatory in production - without it `/cache/purge`
responds 503.

The `app` and `cms` services build from `deploy/Dockerfile` and
`deploy/Dockerfile.cms`; nothing is bind-mounted, so Coolify needs no path to
the checkout. Config and addon changes require an image rebuild rather than a
file drop, and after a rebuild that adds an addon, clear
`storage/cache/modules.cache.php` once in the cms container.
