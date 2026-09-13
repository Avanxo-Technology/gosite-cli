package app

import (
	"embed"
	"io/fs"
	"mime"
	"net/http"
	"net/url"
	"path"
	"strings"

	"github.com/labstack/echo/v5"
	"github.com/labstack/echo/v5/middleware"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
)

// RouterOptions is what gosite.Run passes in from the site.
type RouterOptions struct {
	// Disabled names core routes the site switched off: "home", "robots",
	// "favicon", "llms", "sitemap".
	Disabled map[string]bool
	// Middleware from the site's gosite.Middlewarer, applied after core's.
	Middleware []echo.MiddlewareFunc
	// Mounts are enabled addons' route registrations. They run after core's
	// routes and before the site's.
	Mounts []func(*echo.Echo, *handlers.Handlers)
	// Site registers the site's routes. It runs last, so a site route on a
	// path core also serves replaces core's handler.
	Site func(e *echo.Echo)
}

// NewRouter wires middleware and routes: core's first, then the site's.
func NewRouter(a *App, opts RouterOptions) *echo.Echo {
	// AutoHandleHEAD makes every GET route answer HEAD as well, with the body
	// suppressed and the headers intact. Without it echo answers 405, and an
	// uptime check or a link validator that pings with HEAD reports the site as
	// broken while a browser sees it perfectly.
	//
	// Safe for this scaffold specifically: every GET here is a cached, public,
	// side-effect-free page. Anything that mutates state is a POST, which HEAD
	// never reaches. Echo leaves this off by default because a GET handler runs
	// in full for each HEAD - worth re-reading its caveats before adding a GET
	// route that writes, counts, or costs real work.
	e := echo.NewWithConfig(echo.Config{
		// AllowOverwritingRoute is what lets a site replace a core route: core
		// registers first and the site last, and the later handler wins. Echo's
		// default New() turns it on; a custom RouterConfig does not.
		Router: echo.NewRouter(echo.RouterConfig{AutoHandleHEAD: true, AllowOverwritingRoute: true}),
	})
	e.Renderer = a.Renderer

	e.Use(middleware.Recover())
	e.Use(middleware.RequestLogger())
	e.Use(middleware.Gzip())
	e.Use(assetCacheHeaders())
	for _, m := range opts.Middleware {
		e.Use(m)
	}

	// Core's own browser assets (consent banner, analytics loader) are served
	// from the module, at the paths core's partials link to. Registered as
	// exact routes, so they win over a same-named file in the site's static/:
	// a site cannot end up running an old copy of core's consent script.
	mountCoreAssets(e)
	e.Static("/static", "static")

	// Cockpit uploads: in development with local storage they live on the host
	// filesystem; with S3 storage (or in production) we proxy to Cockpit, which
	// serves them from the configured S3-compatible bucket via Flysystem.
	if a.Config.CockpitURL == "" || (a.Config.IsDev() && a.Config.StorageAdapter != "s3") {
		e.Static("/storage/uploads", "cockpit-storage/uploads")
	} else {
		target, err := url.Parse(a.Config.CockpitURL)
		if err != nil {
			panic("invalid COCKPIT_URL: " + err.Error())
		}
		e.Group("/storage/uploads", middleware.ProxyWithConfig(middleware.ProxyConfig{
			Balancer: middleware.NewRoundRobinBalancer([]*middleware.ProxyTarget{
				{URL: target},
			}),
		}))
	}

	h := a.Handlers

	// --- routes --------------------------------------------------------------
	// Purge and health are not optional: purge is how the CMS reaches the
	// site, and health is what the deploy platform polls.
	e.POST("/cache/purge", h.PurgeCache) // htmx button + Cockpit webhook
	e.GET("/healthz", h.Health)          // liveness, checks Redis

	optional := []struct {
		name, path string
		handler    echo.HandlerFunc
	}{
		{"home", "/", h.Home},                  // the demo page, served from cache
		{"robots", "/robots.txt", h.Robots},    // robots.txt from webapp singleton
		{"favicon", "/favicon.ico", h.Favicon}, // favicon redirect to asset
		{"llms", "/llms.txt", h.LLMs},          // LLM Text from webapp singleton
		{"sitemap", "/sitemap.xml", h.Sitemap}, // built from seoPages + mounted features
	}
	for _, route := range optional {
		if !opts.Disabled[route.name] {
			e.GET(route.path, route.handler)
		}
	}

	// Optional features, mounted after the routes above so those keep
	// precedence. The blog serves /{blog} and /{blog}/{slug}; echo resolves a
	// concrete path segment before a `:param` one regardless of registration
	// order, so a page this file serves always wins over a blog slug.
	for _, mount := range opts.Mounts {
		mount(e, h)
	}

	if opts.Site != nil {
		opts.Site(e)
	}

	return e
}

// assetCacheHeaders sets Cache-Control for the two static prefixes, which get
// deliberately different lifetimes.
//
// Cockpit uploads carry a unique name per upload, so a given URL never changes
// content and is safe to cache forever. Files under /static are served under
// stable names - a stylesheet or a vendored library keeps its path across
// deploys - so they get a short freshness window instead: the browser
// revalidates with its ETag and a new deploy reaches returning visitors within
// the hour. Marking those immutable would hide a CSS or JS change for a year,
// visible only to someone arriving with a cold cache, with no way to
// invalidate it short of renaming the file. If this project ever fingerprints
// its assets, that prefix can move to the immutable branch.
//
// HTML routes are untouched either way - the page cache owns those.
func assetCacheHeaders() echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c *echo.Context) error {
			p := c.Request().URL.Path
			switch {
			case strings.HasPrefix(p, "/storage/uploads/"):
				c.Response().Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			case strings.HasPrefix(p, "/static/"):
				c.Response().Header().Set("Cache-Control", "public, max-age=3600")
			}
			return next(c)
		}
	}
}

// coreAssets are core's browser files, served under /static/.
//
//go:embed assets
var coreAssets embed.FS

// mountCoreAssets registers one GET route per embedded asset.
func mountCoreAssets(e *echo.Echo) {
	_ = fs.WalkDir(coreAssets, "assets", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		body, err := coreAssets.ReadFile(p)
		if err != nil {
			return err
		}
		contentType := mime.TypeByExtension(path.Ext(p))
		if contentType == "" {
			contentType = "application/octet-stream"
		}
		e.GET("/static/"+strings.TrimPrefix(p, "assets/"), func(c *echo.Context) error {
			return c.Blob(http.StatusOK, contentType, body)
		})
		return nil
	})
}
