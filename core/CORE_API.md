# gosite core API

`github.com/Avanxo-Technology/gosite-cli/core` is what a thin site builds on.
This file is the contract: everything listed here keeps working across minor
and patch releases. Anything not listed is internal and can change at any
time — most of it lives under `internal/`, where Go will not let a site
import it.

Versions are tagged `core/vX.Y.Z`, in lockstep with the CLI's `vX.Y.Z`.

## Starting a site

```go
gosite.Run(app gosite.App, opts ...gosite.Option) error
gosite.New(app gosite.App, opts ...gosite.Option) (*gosite.Server, error) // tests, custom launchers
(*Server).Handler() http.Handler
(*Server).Close() error
```

`Run` loads configuration from the environment, connects Redis (failing before
it listens if it cannot), wires the CMS client, cache, SEO, analytics and
consent, registers core's routes and then the site's, and shuts down gracefully
on SIGINT/SIGTERM.

Options:

| Option | Effect |
| --- | --- |
| `WithTheme(fs.FS)` | The site's templates. Without it core renders its demo theme. |
| `WithAddons(names...)` | Enable addons by name instead of reading `gosite.yml`. |
| `WithoutRoutes(names...)` | Switch off core routes: `RouteHome`, `RouteRobots`, `RouteFavicon`, `RouteLLMs`, `RouteSitemap`. |
| `WithLogger(*slog.Logger)` | Replace the default text logger. |

## The App

```go
type App interface { Routes(r Router) }

// Optional, detected at startup:
type Middlewarer    interface { Middleware() []Middleware }
type TemplateDataer interface { TemplateData(c *Context, page string) map[string]any }
type Purger         interface { OnPurge(ctx context.Context) error }
```

- **Middleware** runs after core's own (recover, request log, gzip, asset
  cache headers).
- **TemplateData** is merged into every page's `.Data`, under the handler's own
  values. For pages served with `CachedRender` it is cached with the page, so
  it must not depend on who is visiting.
- **OnPurge** runs once after every successful purge, after core has dropped
  its cache keys.

`Context`, `HandlerFunc` and `Middleware` are aliases of Echo v5's types.

## The Router

```go
GET / POST / PUT / PATCH / DELETE(path string, h HandlerFunc, m ...Middleware)
Group(prefix string, m ...Middleware) Router
CMS() *cms.Client
State() *gosite.State
Render(c *Context, status int, page string, p Page) error
CachedRender(c *Context, page string, build func(ctx context.Context) (Page, error)) error
```

- Routes register after core's and after addons', so a site route on a path
  core serves **replaces** core's handler.
- `CMS()` is the only way to read content. Core has no MongoDB reader and its
  tests fail if a Mongo driver is ever added to the module.
- `CachedRender` keys pages by URL under `<project>:cache:page:`; every purge
  clears them. A failed build is never cached, and a stale copy is served
  instead when one exists.

### Core routes

`POST /cache/purge`, `GET /healthz` (always on); `/`, `/robots.txt`,
`/favicon.ico`, `/llms.txt`, `/sitemap.xml` (switchable). Core's browser
assets are served from the module at `/static/js/analytics/analytics.js`,
`/static/js/analytics/consent.js` and `/static/css/consent.css`; everything else
under `/static/` comes from the site's `static/` directory.

## State

```go
(*State).Get / Set / SetNX / Incr / Expire / TTL / Del
(*State).Key(key string) string
```

Keys are relative and stored under `<project>:app:`. No purge deletes them.
Cache keys live under `<project>:cache:` and nothing else is ever purged.

## Templates

A theme is an `fs.FS` with `layout.html`, `pages/*.html` and, optionally,
`components/*.html`. Each page defines `content`; the layout defines `layout`.

### Slots

The layout calls each exactly once:

| Slot | What core renders into it |
| --- | --- |
| `gosite:head` | `<title>`, SEO meta tags, favicon, consent loader, analytics loader |
| `gosite:body-start` | GTM's `<noscript>` fallback |
| `gosite:body-end` | the consent "preferences" control |

Core adds to slots in later versions; a layout that calls them needs no change.
A theme template with the same name as a core partial replaces it:
`gosite:seo`, `gosite:consent-head`, `gosite:analytics-head`,
`gosite:analytics-body`, `gosite:consent-link`.

### Page

```go
type Page struct {
    Title   string          // fallback <title>
    Path    string          // filled from the request when empty
    Content map[string]any  // CMS content; always a plain map
    SEOData map[string]any  // per-page SEO overrides
    Data    map[string]any  // TemplateData merged with the handler's values
    IsDev   bool            // filled by core
}
```

### Template functions

`assetURL`, `safeHTML`, `toJSON`, `jsonData`, `seoData`, `htmlLang`,
`faviconUrl`, `robotsTxtContent`, `analyticsIntegrations`, `consentSettings`.

## gosite.yml

A strict subset of YAML: `key: value` lines and `- item` lists. Core reads
`addons`; an unknown addon name stops startup. `GOSITE_CONFIG` names another
file.

## Testing a site

```go
gositetest.CheckTheme(t, theme)      // slots present once, every page renders
gositetest.ThemeProblems(theme)      // the same, as a list
```

## Environment

`GOSITE_PROJECT` (Redis namespace and CMS service name), `PORT`, `REDIS_URL`,
`COCKPIT_URL`, `COCKPIT_API_TOKEN`, `APP_ENV`, `STORAGE_ADAPTER`,
`S3_PUBLIC_URL`, `SITE_URL`, `GOSITE_CONFIG`.

## Deprecation policy

A name in this file is never removed or changed in meaning in a minor or patch
release. It first keeps working for at least one minor release while the
process logs one warning at startup naming its replacement; removal waits for
a major version. Today's deprecated names: the pre-slot templates
`consent-head`, `analytics-head`, `analytics-body`, `consent-link` (use the
slots) and `seo` (renders nothing).
