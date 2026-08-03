#!/usr/bin/env bash
#
# gosite create <project-name>
#
# Scaffolds a Go (Echo + htmx + Alpine + Templ) + Cockpit CMS project with a
# strict split between local development (air hot reload, mapped ports) and
# production (multi-stage build, Coolify-native compose file).
#

# Templates are written with __PLACEHOLDER__ tokens and rendered afterwards so
# heredocs can stay fully quoted and never mangle Go/compose "${VAR}" syntax.
#
# Note: __PG_PORT__/__REDIS_PORT__ render to the IN-NETWORK ports (5432/6379),
# not the host-published ones. Project containers always reach the shared
# services by container name on gosite-network, never through the host.
render_placeholders() {
  local file="$1" tmp
  tmp="$(mktemp)"
  sed \
    -e "s|__PROJECT__|${PROJECT_NAME}|g" \
    -e "s|__MODULE__|${PROJECT_MODULE}|g" \
    -e "s|__NETWORK__|${GOSITE_NETWORK}|g" \
    -e "s|__DOMAIN__|${APP_DOMAIN}|g" \
    -e "s|__CMS_DOMAIN__|${CMS_DOMAIN}|g" \
    -e "s|__APP_PORT__|${APP_PORT}|g" \
    -e "s|__CMS_PORT__|${CMS_PORT}|g" \
    -e "s|__PG_HOST__|${GOSITE_PG_HOST}|g" \
    -e "s|__PG_PORT__|5432|g" \
    -e "s|__PG_USER__|${GOSITE_PG_USER}|g" \
    -e "s|__PG_PASSWORD__|${GOSITE_PG_PASSWORD}|g" \
    -e "s|__REDIS_HOST__|${GOSITE_REDIS_HOST}|g" \
    -e "s|__REDIS_PORT__|6379|g" \
    -e "s|__CMS_TOKEN__|${CMS_TOKEN}|g" \
    "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

cmd_create() {
  local PROJECT_NAME="" here=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --here) here=1; shift ;;
      -*)     fatal "Unknown flag for 'create': $1 (expected --here)" ;;
      *)      PROJECT_NAME="$1"; shift ;;
    esac
  done

  validate_project_name "${PROJECT_NAME}"
  require_dependencies

  # Sites live together under the workspace so they are easy to find and list.
  # --here overrides that for a one-off project in the current directory.
  local PROJECT_DIR
  if [[ "${here}" -eq 1 ]]; then
    PROJECT_DIR="${PWD}/${PROJECT_NAME}"
  else
    mkdir -p "${GOSITE_WORKSPACE}"
    PROJECT_DIR="${GOSITE_WORKSPACE}/${PROJECT_NAME}"
  fi
  [[ -e "${PROJECT_DIR}" ]] && fatal "'${PROJECT_DIR}' already exists."

  local PROJECT_MODULE="${GOSITE_MODULE_PREFIX:-github.com/example}/${PROJECT_NAME}"
  local APP_PORT CMS_PORT CMS_TOKEN APP_DOMAIN CMS_DOMAIN
  APP_PORT="$(find_free_port "${GOSITE_PORT_MIN}")"
  CMS_PORT="$(find_free_port "$(( APP_PORT + 1 ))")"
  CMS_TOKEN="$(random_secret 24)"
  APP_DOMAIN="$(project_domain "${PROJECT_NAME}")"
  CMS_DOMAIN="$(project_cms_domain "${PROJECT_NAME}")"

  # A failed scaffold used to leave a half-written directory behind that
  # `gosite remove` could not clean up, because the marker file is written last.
  # Remove it on any non-zero exit instead.
  trap 'rm -rf "${PROJECT_DIR}"; err "Scaffold failed; removed ${PROJECT_DIR}."' ERR

  info "Creating project '${PROJECT_NAME}'"
  debug "module=${PROJECT_MODULE} app=${APP_PORT} cms=${CMS_PORT}"

  mkdir -p "${PROJECT_DIR}"/{config,handlers,cache,cms,models,views/pages,views/components,static}
  # Keep static/ in Git so the production COPY stage always finds it.
  touch "${PROJECT_DIR}/static/.gitkeep"

  # Cockpit's storage is bind-mounted in development so content is visible and
  # backed up with the project. A bind mount hides whatever the image ships at
  # that path, so the skeleton it expects has to exist on the host up front -
  # otherwise Cockpit fails on a missing storage/cache directory.
  local sub
  for sub in cache data logs tmp uploads; do
    mkdir -p "${PROJECT_DIR}/cockpit-storage/${sub}"
    touch "${PROJECT_DIR}/cockpit-storage/${sub}/.gitkeep"
  done
  chmod -R 0777 "${PROJECT_DIR}/cockpit-storage"

  _write_go_mod        "${PROJECT_DIR}"
  _write_main_go       "${PROJECT_DIR}"
  _write_app           "${PROJECT_DIR}"
  _write_router        "${PROJECT_DIR}"
  _write_config        "${PROJECT_DIR}"
  _write_handlers      "${PROJECT_DIR}"
  _write_cache         "${PROJECT_DIR}"
  _write_cms           "${PROJECT_DIR}"
  _write_models        "${PROJECT_DIR}"
  _write_views         "${PROJECT_DIR}"
  _write_air_config    "${PROJECT_DIR}"
  _write_dockerfiles   "${PROJECT_DIR}"
  _write_compose_dev   "${PROJECT_DIR}"
  _write_compose_prod  "${PROJECT_DIR}"
  _write_env_files     "${PROJECT_DIR}"
  _write_meta_files    "${PROJECT_DIR}"

  local f
  while IFS= read -r f; do render_placeholders "${f}"; done < <(
    find "${PROJECT_DIR}" -type f ! -name '*.png' ! -name '*.ico'
  )

  # go.sum must be committed: the production image builds with the default
  # GOFLAGS and refuses to compile without verified module checksums.
  _resolve_dependencies "${PROJECT_DIR}"

  # Issue the local TLS certificate covering <name>.test and cms.<name>.test.
  ensure_project_cert "${PROJECT_NAME}" || true

  # Index the project so it can be reached by name from any directory.
  registry_register "${PROJECT_DIR}"

  trap - ERR
  ok "Project scaffolded at ${PROJECT_DIR}"
  cat <<EOF

