// Package gosite is the core of a gosite site: the CMS client, the page cache,
// SEO, analytics and consent, the core routes, and the server around them.
//
// A site does not copy any of this. Its main.go is one call:
//
//	func main() {
//		if err := gosite.Run(site.New()); err != nil {
//			os.Exit(1)
//		}
//	}
//
// and its own code implements App - and, when it needs to, the optional
// interfaces below. Upgrading core is changing the version in go.mod.
package gosite

import (
	"context"
	"errors"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/app"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

// Context, HandlerFunc and Middleware are the HTTP types site handlers use.
//
// They are aliases of Echo v5's types rather than wrappers: a wrapper around
// echo.Context would be most of Echo's API copied by hand. What core does keep
// behind its own interface is route registration (Router), which is where an
// Echo upgrade would otherwise reach into every site.
type (
	Context     = echo.Context
	HandlerFunc = echo.HandlerFunc
	Middleware  = echo.MiddlewareFunc
)

// App is a site. Routes is the only required method.
type App interface {
	Routes(r Router)
}

// Middlewarer is implemented by a site that adds HTTP middleware. It runs
// after core's own (recover, logging, gzip, asset cache headers).
type Middlewarer interface {
	Middleware() []Middleware
}

// TemplateDataer is implemented by a site that adds values to every page it
// renders through core. The map is available to templates as .Data.
type TemplateDataer interface {
	TemplateData(c *Context, page string) map[string]any
}

// Purger is implemented by a site that owns cached state core does not know
// about. OnPurge runs once after every successful purge, after core has
// dropped its own cache keys.
type Purger interface {
	OnPurge(ctx context.Context) error
}

// Core route names accepted by WithoutRoutes.
const (
	RouteHome    = "home"
	RouteRobots  = "robots"
	RouteFavicon = "favicon"
	RouteLLMs    = "llms"
	RouteSitemap = "sitemap"
)

// Option configures Run and New.
type Option func(*options)

type options struct {
	log      *slog.Logger
	disabled map[string]bool
	theme    fs.FS
}

// WithLogger replaces the default text logger on stdout.
func WithLogger(log *slog.Logger) Option {
	return func(o *options) { o.log = log }
}

// WithTheme is the site's templates: layout.html, pages/*.html and optionally
// components/*.html. Sites embed their theme directory so the binary carries
// it. Without this option core renders its default demo theme.
func WithTheme(theme fs.FS) Option {
	return func(o *options) { o.theme = theme }
}

// WithoutRoutes switches off core routes by name (RouteHome, RouteRobots, ...).
// A site that only wants to replace one does not need this: a route it
// registers on the same path already wins.
func WithoutRoutes(names ...string) Option {
	return func(o *options) {
		for _, n := range names {
			o.disabled[n] = true
		}
	}
}

// Server is a wired site that is not yet listening. Run is New + ListenAndServe;
// New exists so tests and custom launchers can drive the handler directly.
type Server struct {
	core    *app.App
	handler http.Handler
	log     *slog.Logger

	templateData TemplateDataer
}

// New wires core and the site. It connects to Redis before returning, so a
// misconfigured environment fails here rather than on the first request.
func New(site App, opts ...Option) (*Server, error) {
	if site == nil {
		return nil, errors.New("gosite: nil App")
	}
	o := options{disabled: map[string]bool{}}
	for _, apply := range opts {
		apply(&o)
	}
	if o.log == nil {
		o.log = slog.New(slog.NewTextHandler(os.Stdout, nil))
	}

	cfg := config.Load()
	var viewOpts []views.Option
	if o.theme != nil {
		viewOpts = append(viewOpts, views.WithTheme(o.theme))
	}
	core, err := app.NewApp(cfg, o.log, viewOpts...)
	if err != nil {
		return nil, err
	}

	s := &Server{core: core, log: o.log}

	routerOpts := app.RouterOptions{Disabled: o.disabled}
	if m, ok := site.(Middlewarer); ok {
		routerOpts.Middleware = m.Middleware()
	}
	if p, ok := site.(Purger); ok {
		core.Handlers.AfterPurge(p.OnPurge)
	}
	if d, ok := site.(TemplateDataer); ok {
		s.templateData = d
	}

	r := &router{state: newState(core.Redis, cfg.StateKeyPrefix()), cms: core.Handlers.CMS, server: s}
	routerOpts.Site = func(e *echo.Echo) {
		r.target = e
		site.Routes(r)
	}

	s.handler = app.NewRouter(core, routerOpts)
	return s, nil
}

// Handler is the site's complete HTTP handler.
func (s *Server) Handler() http.Handler { return s.handler }

// Close releases the Redis connection.
func (s *Server) Close() error { return s.core.Close() }

// Run wires the site, listens on PORT and shuts down gracefully on SIGINT or
// SIGTERM, waiting up to ten seconds for in-flight requests.
func Run(site App, opts ...Option) error {
	s, err := New(site, opts...)
	if err != nil {
		slog.Error("startup failed", "err", err)
		return err
	}
	defer s.Close()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	start := echo.StartConfig{
		Address:         ":" + s.core.Config.Port,
		HideBanner:      true,
		GracefulTimeout: 10 * time.Second,
	}
	if err := start.Start(ctx, s.handler); err != nil && !errors.Is(err, http.ErrServerClosed) {
		s.log.Error("server stopped", "err", err)
		return err
	}
	return nil
}
