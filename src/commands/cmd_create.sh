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

  info "Creating project '${PROJECT_NAME}'"
  debug "module=${PROJECT_MODULE} app=${APP_PORT} cms=${CMS_PORT}"

  mkdir -p "${PROJECT_DIR}"/{models,views/components,handlers,static}
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
  _write_models        "${PROJECT_DIR}"
  _write_views         "${PROJECT_DIR}"
  _write_handlers      "${PROJECT_DIR}"
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
# Generates the Templ components and resolves the module graph, writing go.sum.
#
# Order matters: views/ and views/components/ hold only .templ files, so those
# packages do not exist for the Go toolchain until `templ generate` has run.
# Running `go mod tidy` first fails to resolve them and leaves no go.sum, which
# then breaks the production build.
#
# Prefers the host toolchain and falls back to a throwaway container, so the
# result is identical whether or not Go and templ are installed locally.
_resolve_dependencies() {
  local dir="$1"
  info "Generating Templ components and resolving dependencies"

  if command -v go >/dev/null 2>&1 && command -v templ >/dev/null 2>&1; then
    if ( cd "${dir}" && templ generate >/dev/null && go mod tidy ); then
      ok "Components generated, go.sum written."
      return 0
    fi
    warn "Host toolchain failed; retrying inside a container."
  fi

  if docker run --rm -v "${dir}:/src" -w /src golang:1.22-alpine sh -c '
        apk add --no-cache git >/dev/null &&
        go install github.com/a-h/templ/cmd/templ@v0.2.793 >/dev/null 2>&1 &&
        /go/bin/templ generate >/dev/null &&
        go mod tidy'; then
    ok "Components generated, go.sum written."
    return 0
  fi

  warn "Could not resolve dependencies (offline?). Run 'templ generate && go mod tidy' in ${dir} before deploying."
  return 0
}

# -----------------------------------------------------------------------------
_write_go_mod() {
  cat > "$1/go.mod" <<'EOF'
module __MODULE__

go 1.22

require (
	github.com/a-h/templ v0.2.793
	github.com/labstack/echo/v4 v4.12.0
	github.com/redis/go-redis/v9 v9.6.1
)
EOF
}

# -----------------------------------------------------------------------------
# Entry point only: wiring, no business logic and no markup. Everything it does
# is create dependencies and hand them to the handlers layer.
_write_main_go() {
  cat > "$1/main.go" <<'EOF'
// Package main is the composition root: it builds the dependencies (Redis,
// Echo) and wires the handlers layer. It contains no business logic and no
// markup - those live in handlers/ and views/ respectively.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"github.com/redis/go-redis/v9"

	"__MODULE__/handlers"
)

