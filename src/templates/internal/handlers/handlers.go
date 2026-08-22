// Package handlers holds one file per route. Everything shared between them
// lives here (dependencies) and in response.go (how they reply), so a new
// endpoint is a new file and a line in router.go - nothing else changes.
package handlers

import (
	"log/slog"

	"github.com/redis/go-redis/v9"

	"__MODULE__/internal/cache"
	"__MODULE__/internal/cms"
	"__MODULE__/internal/config"
	"__MODULE__/internal/views"
)

// Deps is what the handlers need. Passing a struct rather than six positional
// arguments means adding a dependency does not touch every call site.
type Deps struct {
	Config   config.Config
	Log      *slog.Logger
	Cache    *cache.Cache
	CMS      *cms.Client
	Renderer *views.Renderer
	Redis    *redis.Client
}

// Handlers is the receiver every handler hangs off, so they share dependencies
// without any of them reaching for a global.
type Handlers struct {
	Deps
}

func New(d Deps) *Handlers { return &Handlers{Deps: d} }
