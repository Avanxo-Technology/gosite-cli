package app

import (
	"context"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"

	"__MODULE__/internal/cache"
	"__MODULE__/internal/cms"
	"__MODULE__/internal/config"
	"__MODULE__/internal/handlers"
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

	renderer := views.NewRenderer(cfg.AssetBaseURL())

	return &App{
		Config:   cfg,
		Log:      log,
		Redis:    rdb,
		Renderer: renderer,
		Handlers: handlers.New(handlers.Deps{
			Config:   cfg,
			Log:      log,
			Cache:    cache.New(rdb, log, cfg.IsDev()),
			CMS:      cms.New(cfg, log),
			Renderer: renderer,
			Redis:    rdb,
		}),
	}, nil
}

func (a *App) Close() error { return a.Redis.Close() }