func main() {
	rdb, err := newRedisClient()
	if err != nil {
		log.Fatalf("redis: %v", err)
	}
	defer rdb.Close()

	e := echo.New()
	e.HideBanner = true
	e.Use(middleware.Recover())
	e.Use(middleware.Logger())
	e.Use(middleware.Gzip())
	e.Static("/static", "static")

	// The handlers layer owns its own routes, so adding a feature means
	// touching one package instead of editing this file.
	handlers.NewArticulos(rdb).Register(e)

	e.GET("/healthz", func(c echo.Context) error {
		if err := rdb.Ping(c.Request().Context()).Err(); err != nil {
			return c.String(http.StatusServiceUnavailable, "redis unavailable")
		}
		return c.String(http.StatusOK, "ok")
	})

	port := env("PORT", "8080")
	go func() {
		if err := e.Start(":" + port); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server: %v", err)
		}
	}()

	// Graceful shutdown so in-flight htmx requests are not cut mid-render.
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := e.Shutdown(ctx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

// newRedisClient parses REDIS_URL (redis://host:port/db) and verifies the
// connection up front, so a misconfigured environment fails at boot instead of
// on the first cache miss.
func newRedisClient() (*redis.Client, error) {
	opts, err := redis.ParseURL(env("REDIS_URL", "redis://__REDIS_HOST__:__REDIS_PORT__/0"))
	if err != nil {
		return nil, err
	}
	rdb := redis.NewClient(opts)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, err
	}
	log.Printf("redis connected: %s db=%d", opts.Addr, opts.DB)
	return rdb, nil
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
# DATA LAYER. Plain structs mapping Cockpit's JSON. No Redis, no HTTP, no HTML:
# anything here can be read in isolation to know the shape of the data.
_write_models() {
  cat > "$1/models/articulo.go" <<'EOF'
// Package models holds the data structures the application works with.
// It has no dependencies on Echo, Redis or Templ on purpose: this package
// describes *what* the data is, never how it is fetched or rendered.
package models

import "time"

// Articulo maps one item of the "articulos" collection in Cockpit CMS.
//
// The json tags match Cockpit's field names, so the same struct is used to
// decode the CMS response and to encode the value stored in Redis.
type Articulo struct {
	ID        string    `json:"_id"`
	Titulo    string    `json:"titulo"`
	Extracto  string    `json:"extracto"`
	Contenido string    `json:"contenido"`
	Slug      string    `json:"slug"`
	Publicado bool      `json:"publicado"`
	Creado    time.Time `json:"_created"`
}

// URL is the canonical path of the article. Keeping it here means views never
// have to build paths by hand.
func (a Articulo) URL() string {
	return "/articulos/" + a.Slug
}

// RespuestaCockpit is the envelope Cockpit returns for a collection query.
type RespuestaCockpit struct {
	Articulos []Articulo `json:"entries"`
	Total     int        `json:"total"`
}
EOF
}

# -----------------------------------------------------------------------------
# VIEW LAYER. Markup only, one component per file. Components receive
# already-resolved data and never reach for Redis, the CMS or the request.
#
#   views/           page-level markup (layout, pages, fragments)
#   views/components/ reusable pieces, each in its own file
#
_write_views() {
  # --- base document ---------------------------------------------------------
  cat > "$1/views/layout.templ" <<'EOF'
package views

// Layout is the base HTML document and nothing else: Tailwind CSS, htmx and
// Alpine.js. Every page wraps itself in this.
//
// The three libraries are loaded from a CDN to keep local development
// build-free. Before going to production, vendor them into /static so the site
// does not depend on third-party uptime and a CSP can be tightened.
templ Layout(titulo string) {
	<!DOCTYPE html>
	<html lang="es" class="h-full">
		<head>
			<meta charset="utf-8"/>
			<meta name="viewport" content="width=device-width, initial-scale=1"/>
			<title>{ titulo }</title>
			<script src="https://cdn.tailwindcss.com"></script>
			<script src="https://unpkg.com/htmx.org@2.0.2"></script>
			<script defer src="https://unpkg.com/alpinejs@3.14.1/dist/cdn.min.js"></script>
			<style>
				[x-cloak] { display: none !important; }
			</style>
		</head>
		<body class="h-full bg-slate-50 text-slate-900 antialiased">
			<div class="mx-auto max-w-3xl px-6 py-12">
				{ children... }
			</div>
		</body>
	</html>
}
EOF

  # --- home page -------------------------------------------------------------
  cat > "$1/views/inicio.templ" <<'EOF'
package views

import "__MODULE__/views/components"

// Inicio is the page shell. The article list is loaded out of band by htmx, so
// the first paint never waits on the CMS.
templ Inicio(titulo string) {
	@Layout(titulo) {
		<header class="mb-8 flex items-center justify-between">
			<h1 class="text-3xl font-bold tracking-tight">{ titulo }</h1>
			@components.BotonRecargar("/articulos", "#articulos")
		</header>

		@components.Cargando()

		<section
			id="articulos"
			hx-get="/articulos"
			hx-trigger="load"
			hx-swap="innerHTML"
		></section>
	}
}
EOF

  # --- htmx fragment ---------------------------------------------------------
  cat > "$1/views/articulos.templ" <<'EOF'
package views

import (
	"__MODULE__/models"
	"__MODULE__/views/components"
)

// ListaArticulos is the fragment htmx swaps into the page. It only composes
// components: the markup of a single article lives in its own file, so it can
// be reused or changed without touching the list.
//
// It receives the data already resolved by the handler and never knows whether
// that data came from the cache or from the CMS.
templ ListaArticulos(articulos []models.Articulo) {
	if len(articulos) == 0 {
		@components.Vacio("No hay articulos publicados todavia.")
	} else {
		<ul class="space-y-4" x-data="{ abierto: null }">
			for _, articulo := range articulos {
				@components.TarjetaArticulo(articulo)
			}
		</ul>
	}
}
EOF

  # --- reusable components, one per file -------------------------------------
  cat > "$1/views/components/tarjeta.templ" <<'EOF'
package components

import "__MODULE__/models"

// TarjetaArticulo renders a single article. It expects an Alpine `abierto`
// scope from its parent list, which is what lets one card expand at a time.
templ TarjetaArticulo(articulo models.Articulo) {
	<li class="rounded-lg border border-slate-200 bg-white p-5 shadow-sm">
		<button
			class="w-full text-left"
			@click={ "abierto = abierto === '" + articulo.ID + "' ? null : '" + articulo.ID + "'" }
		>
			<h2 class="text-lg font-semibold">{ articulo.Titulo }</h2>
			<p class="mt-1 text-sm text-slate-600">{ articulo.Extracto }</p>
		</button>

		<div x-show={ "abierto === '" + articulo.ID + "'" } x-cloak>
			<p class="mt-3 border-t border-slate-100 pt-3 text-sm text-slate-700">
				{ articulo.Contenido }
			</p>
			<a class="mt-2 inline-block text-sm text-blue-600 hover:underline" href={ templ.SafeURL(articulo.URL()) }>
				Leer mas
			</a>
		</div>
	</li>
}
EOF

  cat > "$1/views/components/boton.templ" <<'EOF'
package components

// BotonRecargar triggers an htmx request against `url` and swaps the result
// into `objetivo`. Parameterised so any page can reuse it.
templ BotonRecargar(url string, objetivo string) {
	<button
		class="rounded-md bg-slate-900 px-4 py-2 text-sm font-medium text-white hover:bg-slate-700"
		hx-get={ url }
		hx-target={ objetivo }
		hx-swap="innerHTML"
		hx-indicator="#cargando"
	>
		Recargar
	</button>
}
EOF

  cat > "$1/views/components/estado.templ" <<'EOF'
package components

// Cargando is the htmx indicator: htmx toggles it automatically for any
// request that points hx-indicator at it.
templ Cargando() {
	<p id="cargando" class="htmx-indicator text-sm text-slate-500">Cargando...</p>
}

// Vacio is the empty state, kept separate so copy changes never touch logic.
templ Vacio(mensaje string) {
	<p class="text-slate-500">{ mensaje }</p>
}
EOF
}

# -----------------------------------------------------------------------------
# LOGIC LAYER. Routing, caching and CMS access. This is the only layer that
# knows Redis exists.
_write_handlers() {
  cat > "$1/handlers/articulos.go" <<'EOF'
// Package handlers holds the HTTP controllers: routing, caching and the calls
// to Cockpit CMS. It is the only layer that talks to Redis, and the only one
// that decides *when* data is produced - views only decide how it looks.
package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/labstack/echo/v4"
	"github.com/redis/go-redis/v9"

	"__MODULE__/models"
	"__MODULE__/views"
)

const (
	// cacheKey holds the rendered HTML fragment. Caching the markup rather than
	// the raw data means a hit skips both the CMS call and the render.
	cacheKey = "articulos_html"

	// cacheTTL keeps Cockpit almost entirely out of the request path while
	// staying fresh enough for editorial work.
	cacheTTL = 10 * time.Minute
)

// Articulos is the controller for everything under /articulos.
type Articulos struct {
	rdb *redis.Client
}

func NewArticulos(rdb *redis.Client) *Articulos {
	return &Articulos{rdb: rdb}
}

// Register mounts this controller's routes. Keeping it here means main.go
// never has to change when a route is added.
func (h *Articulos) Register(e *echo.Echo) {
	e.GET("/", h.Inicio)
	e.GET("/articulos", h.Lista)
	e.POST("/cache/purge", h.Purgar)
}

// Inicio renders the page shell.
func (h *Articulos) Inicio(c echo.Context) error {
	c.Response().Header().Set(echo.HeaderContentType, echo.MIMETextHTMLCharsetUTF8)
	return views.Inicio("__PROJECT__").Render(c.Request().Context(), c.Response().Writer)
}

// Lista is the htmx target and the cache-aside read path:
//
//	1. GET the key from Redis. On a hit, write the cached HTML straight to the
//	   response - no CMS call, no template rendering, microseconds.
//	2. On a miss, query Cockpit, render the Templ component into a buffer, SET
//	   that HTML with a TTL, and serve it.
//
// A Redis failure is never fatal: the CMS is queried directly, just slower.
func (h *Articulos) Lista(c echo.Context) error {
	ctx := c.Request().Context()
	inicio := time.Now()

	c.Response().Header().Set(echo.HeaderContentType, echo.MIMETextHTMLCharsetUTF8)

	// --- cache hit ---------------------------------------------------------
	if html, err := h.rdb.Get(ctx, cacheKey).Bytes(); err == nil {
		h.marcar(c, "HIT", inicio)
		_, err = c.Response().Write(html)
		return err
	} else if !errors.Is(err, redis.Nil) {
		log.Printf("cache: read failed, falling back to cockpit: %v", err)
	}

	// --- cache miss --------------------------------------------------------
	articulos, err := consultarCockpit(ctx)
	if err != nil {
		log.Printf("cockpit: %v", err)
		return echo.NewHTTPError(http.StatusBadGateway, "no se pudieron cargar los articulos")
	}

	// Render into a buffer so the exact bytes served are the bytes cached.
	var buf bytes.Buffer
	if err := views.ListaArticulos(articulos).Render(ctx, &buf); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "error al renderizar")
	}

	if err := h.rdb.Set(ctx, cacheKey, buf.Bytes(), cacheTTL).Err(); err != nil {
		log.Printf("cache: write failed: %v", err)
	}

	h.marcar(c, "MISS", inicio)
	_, err = c.Response().Write(buf.Bytes())
	return err
}