$(printf "${C_BOLD}Next steps${C_NC}")
  1. gosite infra up                 $(printf "${C_DIM}# shared Postgres + Redis on ${GOSITE_NETWORK}${C_NC}")
  2. gosite start ${PROJECT_NAME}      $(printf "${C_DIM}# or: gosite cd ${PROJECT_NAME}${C_NC}")
  3. App  -> https://${APP_DOMAIN}   $(printf "${C_DIM}(air hot reload)${C_NC}")
     CMS  -> https://${CMS_DOMAIN}   $(printf "${C_DIM}(Cockpit)${C_NC}")
     $(printf "${C_DIM}Also on http://localhost:${APP_PORT} and http://localhost:${CMS_PORT}.${C_NC}")

$(printf "${C_DIM}Production: push to Git and point Coolify at docker-compose.prod.yml.${C_NC}")
EOF
}

# -----------------------------------------------------------------------------
# Resolves the module graph and writes go.sum, which the production build needs:
# it compiles with the default GOFLAGS and refuses to build without verified
# checksums. Prefers the host toolchain, falls back to a throwaway container so
# the result is identical whether or not Go is installed locally.
_resolve_dependencies() {
  local dir="$1"
  info "Resolving Go dependencies (writing go.sum)"

  if command -v go >/dev/null 2>&1; then
    ( cd "${dir}" && go mod tidy ) && { ok "go.sum written."; return 0; }
    warn "Host 'go mod tidy' failed; retrying inside a container."
  fi

  if docker run --rm -v "${dir}:/src" -w /src golang:1.26-alpine \
       sh -c 'apk add --no-cache git >/dev/null && go mod tidy'; then
    ok "go.sum written."
    return 0
  fi

  warn "Could not resolve dependencies (offline?). Run 'go mod tidy' in ${dir} before deploying."
  return 0
}

# -----------------------------------------------------------------------------
_write_go_mod() {
  cat > "$1/go.mod" <<'EOF'
module __MODULE__

// Echo v5 requires Go 1.25 or newer.
go 1.25

require (
	github.com/labstack/echo/v5 v5.3.1
	github.com/redis/go-redis/v9 v9.22.0
)
EOF
}

# -----------------------------------------------------------------------------
# Entry point: read configuration, build the app, start the server. Nothing
# else lives here, so there is exactly one place to look for startup order.
_write_main_go() {
  cat > "$1/main.go" <<'EOF'
// Command __PROJECT__ is a Go + Cockpit CMS site: server-rendered HTML with
// htmx and Alpine.js, and a Redis cache in front of the CMS.
//
// Reading order: main.go (startup) -> app.go (dependencies) -> router.go
// (every route) -> handlers/ (one file per handler).
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/labstack/echo/v5"

	"__MODULE__/config"
)

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))

	app, err := NewApp(config.Load(), log)
	if err != nil {
		log.Error("startup failed", "err", err)
		os.Exit(1)
	}
	defer app.Close()

	// Echo v5 handles graceful shutdown itself: Start stops accepting
	// connections when the context is cancelled, then waits up to
	// GracefulTimeout for in-flight requests. There is no Shutdown call in v5.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	start := echo.StartConfig{
		Address:         ":" + app.Config.Port,
		HideBanner:      true,
		GracefulTimeout: 10 * time.Second,
	}
	if err := start.Start(ctx, NewRouter(app)); err != nil {
		log.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
EOF
}

# -----------------------------------------------------------------------------
# The composition root: build every dependency once and hand them to the
# handlers. Nothing here knows about HTTP.
_write_app() {
  cat > "$1/app.go" <<'EOF'
package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"

	"__MODULE__/cache"
	"__MODULE__/cms"
	"__MODULE__/config"
	"__MODULE__/handlers"
	"__MODULE__/views"
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

	renderer := views.NewRenderer()

	return &App{
		Config:   cfg,
		Log:      log,
		Redis:    rdb,
		Renderer: renderer,
		Handlers: handlers.New(handlers.Deps{
			Config:   cfg,
			Log:      log,
			Cache:    cache.New(rdb, log),
			CMS:      cms.New(cfg, log),
			Renderer: renderer,
			Redis:    rdb,
		}),
	}, nil
}

func (a *App) Close() error { return a.Redis.Close() }
EOF
}

