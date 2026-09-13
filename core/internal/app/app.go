package app

import (
	"context"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/Avanxo-Technology/gosite-cli/core/cms"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/analytics"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/cache"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/seo"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
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
//
// views are extra renderer options from the site: its theme, addon partials.
func NewApp(cfg config.Config, log *slog.Logger, viewOpts ...views.Option) (*App, error) {

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
	seoResolver := seo.New(cmsClient, cacheInstance, log, seo.WithAssetBase(cfg.AssetBaseURL()), seo.WithProject(cfg.Project))

	// One reader for both halves of the addon: the integrations and the consent
	// banner that gates them.
	analyticsReader := analytics.New(cmsClient, cfg, log)

	renderer := views.NewRenderer(cfg.AssetBaseURL(), append([]views.Option{
		views.WithLogger(log),
		views.WithIntegrations(analyticsReader.Integrations),
		views.WithConsent(analyticsReader.Consent),
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
	}, viewOpts...)...,
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