// Purgar lets Cockpit invalidate the cache on publish, so editors do not have
// to wait out the TTL. Point a Cockpit webhook at it.
func (h *Articulos) Purgar(c echo.Context) error {
	if token := os.Getenv("COCKPIT_API_TOKEN"); token != "" && c.Request().Header.Get("X-Api-Key") != token {
		return echo.NewHTTPError(http.StatusUnauthorized, "token invalido")
	}
	if err := h.rdb.Del(c.Request().Context(), cacheKey).Err(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "no se pudo purgar")
	}
	return c.String(http.StatusOK, "purgado")
}

// marcar exposes the cache outcome as response headers, so the behaviour is
// visible in the browser devtools without polluting the HTML.
func (h *Articulos) marcar(c echo.Context, estado string, inicio time.Time) {
	transcurrido := time.Since(inicio)
	c.Response().Header().Set("X-Cache", estado)
	c.Response().Header().Set("X-Cache-Elapsed", transcurrido.String())
	log.Printf("GET /articulos cache=%s elapsed=%s", estado, transcurrido)
}

// consultarCockpit stands in for the real CMS call. Replace the body with an
// HTTP request to COCKPIT_URL/api/content/items/articulos carrying the
// COCKPIT_API_TOKEN header and decode it into models.RespuestaCockpit; the
// caching layer above stays unchanged.
func consultarCockpit(ctx context.Context) ([]models.Articulo, error) {
	select {
	case <-time.After(400 * time.Millisecond): // simulated CMS latency
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	datos := []byte(`{"entries":[
		{"_id":"1","titulo":"Go + htmx sin build step","extracto":"HTML renderizado en el servidor, sin bundler.","contenido":"El servidor devuelve HTML y htmx lo intercambia en el DOM.","slug":"go-htmx","publicado":true},
		{"_id":"2","titulo":"Cockpit como CMS headless","extracto":"Editar contenido sin acoplar el frontend.","contenido":"Cockpit expone una API REST que consumimos desde Go.","slug":"cockpit-headless","publicado":true},
		{"_id":"3","titulo":"Cache-aside con Redis","extracto":"Mantener el CMS fuera de la ruta caliente.","contenido":"Guardamos el fragmento ya renderizado con un TTL de 10 minutos.","slug":"redis-cache-aside","publicado":true}
	],"total":3}`)

	var respuesta models.RespuestaCockpit
	if err := json.Unmarshal(datos, &respuesta); err != nil {
		return nil, err
	}
	return respuesta.Articulos, nil
}
EOF
}