# -----------------------------------------------------------------------------
# Every route in one table. Adding an endpoint means one line here plus one
# file in handlers/, and the whole surface of the app stays readable.
_write_router() {
  cat > "$1/router.go" <<'EOF'
package main

import (
	"github.com/labstack/echo/v5"
	"github.com/labstack/echo/v5/middleware"
)

// NewRouter wires middleware and routes. This is the single source of truth
// for the app's HTTP surface - nothing registers routes anywhere else.
func NewRouter(app *App) *echo.Echo {
	e := echo.New()
	e.Renderer = app.Renderer

	e.Use(middleware.Recover())
	e.Use(middleware.RequestLogger())
	e.Use(middleware.Gzip())

	e.Static("/static", "static")

	h := app.Handlers

	// --- routes --------------------------------------------------------------
	e.GET("/", h.Home)                   // the page, served from cache
	e.POST("/cache/purge", h.PurgeCache) // htmx button + Cockpit webhook
	e.GET("/healthz", h.Health)          // liveness, checks Redis

	return e
}
EOF
}

# -----------------------------------------------------------------------------
# Environment settings in one place, so no os.Getenv call is ever buried in a
# handler. Its own package because handlers, cms and main all read it.
_write_config() {
  cat > "$1/config/config.go" <<'EOF'
// Package config reads every environment-provided setting exactly once.
package config

import "os"

type Config struct {
	Port         string
	RedisURL     string
	CockpitURL   string
	CockpitToken string
}

func Load() Config {
	return Config{
		Port:         env("PORT", "8080"),
		RedisURL:     env("REDIS_URL", "redis://__REDIS_HOST__:__REDIS_PORT__/0"),
		CockpitURL:   env("COCKPIT_URL", "http://__PROJECT__-cms:80"),
		CockpitToken: os.Getenv("COCKPIT_API_TOKEN"),
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
EOF
}

# -----------------------------------------------------------------------------
# HANDLERS. One file per route, plus the shared pieces: the dependency struct
# and the Response helper every handler replies through.
_write_handlers() {
  cat > "$1/handlers/handlers.go" <<'EOF'
// Package handlers holds one file per route. Everything shared between them
// lives here (dependencies) and in response.go (how they reply), so a new
// endpoint is a new file and a line in router.go - nothing else changes.
package handlers

import (
	"log/slog"

	"github.com/redis/go-redis/v9"

	"__MODULE__/cache"
	"__MODULE__/cms"
	"__MODULE__/config"
	"__MODULE__/views"
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
EOF

  cat > "$1/handlers/response.go" <<'EOF'
package handlers

import (
	"net/http"

	"github.com/labstack/echo/v5"
)

// Response is a thin layer over Echo's own response helpers
// (https://echo.labstack.com/guide/response/): Context.HTMLBlob, Context.String
// and Context.JSON already know how to set content types and write the body,
// so nothing here re-implements them.
//
// What it does add is the bookkeeping this app would otherwise repeat in every
// handler: the cache header, and logging an error while replying with a
// message that is safe to show a client.
//
// Usage: return h.reply(c).Page(html, cached)
type Response struct {
	h *Handlers
	c *echo.Context
}

func (h *Handlers) reply(c *echo.Context) Response {
	return Response{h: h, c: c}
}

// Page sends a rendered HTML page and records whether it came from the cache.
// The X-Cache header makes the cache observable in devtools without putting
// anything in the markup.
func (r Response) Page(html []byte, cached bool) error {
	status := "MISS"
	if cached {
		status = "HIT"
	}
	r.c.Response().Header().Set("X-Cache", status)
	return r.c.HTMLBlob(http.StatusOK, html)
}

// Text sends a plain-text response, for endpoints with nothing to render.
func (r Response) Text(status int, message string) error {
	return r.c.String(status, message)
}

// JSON sends a JSON response, for when this app grows an API route.
func (r Response) JSON(status int, body any) error {
	return r.c.JSON(status, body)
}

// Fail logs the real error and returns a generic message to the client, so
// internal details never leak and no handler has to remember to do both.
// Echo's error handler turns the returned HTTPError into the response.
func (r Response) Fail(status int, message string, err error) error {
	if err != nil {
		r.h.Log.Error(message, "err", err, "path", r.c.Request().URL.Path)
	}
	return echo.NewHTTPError(status, message)
}
EOF

  cat > "$1/handlers/home.go" <<'EOF'
package handlers

import (
	"bytes"
	"net/http"

	"github.com/labstack/echo/v5"
)

// homeCacheKey is the Redis key holding the fully rendered home page.
const homeCacheKey = "__PROJECT__:home_html"

// Home serves the page through the cache.
//
// The cache-aside dance lives in cache.Cache.HTML; this handler only says what
// to render when the cache is cold. On a hit none of the closure runs, which
// is why a hit costs microseconds.
func (h *Handlers) Home(c *echo.Context) error {
	html, cached, err := h.Cache.HTML(c.Request().Context(), homeCacheKey, func() ([]byte, error) {
		articles, err := h.CMS.Articles(c.Request().Context())
		if err != nil {
			return nil, err
		}
		var buf bytes.Buffer
		err = h.Renderer.Page(&buf, "home", map[string]any{
			"Title":    "__PROJECT__",
			"Articles": articles,
		})
		return buf.Bytes(), err
	})
	if err != nil {
		return h.reply(c).Fail(http.StatusBadGateway, "could not load the page", err)
	}
	return h.reply(c).Page(html, cached)
}
EOF

  cat > "$1/handlers/purge.go" <<'EOF'
package handlers

import (
	"net/http"

	"github.com/labstack/echo/v5"
)

// PurgeCache drops the cached page. It is both the target of the htmx button
// on the page and a webhook Cockpit can call when an editor publishes, so the
// site updates without waiting out the TTL.
func (h *Handlers) PurgeCache(c *echo.Context) error {
	// The token is only enforced when configured, which keeps the htmx button
	// working locally while still protecting a deployed site.
	if h.Config.CockpitToken != "" && c.Request().Header.Get("X-Api-Key") != h.Config.CockpitToken {
		return h.reply(c).Fail(http.StatusUnauthorized, "invalid token", nil)
	}
	if err := h.Cache.Purge(c.Request().Context(), homeCacheKey); err != nil {
		return h.reply(c).Fail(http.StatusInternalServerError, "purge failed", err)
	}
	return h.reply(c).Text(http.StatusOK, "purged")
}
EOF

  cat > "$1/handlers/health.go" <<'EOF'
package handlers

import (
	"net/http"

	"github.com/labstack/echo/v5"
)

// Health reports liveness. It checks Redis because the site is unusable
// without it, so an orchestrator restarting the container is the right call.
func (h *Handlers) Health(c *echo.Context) error {
	if err := h.Redis.Ping(c.Request().Context()).Err(); err != nil {
		return h.reply(c).Fail(http.StatusServiceUnavailable, "redis unavailable", err)
	}
	return h.reply(c).Text(http.StatusOK, "ok")
}
EOF
}

# -----------------------------------------------------------------------------
# The cache-aside pattern, written once. Every cached endpoint calls HTML and
# passes a render function, so no handler repeats Get/Set/error handling.
_write_cache() {
  cat > "$1/cache/cache.go" <<'EOF'
// Package cache is a small cache-aside helper over Redis.
package cache

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"
)

// ttl keeps Cockpit almost entirely out of the request path while staying
// fresh enough for editorial work. Publishing calls /cache/purge anyway.
const ttl = 10 * time.Minute

type Cache struct {
	rdb *redis.Client
	log *slog.Logger
}

func New(rdb *redis.Client, log *slog.Logger) *Cache {
	return &Cache{rdb: rdb, log: log}
}

// HTML returns the cached bytes for key, calling render only on a miss:
//
//	1. GET the key. On a hit, return immediately - no CMS call, no rendering.
//	2. On a miss, run render, SET the result with a TTL and return it.
//
// A Redis failure is never fatal: render still runs and the request is just
// slower, which keeps the site up when the cache is down.
func (c *Cache) HTML(ctx context.Context, key string, render func() ([]byte, error)) ([]byte, bool, error) {
	start := time.Now()

	cached, err := c.rdb.Get(ctx, key).Bytes()
	if err == nil {
		c.log.Info("cache hit", "key", key, "elapsed", time.Since(start))
		return cached, true, nil
	}
	if !errors.Is(err, redis.Nil) {
		c.log.Warn("cache read failed, rendering anyway", "key", key, "err", err)
	}

	fresh, err := render()
	if err != nil {
		return nil, false, err
	}

	if err := c.rdb.Set(ctx, key, fresh, ttl).Err(); err != nil {
		c.log.Warn("cache write failed", "key", key, "err", err)
	}
	c.log.Info("cache miss", "key", key, "elapsed", time.Since(start))
	return fresh, false, nil
}

// Purge removes keys, so an editor never has to wait out the TTL.
func (c *Cache) Purge(ctx context.Context, keys ...string) error {
	return c.rdb.Del(ctx, keys...).Err()
}
EOF
}

# -----------------------------------------------------------------------------
# The only package that knows how to talk to Cockpit.
_write_cms() {
  cat > "$1/cms/cms.go" <<'EOF'
// Package cms is the Cockpit CMS client. Everything the app knows about the
// CMS lives here, so the rest of the code never sees an HTTP call.
package cms

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"__MODULE__/config"
	"__MODULE__/models"
)

type Client struct {
	baseURL string
	token   string
	http    *http.Client
	log     *slog.Logger
}

func New(cfg config.Config, log *slog.Logger) *Client {
	return &Client{
		baseURL: cfg.CockpitURL,
		token:   cfg.CockpitToken,
		// Always bound the CMS call: without a timeout a slow Cockpit would
		// hold every request open, cache or not.
		http: &http.Client{Timeout: 5 * time.Second},
		log:  log,
	}
}

// Articles fetches the "articles" collection.
//
// Cockpit exposes collections at /api/content/items/<collection> and
// authenticates with an api-key header. Create that collection in the Cockpit
// admin with the fields in models.Article and this returns real content.
//
// Until it exists the request fails, so a fresh project falls back to sample
// articles and logs why - the site renders something on the very first run
// instead of an error page.
func (c *Client) Articles(ctx context.Context) ([]models.Article, error) {
	articles, err := c.fetchArticles(ctx)
	if err != nil {
		c.log.Warn("cockpit unavailable, serving sample content", "err", err)
		return sampleArticles()
	}
	return articles, nil
}

func (c *Client) fetchArticles(ctx context.Context) ([]models.Article, error) {
	url := c.baseURL + "/api/content/items/articles"

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("api-key", c.token)
	req.Header.Set("Accept", "application/json")

	res, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()

	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("cockpit returned %s", res.Status)
	}

	var articles []models.Article
	if err := json.NewDecoder(res.Body).Decode(&articles); err != nil {
		return nil, err
	}
	return articles, nil
}

// sampleArticles keeps a fresh project renderable before any content exists.
// Delete it once the Cockpit collection is populated.
func sampleArticles() ([]models.Article, error) {
	data := []byte(`[
		{"_id":"1","title":"Go and htmx without a build step","excerpt":"Server-rendered HTML, no bundler in sight.","body":"The server returns HTML and htmx swaps it into the DOM. No client-side router, no hydration, no build pipeline to maintain.","slug":"go-htmx","published":true},
		{"_id":"2","title":"Cockpit as a headless CMS","excerpt":"Let editors work without coupling the frontend.","body":"Cockpit exposes a REST API that the Go server consumes. Content people get an admin UI; the frontend stays plain server-rendered HTML.","slug":"cockpit-headless","published":true},
		{"_id":"3","title":"Cache-aside with Redis","excerpt":"Keep the CMS off the hot path.","body":"The rendered page is stored in Redis with a ten minute TTL, so a cache hit skips both the CMS call and the template render.","slug":"redis-cache-aside","published":true}
	]`)

	var articles []models.Article
	if err := json.Unmarshal(data, &articles); err != nil {
		return nil, err
	}
	return articles, nil
}
EOF
}

