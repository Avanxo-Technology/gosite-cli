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
# Note: __REDIS_PORT__ renders to the IN-NETWORK port (6379), not the
# host-published one. Project containers always reach the shared services by
# container name on gosite-network, never through the host.

# Template writers (placeholders, compose files, addons) are shared with `sync`
# so an existing project can be re-rendered from the same sources of truth.
# shellcheck source=../lib/templates.sh
source "${GOSITE_ROOT}/lib/templates.sh"

cmd_create() {
  local PROJECT_NAME="" here=0 ADDONS="" INSTALL_ADDONS=0 ADDONS_PROMPT=1
  # Tailwind is on by default; --no-tailwind swaps it for a small stylesheet.
  # Either way the generated markup is clean: no orphan utility classes.
  TAILWIND=1
  ADDONS_ENABLED=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --here)         here=1; shift ;;
      --no-tailwind)  TAILWIND=0; shift ;;
      --tailwind)     TAILWIND=1; shift ;;
      --addons)       INSTALL_ADDONS=1; ADDONS_ENABLED=1; ADDONS_PROMPT=0; [[ -n "${2:-}" ]] || fatal "--addons needs a list of addon names"; ADDONS="$2"; shift 2 ;;
      --no-addons)    INSTALL_ADDONS=0; ADDONS_ENABLED=0; ADDONS_PROMPT=0; shift ;;
      -*)             fatal "Unknown flag for 'create': $1 (expected --here, --no-tailwind, --no-addons, --addons)" ;;
      *)              PROJECT_NAME="$1"; shift ;;
    esac
  done

  validate_project_name "${PROJECT_NAME}"
  require_dependencies
  _prompt_addons

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
  local APP_PORT CMS_PORT CMS_TOKEN COCKPIT_SEC_KEY APP_DOMAIN CMS_DOMAIN
  APP_PORT="$(find_free_port "${GOSITE_PORT_MIN}")"
  CMS_PORT="$(find_free_port "$(( APP_PORT + 1 ))")"
  reserve_ports "${PROJECT_NAME}" "${APP_PORT}" "${CMS_PORT}"
  CMS_TOKEN="$(random_secret 24)"
  COCKPIT_SEC_KEY="$(random_secret 32)"
  APP_DOMAIN="$(project_domain "${PROJECT_NAME}")"
  CMS_DOMAIN="$(project_cms_domain "${PROJECT_NAME}")"

  # A failed scaffold used to leave a half-written directory behind that
  # `gosite remove` could not clean up, because the marker file is written last.
  # Remove it on any non-zero exit instead.
  trap 'rm -rf "${PROJECT_DIR}"; err "Scaffold failed; removed ${PROJECT_DIR}."' ERR

  info "Creating project '${PROJECT_NAME}'"
  debug "module=${PROJECT_MODULE} app=${APP_PORT} cms=${CMS_PORT}"

  mkdir -p "${PROJECT_DIR}"/{cmd/server,internal/{app,config,cache,cms,handlers,views/{pages,components}},cockpit/addons,static,deploy}
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
  _write_views         "${PROJECT_DIR}"
  _write_air_config    "${PROJECT_DIR}"
  _write_dockerfiles   "${PROJECT_DIR}"
  _write_compose_dev   "${PROJECT_DIR}"
  _write_compose_prod  "${PROJECT_DIR}"
  _write_env_files     "${PROJECT_DIR}"
  _write_meta_files    "${PROJECT_DIR}"
  _write_ai_docs       "${PROJECT_DIR}"
  _write_builtin_addons "${PROJECT_DIR}"

  local f
  while IFS= read -r f; do render_placeholders "${f}"; done < <(
    find "${PROJECT_DIR}" -type f ! -name '*.png' ! -name '*.ico'
  )

  # go.sum must be committed: the production image builds with the default
  # GOFLAGS and refuses to compile without verified module checksums.
  _resolve_dependencies "${PROJECT_DIR}"

  # Optional Cockpit addons (Forms + Replica), copied from gosite's own
  # src/addons/ library; --no-addons skips them. Built-in addons were already
  # written by _write_builtin_addons.
  [[ "${INSTALL_ADDONS}" -eq 1 ]] && _install_addons "${PROJECT_DIR}" "${ADDONS}"

  # Issue the local TLS certificate covering <name>.test and cms.<name>.test.
  ensure_project_cert "${PROJECT_NAME}" || true

  # Index the project so it can be reached by name from any directory.
  registry_register "${PROJECT_DIR}"

  trap - ERR
  ok "Project scaffolded at ${PROJECT_DIR}"
  cat <<EOF

$(printf "${C_BOLD}Next steps${C_NC}")
  1. gosite infra up                 $(printf "${C_DIM}# shared Traefik + Redis on ${GOSITE_NETWORK}${C_NC}")
  2. gosite start ${PROJECT_NAME}      $(printf "${C_DIM}# or: gosite cd ${PROJECT_NAME}${C_NC}")
  3. App  -> https://${APP_DOMAIN}   $(printf "${C_DIM}(air hot reload)${C_NC}")
     CMS  -> https://${CMS_DOMAIN}   $(printf "${C_DIM}(Cockpit)${C_NC}")
     $(printf "${C_DIM}Also on http://localhost:${APP_PORT} and http://localhost:${CMS_PORT}.${C_NC}")