# -----------------------------------------------------------------------------
_write_air_config() {
  cat > "$1/.air.toml" <<'EOF'
# air - hot reload for local development inside the dev container.
root = "."
tmp_dir = "tmp"

[build]
  # Regenerate Templ components before every rebuild.
  pre_cmd  = ["templ generate"]
  cmd      = "go build -o ./tmp/main ."
  bin      = "./tmp/main"
  delay    = 300
  include_ext  = ["go", "templ", "html", "css", "js"]
  exclude_dir  = ["tmp", "static/vendor", ".git", "cockpit-storage"]
  exclude_regex = ["_test\\.go", "_templ\\.go"]
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
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates
WORKDIR /src

# Dependencies first so the module cache survives source-only changes.
COPY go.mod go.sum* ./
RUN go mod download

# Templ codegen must run before the compiler sees the package. The CLI is
# pinned to the same version as the library so generated code always matches.
RUN go install github.com/a-h/templ/cmd/templ@v0.2.793

COPY . .
RUN templ generate

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
FROM golang:1.22-alpine

RUN apk add --no-cache git curl

RUN go install github.com/a-h/templ/cmd/templ@v0.2.793 \
 && go install github.com/air-verse/air@v1.52.3

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
*_templ.go
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
*_templ.go
/app
EOF

  cat > "$1/Makefile" <<'EOF'
.PHONY: dev generate build tidy

dev:      ## Hot reload on the host (containers: use `gosite start`)
	air -c .air.toml

generate: ## Regenerate Templ components
	templ generate

build: generate
	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o ./tmp/app .

tidy:
	go mod tidy
EOF

  cat > "$1/README.md" <<'EOF'
# __PROJECT__

Go (Echo + htmx + Alpine.js + Templ + Tailwind) + Cockpit CMS monolith, with
Redis cache-aside in front of the CMS.

## Structure

Strict separation of concerns, one responsibility per directory, so the code
is easy to navigate and extend without mixing server logic and markup:

```
main.go               Composition root: builds Redis + Echo, wires handlers.
models/               DATA. Plain structs mapping Cockpit JSON. No I/O.
  articulo.go
views/                MARKUP. One component per file. No Redis, no CMS.
  layout.templ        Base HTML document (Tailwind, htmx, Alpine).
  inicio.templ        Home page shell.
  articulos.templ     htmx fragment; composes components.
  components/         Reusable pieces.
    tarjeta.templ     A single article card.
    boton.templ       htmx reload button.
    estado.templ      Loading indicator and empty state.
handlers/             LOGIC. Routing, caching, CMS access.
  articulos.go        Controller for /, /articulos and /cache/purge.
```

The dependency direction is one-way: `handlers` imports `views` and `models`,
`views` imports `models`, and `models` imports nothing. A change to the markup
can never break the cache, and vice versa.

## Local development

```bash
gosite infra up      # shared Postgres + Redis on __NETWORK__
gosite start         # app (air hot reload) + Cockpit
```

| Service | URL |
| --- | --- |
| App | http://localhost:__APP_PORT__ |
| Cockpit | http://localhost:__CMS_PORT__ |

Editing any `.go` or `.templ` file (including a single component) triggers
`templ generate` + rebuild via air, in about 3 seconds.

## Caching

`GET /articulos` reads through Redis (key `articulos_html`, TTL 10m). The
cached value is the *rendered HTML fragment*, so a hit skips both the CMS call
and the template render. The `X-Cache` response header reports `HIT` or `MISS`.
Point a Cockpit publish webhook at `POST /cache/purge`
(header `X-Api-Key: $COCKPIT_API_TOKEN`) to invalidate on demand.

To hit the real CMS, replace the body of `consultarCockpit` in
`handlers/articulos.go` with an HTTP call to
`$COCKPIT_URL/api/content/items/articulos`; nothing else changes.

## Production (Coolify)

`docker-compose.prod.yml` publishes no host ports and takes every value from
the environment. In Coolify: create a Docker Compose resource from this repo,
select `docker-compose.prod.yml`, then set `SERVICE_FQDN_APP`,
`SERVICE_FQDN_CMS`, `REDIS_URL`, `DATABASE_URL` and `COCKPIT_API_TOKEN`.
EOF
}