# -----------------------------------------------------------------------------
# Data shapes only: no Redis, no HTTP, no HTML. Kept in its own package so the
# templates and the CMS client can share it without importing each other.
_write_models() {
  cat > "$1/models/article.go" <<'EOF'
// Package models holds the data structures the application works with.
// It describes *what* the data is, never how it is fetched or rendered.
package models

import "time"

// Article maps one item of the "articles" collection in Cockpit CMS. The json
// tags match Cockpit's field names.
type Article struct {
	ID        string    `json:"_id"`
	Title     string    `json:"title"`
	Excerpt   string    `json:"excerpt"`
	Body      string    `json:"body"`
	Slug      string    `json:"slug"`
	Published bool      `json:"published"`
	Created   time.Time `json:"_created"`
}

// URL is the canonical path of the article, so templates never build paths.
func (a Article) URL() string { return "/articles/" + a.Slug }

// CockpitResponse is the envelope Cockpit returns for a collection query.
type CockpitResponse struct {
	Articles []Article `json:"entries"`
	Total    int       `json:"total"`
}
EOF
}

# -----------------------------------------------------------------------------
# Markup only, one component per file, rendered with the standard library's
# html/template and embedded with go:embed.
_write_views() {
  cat > "$1/views/render.go" <<'EOF'
// Package views owns every piece of markup and the renderer that turns it into
// HTML. It never touches Redis, the CMS or the request: it is handed
// already-resolved data and decides only how that data looks.
package views

import (
	"embed"
	"fmt"
	"html/template"
	"io"

	"github.com/labstack/echo/v5"
)

// Templates are embedded so the binary is self-contained: nothing to copy into
// the image, and no chance of the markup drifting from the code.
//
//go:embed layout.html pages/*.html components/*.html
var files embed.FS

// Renderer implements echo.Renderer. Each entry is a page: layout + page body
// + every component, parsed once.
type Renderer struct {
	pages map[string]*template.Template
}

// NewRenderer parses every template at startup and panics on a malformed one,
// so a broken template fails the deploy instead of the first request.
func NewRenderer() *Renderer {
	// Every page is parsed as layout + that page + all components, so a page
	// can use any component without declaring anything.
	page := func(name string) *template.Template {
		return template.Must(template.ParseFS(files,
			"layout.html",
			"pages/"+name+".html",
			"components/*.html",
		))
	}

	return &Renderer{
		pages: map[string]*template.Template{
			"home": page("home"),
		},
	}
}

// Render satisfies echo.Renderer, so handlers can use c.Render directly.
func (r *Renderer) Render(_ *echo.Context, w io.Writer, name string, data any) error {
	return r.Page(w, name, data)
}

// Page renders to any writer, which is what lets the cache layer render into a
// buffer and store exactly the bytes that get served.
func (r *Renderer) Page(w io.Writer, name string, data any) error {
	t, ok := r.pages[name]
	if !ok {
		return fmt.Errorf("unknown page: %s", name)
	}
	return t.ExecuteTemplate(w, "layout", data)
}
EOF

  cat > "$1/views/layout.html" <<'EOF'
{{/*
  Base HTML document: Tailwind CSS, htmx and Alpine.js, and nothing else.
  Every page fills in the "content" block.

  The libraries are loaded from a CDN to keep local development build-free.
  Before going to production, vendor them into /static so the site does not
  depend on third-party uptime and a CSP can be tightened.
*/}}
{{define "layout"}}<!DOCTYPE html>
<html lang="en" class="h-full">
<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<title>{{.Title}}</title>
	<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.3.3"></script>
	<script src="https://unpkg.com/htmx.org@2.0.10"></script>
	<script defer src="https://unpkg.com/alpinejs@3.15.12/dist/cdn.min.js"></script>
	<style>[x-cloak]{display:none !important}</style>
</head>
<body class="h-full bg-slate-50 text-slate-900 antialiased">
	<div class="mx-auto max-w-3xl px-6 py-12">
		{{template "content" .}}
	</div>
</body>
</html>{{end}}
EOF

  cat > "$1/views/pages/home.html" <<'EOF'
{{/* The home page: a header with the purge button, then the article list. */}}
{{define "content"}}
<header class="mb-8 flex items-center justify-between">
	<h1 class="text-3xl font-bold tracking-tight">{{.Title}}</h1>
	{{template "purge-button" .}}
</header>

<ul class="space-y-4" x-data="{ open: null }">
	{{- range .Articles }}
	{{template "card" .}}
	{{- else }}
	{{template "empty" "No articles published yet."}}
	{{- end }}
</ul>
{{end}}
EOF

  cat > "$1/views/components/card.html" <<'EOF'
{{/*
  A single article card. Expects an Alpine `open` scope from its parent list,
  which is what lets one card be expanded at a time.
*/}}
{{define "card"}}
<li class="rounded-lg border border-slate-200 bg-white p-5 shadow-sm">
	<button class="w-full text-left" @click="open = open === '{{.ID}}' ? null : '{{.ID}}'">
		<h2 class="text-lg font-semibold">{{.Title}}</h2>
		<p class="mt-1 text-sm text-slate-600">{{.Excerpt}}</p>
	</button>

	<div x-show="open === '{{.ID}}'" x-cloak>
		<p class="mt-3 border-t border-slate-100 pt-3 text-sm text-slate-700">{{.Body}}</p>
		<a class="mt-2 inline-block text-sm text-blue-600 hover:underline" href="{{.URL}}">Read more</a>
	</div>
</li>
{{end}}
EOF

  cat > "$1/views/components/button.html" <<'EOF'
{{/*
  Purges the cached page and reloads, so the next render comes from the CMS.
  htmx posts the request; Alpine only handles the "Purging..." label.
*/}}
{{define "purge-button"}}
<button
	class="rounded-md bg-slate-900 px-4 py-2 text-sm font-medium text-white hover:bg-slate-700"
	x-data="{ busy: false }"
	x-text="busy ? 'Purging...' : 'Purge cache'"
	hx-post="/cache/purge"
	hx-swap="none"
	@htmx:before-request="busy = true"
	@htmx:after-request="window.location.reload()"
>Purge cache</button>
{{end}}
EOF

  cat > "$1/views/components/state.html" <<'EOF'
{{/* Empty state, kept separate so copy changes never touch logic. */}}
{{define "empty"}}
<li class="text-slate-500">{{.}}</li>
{{end}}
EOF
}