$(if docker ps -q --filter name=gosite-proxy 2>/dev/null | grep -q .; then
  printf "\n  4. gosite infra restart$(printf "${C_DIM}          # infra was already running — restart to pick up new routes${C_NC}")\n"
fi)
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
# Prompt the user to pick Cockpit addons interactively. When --no-addons or
# --addons is used the prompt is skipped. If -y/--yes is set, skips with none.
_prompt_addons() {
  [[ "${ADDONS_PROMPT}" -eq 0 ]] && return 0
  [[ "${GOSITE_ASSUME_YES}" -eq 1 ]] && return 0

  printf "\n"
  printf "${C_BOLD}Cockpit addons${C_NC}\n"
  printf "  ${C_DIM}Optional: public forms, content replication.${C_NC}\n"

  local selected=""

  printf "${C_YELLOW}?${C_NC} Install Forms ${C_DIM}(public form submissions with anti-spam, CSV export)${C_NC} [y/N] "
  local reply
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]] && selected="Forms"

  printf "${C_YELLOW}?${C_NC} Install Replica ${C_DIM}(content replication between Cockpit instances)${C_NC} [y/N] "
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]] && selected="${selected:+${selected} }Replica"

  if [[ -n "${selected}" ]]; then
    ADDONS="${selected}"
    INSTALL_ADDONS=1
    ADDONS_ENABLED=1
    ok "Will install: ${selected}"
  else
    info "No addons selected."
  fi
}

# Built-in Cockpit addons that ship with every scaffolded project. They are
# real source files in src/addons/ (the single source of truth for all addons
# Built-in and optional addons are written by _write_builtin_addons /
# _install_addons from src/lib/templates.sh (shared with `gosite sync`).

# -----------------------------------------------------------------------------
_write_go_mod() {
  cat > "$1/go.mod" <<'EOF'
module __MODULE__

// Echo v5 requires Go 1.25 or newer.
go 1.25

require (
	github.com/labstack/echo/v5 v5.3.1
	github.com/redis/go-redis/v9 v9.22.0
	golang.org/x/sync v0.22.0
)
EOF
}

# -----------------------------------------------------------------------------
# Entry point: read configuration, build the app, start the server. Nothing
# else lives here, so there is exactly one place to look for startup order.
_write_main_go() {
  cat > "$1/cmd/server/main.go" <<'EOF'
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
EOF
}

# -----------------------------------------------------------------------------
# The composition root: build every dependency once and hand them to the
# handlers. Nothing here knows about HTTP.
_write_app() {
  cat > "$1/internal/app/app.go" <<'EOF'
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
			Cache:    cache.New(rdb, log, cfg.IsDev()),
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
  cat > "$1/internal/app/router.go" <<'EOF'
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
EOF
}

