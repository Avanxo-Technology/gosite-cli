package app

import (
	"context"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"

	"__MODULE__/internal/analytics"
	"__MODULE__/internal/cache"
	"__MODULE__/internal/cms"
	"__MODULE__/internal/config"
	"__MODULE__/internal/handlers"
	"__MODULE__/internal/seo"
	"__MODULE__/internal/views"
)

// App holds what main needs to keep alive; the handlers get their own
// dependencies injected at construction.
type App struct {
	Config   config.Config
	Log      *slog.Logger
	Redis    *redis.Client
	Handlers *handlers.Handlers
	Renderer *views.Renderer
}

// NewApp wires everything and verifies Redis up front, so a misconfigured
// environment fails at boot instead of on the first request.
func NewApp(cfg config.Config, log *slog.Logger) (*App, error) {

	// A deployment error, not a caller error: without a shared token the purge
	// endpoint refuses to operate in non-development environments (503), so
	// name the fix at startup rather than letting editors discover it later.
	if !cfg.IsDev() && cfg.CockpitToken == "" {
		log.Warn("COCKPIT_API_TOKEN is empty in a non-development environment; " +
			"POST /cache/purge will respond 503 until a token is configured")
	}

	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		return nil, err
	}
	rdb := redis.NewClient(opts)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, err
	}
	log.Info("redis connected", "addr", opts.Addr, "db", opts.DB)

	// The renderer is built once, but the analytics integrations live in the
	// CMS and change while the process runs, so it is handed a function rather
	// than a list.
	cmsClient := cms.New(cfg, log)
	cacheInstance := cache.New(rdb, log, cfg.IsDev())
	seoResolver := seo.New(cmsClient, cacheInstance, log, seo.WithAssetBase(cfg.AssetBaseURL()))

	renderer := views.NewRenderer(cfg.AssetBaseURL(),
		views.WithIntegrations(analytics.New(cmsClient, cfg, log).Integrations),
		// The adapter keeps views decoupled from the seo package: templates pass
		// .SEOData as a map, seo.Resolve works on *seo.Data, and renderSEOTags
		// consumes the map the adapter returns.
		views.WithSEO(func(path string, overrides ...any) map[string]any {
			var dataOverrides []*seo.Data
			if len(overrides) > 0 {
				if m, ok := overrides[0].(map[string]any); ok {
					dataOverrides = append(dataOverrides, seo.FromMap(m))
				}
			}
			return seo.ToMap(seoResolver.Resolve(path, dataOverrides...))
		}),
		views.WithFavicon(func() string {
			return seoResolver.GetWebappConfig().Favicon
		}),
		views.WithRobotsTxt(func() string {
			return seoResolver.GetWebappConfig().RobotsTxt
		}),
	)

	h := handlers.New(handlers.Deps{
		Config:   cfg,
		Log:      log,
		Cache:    cacheInstance,
		CMS:      cmsClient,
		Renderer: renderer,
		Redis:    rdb,
		SEO:      seoResolver,
	})

	// A change to webapp/seoPages must drop the SEO resolution cache as well
	// as the page HTML (the purge handler already treats those as site-wide).
	h.OnPurge(seoResolver.PurgeHook)

	return &App{
		Config:   cfg,
		Log:      log,
		Redis:    rdb,
		Renderer: renderer,
		Handlers: h,
	}, nil
}

func (a *App) Close() error { return a.Redis.Close() }
