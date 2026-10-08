# __PROJECT__ - agent instructions

Read this first, then read `ARCHITECTURE.md` before changing anything. It holds
the detail behind these facts and rules: the layout, the Echo v5 differences,
how Cockpit and the cache work, and the `gosite` commands.

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

1. **Echo v5, not v4.** Do not copy v4 snippets from the web.
2. **Every route is registered in `internal/app/router.go`**; optional features append to `mountFeatures` from their own file.
3. **Handlers reply through `h.reply(c)`**, never by writing headers by hand.
4. **Views get finished data.** No Redis, HTTP or CMS calls inside `internal/views/`.
5. **The page is cached.** Purge after changing anything that affects the rendered HTML.
6. **No build step.** No npm, bundler or framework.
7. **Templates are embedded** with `go:embed`; a new view ships only if it matches `internal/views/render.go`.
8. **Data model lives in Cockpit.** Add fields in the admin UI and render them with a fallback; no migrations.
9. **Image attributes are type `asset`**, not `image`, so `assetURL` gets the asset object.

## Details

Details: ARCHITECTURE.md § Rules that are easy to get wrong

Details: ARCHITECTURE.md § Common tasks

Details: ARCHITECTURE.md § Cockpit addons
