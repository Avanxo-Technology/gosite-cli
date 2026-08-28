package app

import (
	"net/url"

	"github.com/labstack/echo/v5"
	"github.com/labstack/echo/v5/middleware"

	"__MODULE__/internal/handlers"
)

// mountFeatures are optional features that bring their own routes. A feature
// installed into this project registers itself here from its own file (the
// blog does this in router_blog.go), so installing or removing one is adding
// or deleting files - this file is never rewritten by a tool and stays yours
// to edit.
//
// The call still happens below, in plain sight: the HTTP surface remains
// readable from this file alone.
var mountFeatures []func(*echo.Echo, *handlers.Handlers)

// NewRouter wires middleware and routes. This is the single source of truth
// for the app's HTTP surface - nothing registers routes anywhere else.
func NewRouter(a *App) *echo.Echo {
	e := echo.New()
	e.Renderer = a.Renderer

	e.Use(middleware.Recover())
	e.Use(middleware.RequestLogger())
	e.Use(middleware.Gzip())

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
	e.GET("/", h.Home)                   // the page, served from cache
	e.POST("/cache/purge", h.PurgeCache) // htmx button + Cockpit webhook
	e.GET("/healthz", h.Health)          // liveness, checks Redis
	e.GET("/robots.txt", h.Robots)       // robots.txt from webapp singleton
	e.GET("/favicon.ico", h.Favicon)     // favicon redirect to asset
	e.GET("/llms.txt", h.LLMs)           // LLM Text from webapp singleton
	e.GET("/sitemap.xml", h.Sitemap)     // built from seoPages + mounted features

	// Optional features, mounted after the routes above so those keep
	// precedence. The blog serves /{blog} and /{blog}/{slug}; echo resolves a
	// concrete path segment before a `:param` one regardless of registration
	// order, so a page this file serves always wins over a blog slug.
	for _, mount := range mountFeatures {
		mount(e, h)
	}

	return e
}
