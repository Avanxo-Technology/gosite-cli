// Package handlers holds one file per route. Everything shared between them
// lives here (dependencies) and in response.go (how they reply), so a new
// endpoint is a new file and a line in router.go - nothing else changes.
package handlers

import (
	"context"
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

	purgeHooks []PurgeHook
}

func New(d Deps) *Handlers { return &Handlers{Deps: d} }

// PurgeHook is given what the CMS said changed, so a feature that owns cache
// keys of its own can invalidate exactly those. Both arguments are empty when
// the purge did not name anything - an older CMS, or the on-page button.
type PurgeHook func(ctx context.Context, model, id string) error

// OnPurge registers a hook run by POST /cache/purge.
//
// This is how a package that mounts its own pages - the blog, say - keeps its
// cache keys correct without this package having to know they exist. Register
// during mount, before the server starts serving.
func (h *Handlers) OnPurge(hook PurgeHook) {
	h.purgeHooks = append(h.purgeHooks, hook)
}