# -----------------------------------------------------------------------------
# Environment settings in one place, so no os.Getenv call is ever buried in a
# handler. Its own package because handlers, cms and main all read it.
_write_config() {
  cat > "$1/internal/config/config.go" <<'EOF'
// Package config reads every environment-provided setting exactly once.
package config

import "os"

type Config struct {
	Port         string
	RedisURL     string
	CockpitURL   string
	CockpitToken string
	Environment  string
	StorageAdapter string
}

func Load() Config {
	return Config{
		Port:           env("PORT", "8080"),
		RedisURL:       env("REDIS_URL", "redis://__REDIS_HOST__:__REDIS_PORT__/0"),
		CockpitURL:     env("COCKPIT_URL", "http://__PROJECT__-cms:80"),
		CockpitToken:   os.Getenv("COCKPIT_API_TOKEN"),
		Environment:    os.Getenv("APP_ENV"),
		StorageAdapter: env("STORAGE_ADAPTER", "local"),
	}
}

// IsDev reports whether the app is running for development, where the
// cache-purge button is shown without authentication. The default keeps
// production safe when APP_ENV is not set.
func (c Config) IsDev() bool {
	switch c.Environment {
	case "development", "dev", "local":
		return true
	default:
		return false
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
  cat > "$1/internal/handlers/handlers.go" <<'EOF'
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
EOF

  cat > "$1/internal/handlers/response.go" <<'EOF'
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

  cat > "$1/internal/handlers/home.go" <<'EOF'
package handlers

import (
	"bytes"
	"context"
	"net/http"
	"time"

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
	html, cached, err := h.Cache.HTML(c.Request().Context(), homeCacheKey, h.renderHome)
	if err != nil {
		return h.reply(c).Fail(http.StatusBadGateway, "could not load the page", err)
	}
	return h.reply(c).Page(html, cached)
}

// renderHome builds the page from scratch. It deliberately uses its own context
// rather than the request's: a cold render is shared by every request waiting
// on it, so if the one caller that happened to trigger it disconnects, that
// must not cancel the work everyone else is waiting for.
func (h *Handlers) renderHome() ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	var buf bytes.Buffer
	err := h.Renderer.Page(&buf, "home", map[string]any{
		"Title":   "__PROJECT__",
		"Content": h.CMS.Singleton(ctx, "home"),
		"IsDev":   h.Config.IsDev(),
	})
	return buf.Bytes(), err
}
EOF

  cat > "$1/internal/handlers/purge.go" <<'EOF'
package handlers

import (
	"context"
	"net/http"

	"github.com/labstack/echo/v5"
)

// PurgeCache drops the cached page. It is both the target of the htmx button
// on the page and a webhook Cockpit can call when an editor publishes, so the
// site updates without waiting out the TTL.
func (h *Handlers) PurgeCache(c *echo.Context) error {
	// In development the on-page button posts without a token, so the check is
	// skipped there; everywhere else the token is enforced whenever one is
	// configured, which is what protects a deployed site.
	if !h.Config.IsDev() && h.Config.CockpitToken != "" && c.Request().Header.Get("X-Api-Key") != h.Config.CockpitToken {
		return h.reply(c).Fail(http.StatusUnauthorized, "invalid token", nil)
	}
	if err := h.Cache.Purge(c.Request().Context(), homeCacheKey); err != nil {
		return h.reply(c).Fail(http.StatusInternalServerError, "purge failed", err)
	}

	go h.warmHome()

	return h.reply(c).Text(http.StatusOK, "purged")
}

// warmHome re-renders the page in the background after a purge, so the next
// visitor finds a warm cache instead of paying for the cold path. Single-flight
// in the cache means concurrent purges - and any visitor who arrives mid-render
// - collapse into this one render rather than piling onto the CMS.
func (h *Handlers) warmHome() {
	if _, _, err := h.Cache.HTML(context.Background(), homeCacheKey, h.renderHome); err != nil {
		h.Log.Warn("cache re-warm failed", "key", homeCacheKey, "err", err)
	}
}
EOF

  cat > "$1/internal/handlers/health.go" <<'EOF'
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
  cat > "$1/internal/cache/cache.go" <<'EOF'
// Package cache is a small cache-aside helper over Redis.
package cache

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"
	"golang.org/x/sync/singleflight"
)

// ttl keeps Cockpit almost entirely out of the request path while staying
// fresh enough for editorial work. Publishing calls /cache/purge anyway.
const ttl = 10 * time.Minute

type Cache struct {
	rdb *redis.Client
	log *slog.Logger
	dev bool

	// sf collapses concurrent cold renders of the same key into a single one,
	// so an expired cache under load never turns into a stampede against the
	// CMS: one request renders, the rest wait and share its result.
	sf singleflight.Group
}

func New(rdb *redis.Client, log *slog.Logger, dev bool) *Cache {
	return &Cache{rdb: rdb, log: log, dev: dev}
}

// HTML returns the cached bytes for key, calling render only on a miss:
//
//  1. GET the key. On a hit, return immediately - no CMS call, no rendering.
//  2. On a miss, run render behind single-flight, SET the result with a TTL
//     and return it. Concurrent misses of the same key share that one render.
//
// A Redis failure is never fatal: render still runs and the request is just
// slower, which keeps the site up when the cache is down.
//
// In development mode (dev=true) the cache is bypassed entirely — every
// request renders fresh, which makes iteration faster and avoids stale pages.
func (c *Cache) HTML(ctx context.Context, key string, render func() ([]byte, error)) ([]byte, bool, error) {
	start := time.Now()

	// Bypass cache entirely in development — always render fresh.
	if c.dev {
		html, err := render()
		if err != nil {
			return nil, false, err
		}
		c.log.Debug("dev bypass", "key", key, "elapsed", time.Since(start))
		return html, false, nil
	}

	cached, err := c.rdb.Get(ctx, key).Bytes()
	if err == nil {
		c.log.Info("cache hit", "key", key, "elapsed", time.Since(start))
		return cached, true, nil
	}
	if !errors.Is(err, redis.Nil) {
		c.log.Warn("cache read failed, rendering anyway", "key", key, "err", err)
	}

	v, err, shared := c.sf.Do(key, func() (any, error) {
		fresh, err := render()
		if err != nil {
			// single-flight discards failed results, so the next caller retries
			// instead of inheriting this error. No Forget needed.
			return nil, err
		}

		// Write with a background context, not the request one: the caller that
		// happened to win the race may disconnect, and that must not stop the
		// cache from being warmed for everyone else waiting on this render.
		if err := c.rdb.Set(context.Background(), key, fresh, ttl).Err(); err != nil {
			c.log.Warn("cache write failed", "key", key, "err", err)
		}
		return fresh, nil
	})
	if err != nil {
		return nil, false, err
	}

	c.log.Info("cache miss", "key", key, "shared", shared, "elapsed", time.Since(start))
	return v.([]byte), false, nil
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
  cat > "$1/internal/cms/cms.go" <<'EOF'
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

	"__MODULE__/internal/config"
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

// Content is one piece of CMS content, kept as a map so a template can read
// {{.Content.headline}} without a struct having to exist first. Define a
// struct in this package once the shape of a model settles down.
type Content map[string]any

// Singleton fetches a Cockpit singleton by name, e.g. Singleton(ctx, "home").
//
// Cockpit exposes singletons at /api/content/item/<name> and collections at
// /api/content/items/<name>, both authenticated with an api-key header. Create
// a "home" singleton in the Cockpit admin and its fields show up here.
//
// Until it exists the request fails, so the caller gets an empty Content and a
// logged warning rather than an error page: the site still renders with the
// fallbacks in the template.
func (c *Client) Singleton(ctx context.Context, name string) Content {
	content, err := c.fetch(ctx, "/api/content/item/"+name)
	if err != nil {
		c.log.Warn("cockpit unavailable, using template fallbacks", "item", name, "err", err)
		return Content{}
	}
	return content
}

func (c *Client) fetch(ctx context.Context, path string) (Content, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
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

	var content Content
	if err := json.NewDecoder(res.Body).Decode(&content); err != nil {
		return nil, err
	}
	return content, nil
}
EOF
}

# -----------------------------------------------------------------------------
# Markup only, one component per file, rendered with the standard library's
# html/template and embedded with go:embed.
#
# The markup differs between the two styling modes on purpose: with Tailwind
# the components carry utility classes, without it they carry semantic class
# names styled by static/app.css. Neither mode leaves classes that do nothing.
_write_views() {
  cat > "$1/internal/views/render.go" <<'EOF'
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

  if [[ "${TAILWIND}" -eq 1 ]]; then
    _write_views_tailwind "$1"
  else
    _write_views_plain "$1"
  fi
}

# --- Tailwind flavour ---------------------------------------------------------
_write_views_tailwind() {
  cat > "$1/internal/views/layout.html" <<'EOF'
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

  cat > "$1/internal/views/pages/home.html" <<'EOF'
{{/*
  The home page. .Content is whatever the Cockpit "home" singleton returns, so
  a field an editor has not filled in yet falls back to the text here.
*/}}
{{define "content"}}
<header class="mb-8 flex items-center justify-between">
	<h1 class="text-3xl font-bold tracking-tight">{{.Title}}</h1>
	{{template "purge-button" .}}
</header>

<section class="rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
	<h2 class="text-xl font-semibold">
		{{with .Content.headline}}{{.}}{{else}}Your site is running{{end}}
	</h2>
	<p class="mt-2 text-slate-600">
		{{with .Content.intro}}{{.}}{{else}}
		Edit views/pages/home.html to change this page, or create a "home"
		singleton in Cockpit with headline and intro fields to drive it from
		the CMS.
		{{end}}
	</p>
</section>
{{end}}
EOF

  cat > "$1/internal/views/components/button.html" <<'EOF'
{{/* Purges the cached page and reloads. Dev-only: it is not rendered at all in
   production, and it carries its own <style> block so it can be copied into any
   project without touching the shared stylesheet. */}}
{{define "purge-button"}}
{{if .IsDev}}
<button
  type="button"
  class="dev-purge"
  aria-label="Clear the page cache"
  x-data="{ busy: false }"
  :disabled="busy"
  x-text="busy ? 'Purging…' : 'Purge cache'"
  hx-post="/cache/purge"
  hx-swap="none"
  hx-on::before-request="busy = true"
  hx-on::after-request="if (event.detail.successful) window.location.reload()"
>Purge cache</button>
<style>
.dev-purge {
  position: fixed;
  bottom: 16px;
  right: 16px;
  z-index: 200;
  padding: 8px 14px;
  border: 1px solid var(--dev-purge-border, rgba(255, 255, 255, 0.16));
  border-radius: 999px;
  background: var(--dev-purge-bg, rgba(15, 23, 42, 0.78));
  color: var(--dev-purge-fg, #f8fafc);
  font: 600 12px/1 ui-monospace, "SF Mono", Menlo, monospace;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  cursor: pointer;
  backdrop-filter: blur(4px);
  -webkit-backdrop-filter: blur(4px);
  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.25);
}
.dev-purge:hover { background: var(--dev-purge-hover, rgba(37, 99, 235, 0.85)); }
.dev-purge:disabled { opacity: 0.6; cursor: wait; }
</style>
{{end}}
{{end}}
EOF
}

# --- plain CSS flavour --------------------------------------------------------
_write_views_plain() {
  cat > "$1/internal/views/layout.html" <<'EOF'
{{/*
  Base HTML document: one stylesheet, htmx and Alpine.js. Every page fills in
  the "content" block.

  htmx and Alpine are loaded from a CDN to keep local development build-free.
  Before going to production, vendor them into /static so the site does not
  depend on third-party uptime and a CSP can be tightened.
*/}}
{{define "layout"}}<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width, initial-scale=1">
	<title>{{.Title}}</title>
	<link rel="stylesheet" href="/static/styles.css">
	<script src="https://unpkg.com/htmx.org@2.0.10"></script>
	<script defer src="https://unpkg.com/alpinejs@3.15.12/dist/cdn.min.js"></script>
</head>
<body>
	<main class="container">
		{{template "content" .}}
	</main>
</body>
</html>{{end}}
EOF

  cat > "$1/internal/views/pages/home.html" <<'EOF'
{{/*
  The home page. .Content is whatever the Cockpit "home" singleton returns, so
  a field an editor has not filled in yet falls back to the text here.
*/}}
{{define "content"}}
<header class="page-header">
	<h1>{{.Title}}</h1>
	{{template "purge-button" .}}
</header>

<section class="panel">
	<h2>{{with .Content.headline}}{{.}}{{else}}Your site is running{{end}}</h2>
	<p>
		{{with .Content.intro}}{{.}}{{else}}
		Edit views/pages/home.html to change this page, or create a "home"
		singleton in Cockpit with headline and intro fields to drive it from
		the CMS.
		{{end}}
	</p>
</section>
{{end}}
EOF

  cat > "$1/internal/views/components/button.html" <<'EOF'
{{/* Purges the cached page and reloads. Dev-only: it is not rendered at all in
   production, and it carries its own <style> block so it can be copied into any
   project without touching the shared stylesheet. */}}
{{define "purge-button"}}
{{if .IsDev}}
<button
  type="button"
  class="dev-purge"
  aria-label="Clear the page cache"
  x-data="{ busy: false }"
  :disabled="busy"
  x-text="busy ? 'Purging…' : 'Purge cache'"
  hx-post="/cache/purge"
  hx-swap="none"
  hx-on::before-request="busy = true"
  hx-on::after-request="if (event.detail.successful) window.location.reload()"
>Purge cache</button>
<style>
.dev-purge {
  position: fixed;
  bottom: 16px;
  right: 16px;
  z-index: 200;
  padding: 8px 14px;
  border: 1px solid var(--dev-purge-border, rgba(255, 255, 255, 0.16));
  border-radius: 999px;
  background: var(--dev-purge-bg, rgba(15, 23, 42, 0.78));
  color: var(--dev-purge-fg, #f8fafc);
  font: 600 12px/1 ui-monospace, "SF Mono", Menlo, monospace;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  cursor: pointer;
  backdrop-filter: blur(4px);
  -webkit-backdrop-filter: blur(4px);
  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.25);
}
.dev-purge:hover { background: var(--dev-purge-hover, rgba(37, 99, 235, 0.85)); }
.dev-purge:disabled { opacity: 0.6; cursor: wait; }
</style>
{{end}}
{{end}}
EOF

  # Served from /static, so it is cached by the browser and never inlined.
  cat > "$1/static/styles.css" <<'EOF'
/* __PROJECT__ - plain CSS, no build step.
   Custom properties first so a restyle is a few values, not a find-replace. */
:root {
	--bg: #f8fafc;
	--surface: #ffffff;
	--text: #0f172a;
	--muted: #475569;
	--border: #e2e8f0;
	--accent: #2563eb;
	--radius: 8px;
}

@media (prefers-color-scheme: dark) {
	:root {
		--bg: #0f172a;
		--surface: #1e293b;
		--text: #e2e8f0;
		--muted: #94a3b8;
		--border: #334155;
		--accent: #60a5fa;
	}
}

*, *::before, *::after { box-sizing: border-box; }
[x-cloak] { display: none !important; }

body {
	margin: 0;
	background: var(--bg);
	color: var(--text);
	font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif;
	-webkit-font-smoothing: antialiased;
}

.container { max-width: 48rem; margin: 0 auto; padding: 3rem 1.5rem; }

.page-header {
	display: flex;
	align-items: center;
	justify-content: space-between;
	gap: 1rem;
	margin-bottom: 2rem;
}
.page-header h1 { margin: 0; font-size: 1.875rem; letter-spacing: -0.02em; }

.button {
	padding: 0.5rem 1rem;
	border: 0;
	border-radius: var(--radius);
	background: var(--text);
	color: var(--bg);
	font: inherit;
	font-size: 0.875rem;
	cursor: pointer;
}
.button:hover { opacity: 0.85; }

.panel {
	background: var(--surface);
	border: 1px solid var(--border);
	border-radius: var(--radius);
	padding: 1.5rem;
}
.panel h2 { margin: 0; font-size: 1.25rem; }
.panel p { margin: 0.5rem 0 0; color: var(--muted); }
EOF
}

# -----------------------------------------------------------------------------
_write_air_config() {
  cat > "$1/.air.toml" <<'EOF'
# air - hot reload for local development inside the dev container.
root = "."
tmp_dir = "tmp"

[build]
  cmd        = "go build -o ./tmp/main ./cmd/server"
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
  cat > "$1/deploy/Dockerfile" <<'EOF'
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
      -o /out/app ./cmd/server

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
  cat > "$1/deploy/Dockerfile.dev" <<'EOF'
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

  # Production CMS image: the stock Cockpit core plus the committed
  # cockpit/config.php and addons, baked in. Build from this instead of the
  # stock image so the CMS container carries its own config and addons - the
  # old approach of bind-mounting them (./cockpit/config.php, ./addons) breaks
  # in Coolify, where relative paths resolve against the directory that stores
  # the pasted compose file, not the repo checkout, silently mounting empty
  # directories. cockpit/config.php reads values through Cockpit's ${VAR}
  # resolution, so the environment variables in the compose file still win.
  #
  # No package installation happens at build time: the stock image already
  # ships PHP, the Flysystem S3 adapter and the AWS SDK under lib/vendor/ (it
  # has no composer binary, so a composer step would fail the build).
  cat > "$1/deploy/Dockerfile.cms" <<'EOF'
FROM cockpithq/cockpit:core-2.14.0

COPY cockpit/config.php /var/www/html/config/config.php
COPY cockpit/addons/ /var/www/html/addons/
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
deploy/
README.md
EOF
}

# -----------------------------------------------------------------------------
# Context files for AI assistants. MEMORY.md is the short entry point loaded
# first; ARCHITECTURE.md is the reference it points at.
_write_ai_docs() {
  cat > "$1/MEMORY.md" <<'EOF'
# __PROJECT__ - project memory

Read this first, then read `ARCHITECTURE.md` before changing anything. It
covers the layout, the rules that are easy to get wrong, the Echo v5 API
differences, how Cockpit and the cache work, and the `gosite` commands.

## What this is

A Go monolith that serves server-rendered HTML: **Echo v5** for routing,
**html/template** for markup, **htmx** and **Alpine.js** on the client,
**Cockpit** as the CMS and **Redis** as a page cache in front of it.
There is no JavaScript build step and no SPA.

## Facts

| | |
| --- | --- |
| Go module | `__MODULE__` |
| Local URL | https://__DOMAIN__ (also http://localhost:__APP_PORT__) |
| Cockpit admin | https://__CMS_DOMAIN__ (also http://localhost:__CMS_PORT__) |
| Redis | shared container `__REDIS_HOST__` on the `__NETWORK__` Docker network |
| CMS database | MongoDB (shared `__MONGO_HOST__` container locally, own MongoDB in production) |
| Cache key | `__PROJECT__:home_html`, TTL 10 minutes |
| Cache behaviour | single-flight on misses; `/cache/purge` re-warms in the background |
| CMS addons | Forms + Replica in `cockpit/addons/`, installed at scaffold time (`--no-addons` skips) |
| Managed by | the `gosite` CLI - see ARCHITECTURE.md for the commands |

## Reading order

`cmd/server/main.go` -> `internal/app/` -> `internal/handlers/`

## Rules that are easy to get wrong

1. **Echo v5, not v4.** Handlers take `*echo.Context`, `c.Response()` returns
   `http.ResponseWriter`, `echo.NewHTTPError(code, string)` takes a string, and
   there is no `e.Shutdown`. Do not copy v4 snippets from the web.
2. **Every route is registered in `internal/app/router.go`.** Nothing registers
   routes anywhere else.
3. **Handlers reply through `h.reply(c)`** (`internal/handlers/response.go`),
   never by writing headers by hand.
4. **Views get finished data.** No Redis, no HTTP and no CMS calls inside
   `internal/views/`.
5. **The page is cached.** After changing anything that affects the rendered
   HTML, purge: `curl -X POST -H "X-Api-Key: $COCKPIT_API_TOKEN" https://__DOMAIN__/cache/purge`
   Otherwise you will be looking at a stale page for up to 10 minutes.
6. **No build step.** Do not add npm, a bundler or a framework. htmx and
   Alpine are loaded from a CDN in `internal/views/layout.html`.
7. **Templates are embedded** with `go:embed`, so a new file under
   `internal/views/` only ships if it matches the embed patterns in
   `internal/views/render.go`.
8. **Data model lives in the database.** Content schemas (singletons,
   collections, fields) are defined in the Cockpit admin UI and stored in
   MongoDB. No migration files or SQL schemas exist in this repo - add fields
   in Cockpit, then render them in the template with a fallback.

## Common tasks

| Task | Do this |
| --- | --- |
| Add a route | one file in `internal/handlers/`, one line in `internal/app/router.go` |
| Add a page | template in `internal/views/pages/`, register it in `internal/views/render.go` |
| Add a component | file in `internal/views/components/`, call `{{template "name" .}}` |
| Change content | edit it in Cockpit, then purge the cache |
| Read the logs | `gosite logs __PROJECT__` |
| Restart | `gosite restart __PROJECT__` (air already reloads code) |

## Cockpit addons

The CMS carries two optional addons installed at scaffold time from
Avanxo-Technology/cockpit-addons. Locally the container mounts
`cockpit/addons/`; in production `deploy/Dockerfile.cms` bakes them (plus
`cockpit/config.php`) into the image, because relative bind mounts do not
resolve to the repo checkout in Coolify:

- **Forms** - inbox-style manager for website form submissions, with anti-spam,
  CSV export and notifications.
- **Replica** - content replication between Cockpit instances (push/pull,
  multiple targets, mirror/merge).

Skip them with `gosite create --no-addons`. After the first login grant the
permissions `forms/manage` and `replica/manage` in Settings > Roles. Update or
add addons later with:

```bash
curl -fsSL https://raw.githubusercontent.com/Avanxo-Technology/cockpit-addons/main/install.sh \
  | sh -s -- all --dir cockpit/addons --force
gosite restart __PROJECT__
```

The installer clears the Cockpit module cache; the restart is needed so PHP does
not serve the previous bootstrap from opcache. In production the module cache
lives in the persistent `cockpit-storage` volume, so after a deploy that adds or
updates an addon, clear `storage/cache/modules.cache.php` once inside the cms
container (the image rebuild ships the files; the stale cache is what hides
them).
EOF

  # Styling differs per project, so state the truth for this one.
  if [[ "${TAILWIND}" -eq 1 ]]; then
    cat >> "$1/MEMORY.md" <<'EOF'

## Styling

Tailwind CSS, loaded from a CDN in `internal/views/layout.html`. Components
carry utility classes. There is no Tailwind build or config file; before
production, vendor the CDN script into `/static`.
EOF
  else
    cat >> "$1/MEMORY.md" <<'EOF'

## Styling

Plain CSS in `static/styles.css`, built on custom properties with a dark-mode
block. Components carry semantic class names (`panel`, `page-header`,
`button`). No Tailwind, no build step - add rules to that stylesheet.
EOF
  fi

  cat > "$1/ARCHITECTURE.md" <<'EOF'
# __PROJECT__ - architecture

Reference for humans and AI assistants working on this project. `MEMORY.md` is
the short version; this file is the detail behind it.

## Stack

| Layer | Choice | Why |
| --- | --- | --- |
| HTTP | Echo v5 | Small, fast, standard-library shaped |
| Markup | `html/template` | Standard library, no code generation |
| Interactivity | htmx + Alpine.js | HTML over the wire; no SPA, no build step |
| CMS | Cockpit | Headless, editors get an admin UI |
| Cache | Redis | Keeps the CMS off the request path |
| Deploy | Docker + Coolify | Same compose format locally and in production |

## Layout

```
cmd/server/          Entry point (package main).
  main.go            Startup: read config, build the app, start the server.
  app.go             Composition root: build every dependency once.
  router.go          Every route and middleware. The whole HTTP surface.
internal/            Application packages (not importable by external code).
  config/            Environment settings, read exactly once.
  handlers/          One file per route.
    handlers.go      Deps + the receiver the handlers hang off.
    response.go      How this app replies.
    home.go          GET /
    purge.go         POST /cache/purge
    health.go        GET /healthz
  cache/             Cache-aside over Redis, written once.
  cms/               The Cockpit API client. The only package that calls the CMS.
  views/             Markup, embedded with go:embed.
    render.go        Parses every template at startup.
    layout.html      Base document.
    pages/           One file per page.
    components/      Reusable pieces, one per file.
  app/               App struct, NewApp, NewRouter (wiring).
cockpit/             Cockpit CMS configuration.
  config.php         Production config (baked into Dockerfile.cms).
  addons/            Cockpit addons (Forms, Replica).
deploy/              Dockerfiles for production, dev, and CMS images.
static/              Assets served at /static.
```

Dependency direction is one way: `internal/config` <- `internal/cache`/
`internal/cms` <- `internal/handlers` <- `internal/app` <- `cmd/server/main`.
Views import nothing from the app. Keep it that way: it is what stops markup
changes from breaking the cache and vice versa.

## Echo v5

v5 is not v4. The differences that bite:

| v4 | v5 |
| --- | --- |
| `func(c echo.Context) error` (interface) | `func(c *echo.Context) error` (struct pointer) |
| `c.Response()` returns `*echo.Response` | returns `http.ResponseWriter` |
| `echo.NewHTTPError(code, any...)` | `echo.NewHTTPError(code, string)` |
| `e.Shutdown(ctx)` | removed - `Start` handles signals and graceful shutdown |
| `middleware.Logger()` | `middleware.RequestLogger()` |
| Go 1.22 | Go 1.25 minimum |

Startup uses `echo.StartConfig{GracefulTimeout: ...}.Start(ctx, e)`, which
stops accepting connections when the context is cancelled and drains in-flight
requests. Do not add a manual shutdown.

Response helpers: https://echo.labstack.com/guide/response/

## Responses

Handlers reply through the helper in `internal/handlers/response.go`:

```go
return h.reply(c).Page(html, cached)                      // HTML + X-Cache header
return h.reply(c).Text(http.StatusOK, "purged")           // plain text
return h.reply(c).JSON(http.StatusOK, payload)            // JSON
return h.reply(c).Fail(http.StatusBadGateway, "...", err) // logs err, returns a safe message
```

`Fail` logs the real error with the request path and returns only the public
message, so internal detail never reaches a client. It is a thin layer over
Echo's own helpers - they still do the writing.

## Caching

`GET /` is served from Redis under `__PROJECT__:home_html` with a 10 minute
TTL. The cached value is the **fully rendered page**, so a hit skips the CMS
call and the template execution entirely.

The mechanics live in `internal/cache/cache.go` as one helper:

```go
html, cached, err := h.Cache.HTML(ctx, key, func() ([]byte, error) {
    // only runs on a miss
})
```

Cache another page by calling it with a different key. Do not reimplement
Get/Set in a handler.

Concurrent misses of the same key are coalesced with single-flight: exactly one
render runs and the others wait and share its bytes, so an expired or purged
key under load never becomes a stampede against Cockpit. The `SET` is issued
with a background context, so the caller that happened to trigger the render
disconnecting does not stop the cache from being warmed for everyone else.

`POST /cache/purge` re-renders the page in the background before it responds,
so the next request after an editor publishes finds a warm cache rather than
paying for the cold path.

The `X-Cache` response header reports `HIT` or `MISS` - check it before
concluding a change did not work:

```bash
curl -sD- -o /dev/null https://__DOMAIN__/ | grep -i x-cache
```

A Redis failure is never fatal: the page still renders, just slower.

### Purging

```bash
curl -X POST -H "X-Api-Key: $COCKPIT_API_TOKEN" https://__DOMAIN__/cache/purge
```

The button on the page does the same thing over htmx. The token is only
enforced when `COCKPIT_API_TOKEN` is set. Point a Cockpit publish webhook at
this URL so editors do not wait out the TTL.

## Cockpit CMS

The admin is at https://__CMS_DOMAIN__.

Locally Cockpit connects to the shared MongoDB container (`__MONGO_HOST__`), the
same way it connects to the shared Redis - no per-project database container is
needed. In production `cockpit/config.php` is baked in and points Cockpit at
the MongoDB service in the compose stack. Uploads and cache stay on the
`cockpit-storage` volume; content moves into MongoDB.

### Data model

Content is stored in MongoDB as documents. Singletons and collections are
defined in the Cockpit admin UI at https://__CMS_DOMAIN__/settings/blueprints.
`cms/cms.go` fetches them via the REST API:

```go
content := h.CMS.Singleton(ctx, "home") // GET /api/content/item/home
```

When the schema changes (new fields, new collections, new singletons), the
change happens in the database - no migration file or code change is needed
unless the template needs to render the new data. Add a fallback in the
template until the content exists:

```
{{with .Content.new_field}}{{.}}{{else}}default{{end}}
```

| Kind | Endpoint |
| --- | --- |
| Singleton | `/api/content/item/<name>` |
| Collection | `/api/content/items/<name>` |

Both authenticate with an `api-key` header, set from `COCKPIT_API_TOKEN`.

`cms.Content` is a `map[string]any`, so a template can read
`{{.Content.headline}}` without a struct existing. Once a model settles, define
a struct in `cms` and decode into it.

When Cockpit is unreachable or the item does not exist, the client returns
empty content and logs a warning; the template falls back to its own copy. That
is why a fresh project renders before any content exists.

### Updating content

1. Open https://__CMS_DOMAIN__ and sign in.
2. Create or edit the item (a `home` singleton with `headline` and `intro`
   fields drives the starter page).
3. Purge the cache, or wait up to 10 minutes.

To add a field: add it in Cockpit, then read it in the template with a fallback
(`{{with .Content.field}}{{.}}{{else}}default{{end}}`).

### Addons

The CMS container mounts `cockpit/addons/` into `/var/www/html/addons`, which
Cockpit core loads as first-class modules (bootstrap.php includes it in
`modulesPaths`). `gosite create` installs two by default from
Avanxo-Technology/cockpit-addons:

- **Forms** - public `POST /forms/api/submit` receiver (anti-spam honeypot +
  rate limit), per-form admin screen, CSV export, mail/webhook notifications.
- **Replica** - content sync between Cockpit instances: targets, push/pull,
  mirror/merge, dry runs, CLI, activity log.

Grant `forms/manage` and `replica/manage` in Settings > Roles after first login.

Addons are plain directories, so an addon is added by dropping its folder into
`cockpit/addons/` (or re-running the repo installer) and recreating the CMS
container.
In non-debug mode Cockpit caches the module list in
`storage/cache/modules.cache.php`; the installer clears it, and the container
must restart because opcache holds the compiled bootstrap.

## htmx and Alpine

- **htmx** issues the requests: `hx-get`, `hx-post`, `hx-target`, `hx-swap`.
  A handler answers with an HTML **fragment**, not JSON.
- **Alpine** handles local UI state only: `x-data`, `x-show`, `x-text`,
  `@click`. Use `x-cloak` on anything that would flash before Alpine loads.
- Both are CDN `<script>` tags in `internal/views/layout.html`. Vendor them into
  `/static` before production so the site does not depend on a third party and
  a CSP can be tightened.

Rule of thumb: if the server can render it, let the server render it. Reach for
Alpine only for state that never needs to touch the server.

## Templates

`internal/views/render.go` parses each page as `layout.html` + `pages/<name>.html`
+ `components/*.html` at startup, and panics on a malformed template - so a
broken template fails the deploy, not the first request.

Adding a page:

1. `internal/views/pages/about.html` defining `{{define "content"}}`.
2. Register it in `NewRenderer`: `"about": page("about")`.
3. A handler that renders `"about"`, and a line in `internal/app/router.go`.

Templates are embedded, so only files matching the `go:embed` patterns in
`render.go` ship in the binary.

## gosite commands

The `gosite` CLI manages this project. Run from anywhere with the project name,
or from inside the directory without it.

| Command | What it does |
| --- | --- |
| `gosite start __PROJECT__` | Start the app (air hot reload) and Cockpit |
| `gosite stop __PROJECT__` | Stop the containers |
| `gosite restart __PROJECT__` | Recreate the containers; `--build` rebuilds the image |
| `gosite logs __PROJECT__` | Follow both containers; `app` or `cms` to pick one |
| `gosite logs __PROJECT__ app -n 50 --no-follow` | Last 50 lines, no follow |
| `gosite list` | Every project, its ports and container status |
| `gosite cd __PROJECT__` | Jump to the directory (needs `eval "$(gosite shell-init)"`) |
| `gosite path __PROJECT__` | Print the directory, for scripts |
 | `gosite remove __PROJECT__` | Delete everything; `--keep-source` keeps the code |
 | `gosite sync __PROJECT__` | Re-apply gosite's templates: compose files, addons, missing `.env` keys |
 | `gosite infra up` / `down` / `status` | Shared Traefik and Redis |
| `gosite dns` | Check that `*.test` resolves to 127.0.0.1 |
| `gosite doctor` | Check the local toolchain |

Editing a `.go` or `.html` file rebuilds automatically through air in about
three seconds - no restart needed. Restart for `.env`, compose or Dockerfile
changes.

If a request 404s right after a start, Cockpit is still failing its health
check: Traefik does not route to a container until it is healthy.

## Environment

Read once in `internal/config/config.go`; never call `os.Getenv` in a handler.

| Variable | Local default | Production |
| --- | --- | --- |
| `PORT` | 8080 | set by Coolify |
| `REDIS_URL` | `redis://__REDIS_HOST__:__REDIS_PORT__/0` | a Coolify Redis service |
| `COCKPIT_URL` | `http://__PROJECT__-cms:80` | the deployed Cockpit |
| `COCKPIT_API_TOKEN` | in `.env` | set in the Coolify UI |

`.env` is local only and gitignored. Production values come from the Coolify
UI.

## Deployment

`docker-compose.yml` is local only: mapped ports, source bind-mounted, air.
`docker-compose.prod.yml` is what Coolify uses: no host ports, Traefik labels,
every value from the environment, and the multi-stage `deploy/Dockerfile`
producing a static binary on Alpine.

The production stack is self-contained: it brings its own MongoDB and Redis, so
Coolify only supplies domains and secrets.

Push to Git, point a Coolify Docker Compose resource at
`docker-compose.prod.yml`, and set `SERVICE_FQDN_APP`, `SERVICE_FQDN_CMS`,
`COCKPIT_API_TOKEN`, `COCKPIT_SEC_KEY`, `MONGO_USER` and `MONGO_PASSWORD`.

## Conventions

- Comments explain **why**, not what the next line does.
- Errors are logged where they happen and returned as a safe message.
- No global state; dependencies are passed through `handlers.Deps`.
- No JavaScript build step. Ever.
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
	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ./tmp/app ./cmd/server

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
cmd/server/          Entry point (package main).
  main.go            Startup: read config, build the app, start the server.
  app.go             Composition root: build every dependency once.
  router.go          Every route and middleware. The whole HTTP surface.
internal/            Application packages (not importable by external code).
  config/            Environment settings, read exactly once.
  handlers/          One file per route.
    handlers.go      Deps + the receiver they hang off.
    response.go      How this app replies (see below).
    home.go          GET /
    purge.go         POST /cache/purge
    health.go        GET /healthz
  cache/             Cache-aside over Redis, written once.
  cms/               The Cockpit API client. The only package that calls the CMS.
  views/             Markup, embedded with go:embed.
    render.go        Parses every template at startup.
    layout.html      Base document (styles, htmx, Alpine).
    pages/           One file per page.
    components/      Reusable pieces, one per file.
  app/               App struct, NewApp, NewRouter (wiring).
cockpit/             Cockpit CMS configuration.
  config.php         Production config (baked into Dockerfile.cms).
  addons/            Cockpit addons (Forms, Replica).
deploy/              Dockerfiles for production, dev, and CMS images.
static/              Assets served at /static.
```

Reading order: `cmd/server/main.go` -> `internal/app/` -> `internal/handlers/`.

Adding an endpoint is one file in `internal/handlers/` and one line in
`internal/app/router.go`. Adding a page is one template in
`internal/views/pages/`. Nothing else changes.

Data flows one way: `internal/cms` fetches from Cockpit, a handler passes that
to `internal/views`, and the rendered HTML goes into `internal/cache`.

The example is deliberately one page with no data model. Add a struct in
`internal/cms` once the shape of your content settles; until then
`cms.Content` is a map, so a template can read `{{.Content.headline}}` without
anything to define first.

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

`internal/cms/cms.go` calls `GET $COCKPIT_URL/api/content/item/home` with an
`api-key` header. Create a `home` singleton in the Cockpit admin with
`headline` and `intro` fields and the page renders them.

Until it exists the request fails, the client returns empty content and logs
why, and the template falls back to the copy written into
`internal/views/pages/home.html` - so a fresh project renders on the first run
instead of an error page.

Collections live at `/api/content/items/<name>` if you need a list later.

When the data model changes (new fields, new collections) the change goes into
MongoDB through the Cockpit admin UI. No migration files or code changes are
needed unless the template needs to render the new data.

## Addons

Locally the CMS container mounts `cockpit/addons/`; in production
`deploy/Dockerfile.cms` bakes `cockpit/config.php` and `cockpit/addons/` into
the image. Scaffolding installs two optional addons by default:

- **Forms** — inbox-style manager for website form submissions: public receiver
  endpoint with anti-spam, an admin screen, CSV export and notifications.
- **Replica** — content replication between Cockpit instances: push/pull,
  multiple targets, mirror/merge conflict handling, dry runs and a CLI.

Skip them with `gosite create --no-addons`. After first login, grant
`forms/manage` and `replica/manage` in Settings > Roles. To update or add more:

```bash
curl -fsSL https://raw.githubusercontent.com/Avanxo-Technology/cockpit-addons/main/install.sh \
  | sh -s -- all --dir cockpit/addons --force
gosite restart
```

## Local development

```bash
gosite infra up      # shared Traefik + Redis on __NETWORK__
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
`SERVICE_FQDN_CMS`, `COCKPIT_API_TOKEN`, `COCKPIT_SEC_KEY`, `MONGO_USER` and
`MONGO_PASSWORD`. The stack brings its own MongoDB and Redis.

The `app` and `cms` services build from `deploy/Dockerfile` and
`deploy/Dockerfile.cms`; nothing is bind-mounted, so Coolify needs no path to
the checkout. Config and addon changes require an image rebuild rather than a
file drop, and after a rebuild that adds an addon, clear
`storage/cache/modules.cache.php` once in the cms container.
EOF
}
