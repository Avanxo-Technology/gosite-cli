package app

import (
	"net/url"

	"github.com/labstack/echo/v5"
	"github.com/labstack/echo/v5/middleware"
)

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

	return e
}