# -----------------------------------------------------------------------------
_write_air_config() {
  cat > "$1/.air.toml" <<'EOF'
# air - hot reload for local development inside the dev container.
root = "."
tmp_dir = "tmp"

[build]
  cmd        = "go build -o ./tmp/main ."
  entrypoint = "./tmp/main"
  delay    = 300
  include_ext  = ["go", "html", "css", "js"]
  exclude_dir  = ["tmp", "static/vendor", ".git", "cockpit-storage"]
  exclude_regex = ["_test\\.go"]
  stop_on_error = true
  send_interrupt = true
  kill_delay = "1s"

[log]
  time = true

[misc]
  clean_on_exit = true
EOF
}

# -----------------------------------------------------------------------------
_write_dockerfiles() {
  # Production image: compile Templ + a static binary, ship it on alpine.
  cat > "$1/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1

# --- stage 1: build ----------------------------------------------------------
FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git ca-certificates
WORKDIR /src

# Dependencies first so the module cache survives source-only changes.
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 produces a fully static binary that runs on a bare alpine.
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath -ldflags="-s -w" \
      -o /out/app .

# --- stage 2: runtime --------------------------------------------------------
FROM alpine:latest

RUN apk add --no-cache ca-certificates tzdata wget \
 && adduser -D -u 10001 app

WORKDIR /app
COPY --from=builder /out/app /app/app
COPY --from=builder /src/static /app/static

USER app
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/app/app"]
EOF

  # Development image: toolchain + air, source is bind-mounted at runtime.
  cat > "$1/Dockerfile.dev" <<'EOF'
# syntax=docker/dockerfile:1
# Local development only. The source tree is bind-mounted, so this image just
# carries the toolchain and runs air for hot reload.
FROM golang:1.26-alpine

RUN apk add --no-cache git curl

RUN go install github.com/air-verse/air@v1.67.4

WORKDIR /app
ENV PORT=8080 CGO_ENABLED=0
EXPOSE 8080

CMD ["air", "-c", ".air.toml"]
EOF

  cat > "$1/.dockerignore" <<'EOF'
.git
.gitignore
tmp/
cockpit-storage/
.env
.env.*
!.env.example
docker-compose*.yml
Dockerfile.dev
README.md
EOF
}

