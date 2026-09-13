// Package handlers holds one file per route. Everything shared between them
// lives here (dependencies) and in response.go (how they reply), so a new
// endpoint is a new file and a line in router.go - nothing else changes.
package handlers

import (
	"context"
	"log/slog"

	"github.com/redis/go-redis/v9"

	"github.com/Avanxo-Technology/gosite-cli/core/cms"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/cache"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/seo"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

// cacheKeyPrefix namespaces every cache key this project owns. Several
// projects share one Redis, so it is also what keeps a site-wide purge from
// becoming a flush of everybody's cache.
//
// Only keys under "<project>:cache:" are ever purged; application state lives
// under "<project>:app:" (gosite State) where no purge can reach it.
func (h *Handlers) cacheKeyPrefix() string { return h.Config.CacheKeyPrefix() }

// Deps is what the handlers need. Passing a struct rather than six positional
// arguments means adding a dependency does not touch every call site.
type Deps struct {
	Config   config.Config
	Log      *slog.Logger
	Cache    *cache.Cache
	CMS      *cms.Client
	Renderer *views.Renderer
	Redis    *redis.Client
	SEO      *seo.SEO
}

// Handlers is the receiver every handler hangs off, so they share dependencies
// without any of them reaching for a global.
type Handlers struct {
	Deps

	purgeHooks       []PurgeHook
	afterPurge       []func(ctx context.Context) error
	sitemapProviders []SitemapProvider
}

func New(d Deps) *Handlers { return &Handlers{Deps: d} }

// PurgeHook is given what the CMS said changed, so a feature that owns cache
// keys of its own can invalidate exactly those. Both arguments are empty when
// the purge did not name anything - an older CMS, or the on-page button.
type PurgeHook func(ctx context.Context, model, id string) error

// AfterPurge registers a hook run once after every successful purge, narrow or
// site-wide, once core has dropped its own keys. It is how a site's
// gosite.Purger learns that content changed.
func (h *Handlers) AfterPurge(hook func(ctx context.Context) error) {
	h.afterPurge = append(h.afterPurge, hook)
}

// runAfterPurge calls every AfterPurge hook in registration order.
func (h *Handlers) runAfterPurge(ctx context.Context) error {
	for _, hook := range h.afterPurge {
		if err := hook(ctx); err != nil {
			return err
		}
	}
	return nil
}

// OnPurge registers a hook run by POST /cache/purge.
//
// This is how a package that mounts its own pages - the blog, say - keeps its
// cache keys correct without this package having to know they exist. Register
// during mount, before the server starts serving.
func (h *Handlers) OnPurge(hook PurgeHook) {
	h.purgeHooks = append(h.purgeHooks, hook)
}
