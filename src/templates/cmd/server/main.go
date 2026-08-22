// Command __PROJECT__ is a Go + Cockpit CMS site: server-rendered HTML with
// htmx and Alpine.js, and a Redis cache in front of the CMS.
//
// Reading order: cmd/server/main.go (startup) -> internal/app/ (dependencies)
// -> internal/app/router.go (every route) -> internal/handlers/ (one file per handler).
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/labstack/echo/v5"

	"__MODULE__/internal/app"
	"__MODULE__/internal/config"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))

	a, err := app.NewApp(config.Load(), log)
	if err != nil {
		log.Error("startup failed", "err", err)
		os.Exit(1)
	}
	defer a.Close()

	// Echo v5 handles graceful shutdown itself: Start stops accepting
	// connections when the context is cancelled, then waits up to
	// GracefulTimeout for in-flight requests. There is no Shutdown call in v5.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	start := echo.StartConfig{
		Address:         ":" + a.Config.Port,
		HideBanner:      true,
		GracefulTimeout: 10 * time.Second,
	}
	if err := start.Start(ctx, app.NewRouter(a)); err != nil {
		log.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