# -----------------------------------------------------------------------------
_write_compose_dev() {
  # LOCAL ONLY: ports mapped to localhost, source bind-mounted, air hot reload,
  # attached to the external shared network for Postgres and Redis.
  cat > "$1/docker-compose.yml" <<'EOF'
# Local development stack for __PROJECT__.
# Postgres and Redis are NOT defined here: they are the shared gosite
# infrastructure, reachable by container name on the external network.
# Start them with `gosite infra up`.

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile.dev
    container_name: __PROJECT__-app
    restart: unless-stopped
    env_file: .env
    environment:
      PORT: "8080"
      APP_ENV: development
      REDIS_URL: "redis://__REDIS_HOST__:__REDIS_PORT__/0"
      COCKPIT_URL: "http://__PROJECT__-cms:80"
    # Host ports stay mapped as a fallback; the domain below is the main entry.
    ports:
      - "__APP_PORT__:8080"
    labels:
      - traefik.enable=true
      - traefik.docker.network=__NETWORK__
      - traefik.http.routers.__PROJECT__-app.rule=Host(`__DOMAIN__`)
      - traefik.http.routers.__PROJECT__-app.entrypoints=websecure
      - traefik.http.routers.__PROJECT__-app.tls=true
      - traefik.http.services.__PROJECT__-app.loadbalancer.server.port=8080
    volumes:
      # Live source mount: air rebuilds on save.
      - .:/app
      # Named volumes keep the module cache and build artifacts off the host FS.
      - __PROJECT__-gomod:/go/pkg/mod
      - __PROJECT__-tmp:/app/tmp
    depends_on:
      - cms
    networks:
      - gosite

  cms:
    image: cockpithq/cockpit:core-2.14.0
    container_name: __PROJECT__-cms
    restart: unless-stopped
    environment:
      COCKPIT_DATABASE_SERVER: "mongolite://storage/data"
      COCKPIT_SESSION_NAME: "__PROJECT__"
    ports:
      - "__CMS_PORT__:80"
    labels:
      - traefik.enable=true
      - traefik.docker.network=__NETWORK__
      - traefik.http.routers.__PROJECT__-cms.rule=Host(`__CMS_DOMAIN__`)
      - traefik.http.routers.__PROJECT__-cms.entrypoints=websecure
      - traefik.http.routers.__PROJECT__-cms.tls=true
      - traefik.http.services.__PROJECT__-cms.loadbalancer.server.port=80
    volumes:
      - ./cockpit-storage:/var/www/html/storage
    networks:
      - gosite

volumes:
  __PROJECT__-gomod:
  __PROJECT__-tmp:

networks:
  gosite:
    external: true
    name: __NETWORK__
EOF
}

# -----------------------------------------------------------------------------
_write_compose_prod() {
  # COOLIFY: no host port mappings, Traefik labels, all config through env vars
  # that are set from the Coolify UI.
  cat > "$1/docker-compose.prod.yml" <<'EOF'
# Production stack for __PROJECT__, in Coolify's native compose format.
#
# No host ports are published: Coolify's Traefik proxy routes to the container
# port declared in the labels below. Every value comes from the environment,
# so it is configured from the Coolify UI (or a .env at the service level).
#
# Required variables in Coolify:
#   SERVICE_FQDN_APP        e.g. https://__PROJECT__.example.com
#   SERVICE_FQDN_CMS        e.g. https://cms.__PROJECT__.example.com
#   REDIS_URL               redis://<redis-service>:6379/0
#   DATABASE_URL            postgres://user:pass@<pg-service>:5432/__PROJECT__
#   COCKPIT_API_TOKEN       shared token between the app and Cockpit

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    environment:
      - APP_ENV=production
      - PORT=8080
      - SERVICE_FQDN_APP
      - REDIS_URL=${REDIS_URL}
      - DATABASE_URL=${DATABASE_URL}
      - COCKPIT_URL=${COCKPIT_URL:-http://cms:80}
      - COCKPIT_API_TOKEN=${COCKPIT_API_TOKEN}
    labels:
      # Tells Coolify this service is built from the repository Dockerfile.
      - coolify.managed=true
      - coolify.image=true
      - traefik.enable=true
      - traefik.http.routers.__PROJECT__-app.rule=Host(`${SERVICE_FQDN_APP}`)
      - traefik.http.routers.__PROJECT__-app.entrypoints=https
      - traefik.http.routers.__PROJECT__-app.tls=true
      - traefik.http.routers.__PROJECT__-app.tls.certresolver=letsencrypt
      - traefik.http.services.__PROJECT__-app.loadbalancer.server.port=8080
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
    depends_on:
      - cms

  cms:
    image: cockpithq/cockpit:core-2.14.0
    restart: unless-stopped
    environment:
      - COCKPIT_DATABASE_SERVER=${COCKPIT_DATABASE_SERVER:-mongolite://storage/data}
      - COCKPIT_SESSION_NAME=__PROJECT__
    volumes:
      - cockpit-storage:/var/www/html/storage
    labels:
      - coolify.managed=true
      - traefik.enable=true
      - traefik.http.routers.__PROJECT__-cms.rule=Host(`${SERVICE_FQDN_CMS}`)
      - traefik.http.routers.__PROJECT__-cms.entrypoints=https
      - traefik.http.routers.__PROJECT__-cms.tls=true
      - traefik.http.routers.__PROJECT__-cms.tls.certresolver=letsencrypt
      - traefik.http.services.__PROJECT__-cms.loadbalancer.server.port=80

volumes:
  cockpit-storage:
EOF
}

# -----------------------------------------------------------------------------
_write_env_files() {
  cat > "$1/.env" <<'EOF'
# Local development environment. Not committed.
APP_ENV=development
PORT=8080
REDIS_URL=redis://__REDIS_HOST__:__REDIS_PORT__/0
DATABASE_URL=postgres://__PG_USER__:__PG_PASSWORD__@__PG_HOST__:__PG_PORT__/__PROJECT__?sslmode=disable
COCKPIT_URL=http://__PROJECT__-cms:80
COCKPIT_API_TOKEN=__CMS_TOKEN__
EOF

  cat > "$1/.env.example" <<'EOF'
# Copy to .env for local dev; set the same keys in the Coolify UI for prod.
APP_ENV=development
PORT=8080
REDIS_URL=redis://__REDIS_HOST__:__REDIS_PORT__/0
DATABASE_URL=postgres://user:password@host:5432/__PROJECT__?sslmode=disable
COCKPIT_URL=http://__PROJECT__-cms:80
COCKPIT_API_TOKEN=change-me
EOF

  # Marker file consumed by list/start/stop/remove.
  cat > "$1/${GOSITE_MARKER}" <<'EOF'
GOSITE_PROJECT=__PROJECT__
GOSITE_MODULE=__MODULE__
GOSITE_APP_PORT=__APP_PORT__
GOSITE_CMS_PORT=__CMS_PORT__
GOSITE_APP_DOMAIN=__DOMAIN__
GOSITE_CMS_DOMAIN=__CMS_DOMAIN__
GOSITE_NETWORK=__NETWORK__
EOF
}

# -----------------------------------------------------------------------------
_write_meta_files() {
  cat > "$1/.gitignore" <<'EOF'
.env
tmp/
cockpit-storage/
/app
EOF

  cat > "$1/Makefile" <<'EOF'
.PHONY: dev build tidy

dev:   ## Hot reload on the host (containers: use `gosite start`)
	air -c .air.toml

build: ## Static production binary (templates are embedded)
	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ./tmp/app .

tidy:
	go mod tidy
EOF

  cat > "$1/README.md" <<'EOF'
# __PROJECT__

Go (Echo + htmx + Alpine.js + Templ + Tailwind) + Cockpit CMS monolith, with
Redis cache-aside in front of the CMS.

## Structure

One file per responsibility. Handlers live in their own package, one file per
route, so the file never becomes a dumping ground as the app grows:

```
main.go            Startup: read config, build the app, start the server.
app.go             Composition root: build every dependency once.
router.go          Every route and middleware. The whole HTTP surface.
config/            Environment settings, read exactly once.
handlers/          One file per route.
  handlers.go      Deps + the receiver they hang off.
  response.go      How this app replies (see below).
  home.go          GET /
  purge.go         POST /cache/purge
  health.go        GET /healthz
cache/             Cache-aside over Redis, written once.
cms/               The Cockpit API client. The only package that calls the CMS.
models/            Data shapes. No Redis, no HTTP, no HTML.
views/             Markup, embedded with go:embed.
  render.go        Parses every template at startup.
  layout.html      Base document (Tailwind, htmx, Alpine).
  pages/           One file per page.
  components/      Reusable pieces, one per file.
static/            Assets served at /static.
```

Reading order: `main.go` -> `app.go` -> `router.go` -> `handlers/`.

Adding an endpoint is one file in `handlers/` and one line in `router.go`.
Adding a page is one template in `views/pages/`. Nothing else changes.

Data flows one way: `cms` fetches from Cockpit into `models`, a handler passes
those to `views`, and the rendered HTML goes into `cache`.

## Responses

Handlers reply through the small `Response` helper in `handlers/response.go`
rather than repeating the same bookkeeping:

```go
return h.reply(c).Page(html, cached)                       // HTML + X-Cache header
return h.reply(c).Text(http.StatusOK, "purged")            // plain text
return h.reply(c).Fail(http.StatusBadGateway, "...", err)  // log + safe message
```

It is a thin layer over [Echo's own response helpers][echo-response] -
`Context.HTMLBlob`, `Context.String` and `Context.JSON` do the actual writing.
What it adds is the cache header and, in `Fail`, logging the real error while
returning only a message that is safe to show a client.

[echo-response]: https://echo.labstack.com/guide/response/

## Routes

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/` | The page, served from the Redis cache |
| POST | `/cache/purge` | Invalidate the cache (htmx button + Cockpit webhook) |
| GET | `/healthz` | Liveness, checks Redis |

## Cockpit

`cms.go` calls `GET $COCKPIT_URL/api/content/items/articles` with an `api-key`
header. Create an `articles` collection in the Cockpit admin with the fields in
`models/article.go` and the site renders real content.

Until that collection exists the request fails and the app falls back to sample
articles, logging why - so a fresh project renders something on the first run
instead of an error page. Delete `sampleArticles` in `cms.go` once you have
real content.

## Local development

```bash
gosite infra up      # shared Postgres + Redis on __NETWORK__
gosite start         # app (air hot reload) + Cockpit
```

| Service | URL |
| --- | --- |
| App | http://localhost:__APP_PORT__ |
| Cockpit | http://localhost:__CMS_PORT__ |

Editing any `.go` or `.html` file (including a single component) triggers an
air rebuild in about 3 seconds. Templates are embedded with `go:embed`, so the
production image is a single self-contained binary.

## Caching

`GET /` is served from Redis (key `<project>:index_html`, TTL 10m). The cached
value is the *fully rendered page*, so a hit skips the CMS call and the
template render entirely. The `X-Cache` response header reports `HIT` or
`MISS`.

The purge button on the page posts to `/cache/purge`; point a Cockpit publish
webhook at the same route (header `X-Api-Key: $COCKPIT_API_TOKEN`) so editors
never wait out the TTL.

The mechanics live in `cache.go` as a single `Cache.HTML(key, render)` helper,
so caching another page is one call, not another copy of the same Get/Set
dance.

## Production (Coolify)

`docker-compose.prod.yml` publishes no host ports and takes every value from
the environment. In Coolify: create a Docker Compose resource from this repo,
select `docker-compose.prod.yml`, then set `SERVICE_FQDN_APP`,
`SERVICE_FQDN_CMS`, `REDIS_URL`, `DATABASE_URL` and `COCKPIT_API_TOKEN`.
EOF
}
