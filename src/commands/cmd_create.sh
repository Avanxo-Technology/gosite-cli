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
  local PROJECT_NAME="${1:-}"
  validate_project_name "${PROJECT_NAME}"
  require_dependencies

  local PROJECT_DIR="${PWD}/${PROJECT_NAME}"
  [[ -e "${PROJECT_DIR}" ]] && fatal "'./${PROJECT_NAME}' already exists."

  local PROJECT_MODULE="${GOSITE_MODULE_PREFIX:-github.com/example}/${PROJECT_NAME}"
  local APP_PORT CMS_PORT CMS_TOKEN
  APP_PORT="$(find_free_port "${GOSITE_PORT_MIN}")"
  CMS_PORT="$(find_free_port "$(( APP_PORT + 1 ))")"
  CMS_TOKEN="$(random_secret 24)"

  info "Creating project '${PROJECT_NAME}'"
  debug "module=${PROJECT_MODULE} app=${APP_PORT} cms=${CMS_PORT}"

  mkdir -p "${PROJECT_DIR}/templates" "${PROJECT_DIR}/static"
  # Keep static/ in Git so the production COPY stage always finds it.
  touch "${PROJECT_DIR}/static/.gitkeep"

  _write_go_mod        "${PROJECT_DIR}"
  _write_main_go       "${PROJECT_DIR}"
  _write_templ         "${PROJECT_DIR}"
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

  ok "Project scaffolded at ./${PROJECT_NAME}"
  cat <<EOF

$(printf "${C_BOLD}Next steps${C_NC}")
  1. gosite infra up                 $(printf "${C_DIM}# shared Postgres + Redis on ${GOSITE_NETWORK}${C_NC}")
  2. cd ${PROJECT_NAME} && gosite start
  3. App  -> http://localhost:${APP_PORT}   $(printf "${C_DIM}(air hot reload)${C_NC}")
     CMS  -> http://localhost:${CMS_PORT}   $(printf "${C_DIM}(Cockpit)${C_NC}")

$(printf "${C_DIM}Production: push to Git and point Coolify at docker-compose.prod.yml.${C_NC}")
EOF
}

# -----------------------------------------------------------------------------
# Resolves the module graph and writes go.sum. Prefers the host toolchain and
# falls back to a throwaway golang container so the result is identical whether
# or not Go is installed locally.
_resolve_dependencies() {
  local dir="$1"
  info "Resolving Go dependencies (writing go.sum)"

  if command -v go >/dev/null 2>&1; then
    ( cd "${dir}" && go mod tidy ) && { ok "go.sum written."; return 0; }
    warn "Host 'go mod tidy' failed; retrying inside a container."
  fi

  if docker run --rm -v "${dir}:/src" -w /src golang:1.22-alpine \
       sh -c 'apk add --no-cache git >/dev/null && go mod tidy'; then
    ok "go.sum written."
    return 0
  fi

  warn "Could not resolve dependencies (offline?). Run 'go mod tidy' in ./${PROJECT_NAME} before deploying."
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
_write_main_go() {
  cat > "$1/main.go" <<'EOF'
// Package main wires an Echo server that serves htmx fragments rendered with
// Templ, backed by a Redis cache-aside layer in front of Cockpit CMS.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/a-h/templ"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"github.com/redis/go-redis/v9"

	"__MODULE__/templates"
)

// cacheTTL is how long a Cockpit response stays warm in Redis. Cockpit content
// changes rarely, so 10 minutes keeps the CMS almost entirely out of the
// request path while staying fresh enough for editorial work.
const cacheTTL = 10 * time.Minute

// articlesCacheKey namespaces the cached payload. Bump the suffix whenever the
// shape of Article changes so stale JSON is never decoded into a new struct.
const articlesCacheKey = "__PROJECT__:articles:v1"

// Article is the projection of a Cockpit collection item the frontend needs.
// It is a type alias, not a copy: the canonical definition lives in the
// templates package so components can take it directly with no conversion.
type Article = templates.Article

type Server struct {
	rdb *redis.Client
}

func main() {
	rdb, err := newRedisClient()
	if err != nil {
		log.Fatalf("redis: %v", err)
	}
	defer rdb.Close()

	s := &Server{rdb: rdb}

	e := echo.New()
	e.HideBanner = true
	e.Use(middleware.Recover())
	e.Use(middleware.Logger())
	e.Use(middleware.Gzip())

	e.Static("/static", "static")

	e.GET("/", s.handleIndex)
	e.GET("/articulos", s.handleArticles)     // htmx fragment
	e.POST("/cache/purge", s.handleCachePurge) // Cockpit webhook target
	e.GET("/healthz", func(c echo.Context) error {
		if err := s.rdb.Ping(c.Request().Context()).Err(); err != nil {
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

func (s *Server) handleIndex(c echo.Context) error {
	return render(c, http.StatusOK, templates.Index("__PROJECT__"))
}

// handleArticles is the htmx target. It reads through the Redis cache and only
// touches Cockpit when the key is cold.
func (s *Server) handleArticles(c echo.Context) error {
	ctx := c.Request().Context()
	start := time.Now()

	articles, hit, err := s.articles(ctx)
	if err != nil {
		return echo.NewHTTPError(http.StatusBadGateway, "could not load articles")
	}

	source := "MISS"
	if hit {
		source = "HIT"
	}
	// Surfaced as a response header so the cache behaviour is observable from
	// the browser devtools while developing.
	c.Response().Header().Set("X-Cache", source)
	c.Response().Header().Set("X-Cache-Elapsed", time.Since(start).String())
	log.Printf("GET /articulos cache=%s elapsed=%s", source, time.Since(start))

	return render(c, http.StatusOK, templates.ArticleList(articles, source, time.Since(start).String()))
}

// articles implements the cache-aside read path:
//
//	1. GET the key from Redis. On a hit, decode and return in microseconds.
//	2. On a miss, query Cockpit, encode the result, SET it with a TTL, return it.
//
// A Redis failure is never fatal: the CMS query is still served, just slower.
func (s *Server) articles(ctx context.Context) ([]Article, bool, error) {
	cached, err := s.rdb.Get(ctx, articlesCacheKey).Bytes()
	switch {
	case err == nil:
		var articles []Article
		if err := json.Unmarshal(cached, &articles); err == nil {
			return articles, true, nil // cache hit
		}
		// Corrupt payload: drop it and fall through to a fresh fetch.
		log.Printf("cache: discarding unreadable value for %s", articlesCacheKey)
		s.rdb.Del(ctx, articlesCacheKey)
	case errors.Is(err, redis.Nil):
		// Cache miss, expected.
	default:
		log.Printf("cache: read failed, falling back to cockpit: %v", err)
	}

	articles, err := fetchFromCockpit(ctx)
	if err != nil {
		return nil, false, err
	}

	if payload, err := json.Marshal(articles); err == nil {
		if err := s.rdb.Set(ctx, articlesCacheKey, payload, cacheTTL).Err(); err != nil {
			log.Printf("cache: write failed: %v", err)
		}
	}
	return articles, false, nil
}

// handleCachePurge lets Cockpit invalidate the cache on publish, so editors do
// not have to wait out the TTL. Protect it with the shared CMS token.
func (s *Server) handleCachePurge(c echo.Context) error {
	if token := os.Getenv("COCKPIT_API_TOKEN"); token != "" && c.Request().Header.Get("X-Api-Key") != token {
		return echo.NewHTTPError(http.StatusUnauthorized, "invalid token")
	}
	if err := s.rdb.Del(c.Request().Context(), articlesCacheKey).Err(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "purge failed")
	}
	return c.String(http.StatusOK, "purged")
}

// fetchFromCockpit stands in for the real CMS call. Replace the body with an
// HTTP request to COCKPIT_URL/api/content/items/articles carrying the
// COCKPIT_API_TOKEN header; the caching layer above stays unchanged.
func fetchFromCockpit(ctx context.Context) ([]Article, error) {
	select {
	case <-time.After(400 * time.Millisecond): // simulated CMS latency
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	return []Article{
		{ID: "1", Title: "Go + htmx without a build step", Excerpt: "Server-rendered HTML, no bundler.", Slug: "go-htmx"},
		{ID: "2", Title: "Cockpit as a headless CMS", Excerpt: "Content editing without coupling the frontend.", Slug: "cockpit-headless"},
		{ID: "3", Title: "Cache-aside with Redis", Excerpt: "Keep the CMS off the hot path.", Slug: "redis-cache-aside"},
	}, nil
}

// render adapts a Templ component to an Echo response.
func render(c echo.Context, status int, component templ.Component) error {
	c.Response().Header().Set(echo.HeaderContentType, echo.MIMETextHTMLCharsetUTF8)
	c.Response().WriteHeader(status)
	return component.Render(c.Request().Context(), c.Response().Writer)
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
_write_templ() {
  cat > "$1/templates/index.templ" <<'EOF'
package templates

// Layout is the shared HTML shell. htmx and Alpine are loaded from a CDN here;
// vendor them into /static before going to production.
templ Layout(title string) {
	<!DOCTYPE html>
	<html lang="es">
		<head>
			<meta charset="utf-8"/>
			<meta name="viewport" content="width=device-width, initial-scale=1"/>
			<title>{ title }</title>
			<script src="https://unpkg.com/htmx.org@2.0.2"></script>
			<script defer src="https://unpkg.com/alpinejs@3.14.1/dist/cdn.min.js"></script>
		</head>
		<body>
			{ children... }
		</body>
	</html>
}

// Index renders the page shell. The article list is loaded out-of-band by htmx
// so the first paint never waits on the CMS.
templ Index(project string) {
	@Layout(project) {
		<main x-data="{ loading: false }">
			<h1>{ project }</h1>

			<button
				hx-get="/articulos"
				hx-target="#articles"
				hx-swap="innerHTML"
				@htmx:before-request="loading = true"
				@htmx:after-request="loading = false"
			>
				Reload articles
			</button>
			<span x-show="loading" x-cloak>loading...</span>

			<section
				id="articles"
				hx-get="/articulos"
				hx-trigger="load"
				hx-swap="innerHTML"
			>
				<p>Loading articles...</p>
			</section>
		</main>
	}
}

// ArticleList is the htmx fragment. `source` is HIT or MISS so the cache
// behaviour is visible in the UI while developing.
templ ArticleList(articles []Article, source string, elapsed string) {
	<ul x-data="{ open: null }">
		for _, article := range articles {
			<li>
				<h2 @click={ "open = open === '" + article.ID + "' ? null : '" + article.ID + "'" }>
					{ article.Title }
				</h2>
				<p x-show={ "open === '" + article.ID + "'" } x-cloak>{ article.Excerpt }</p>
			</li>
		}
	</ul>
	<footer>
		<small>cache: { source } — { elapsed }</small>
	</footer>
}
EOF

  # Templ components need the Article type in their own package.
  cat > "$1/templates/models.go" <<'EOF'
package templates

// Article mirrors the main package projection of a Cockpit item.
type Article struct {
	ID      string `json:"id"`
	Title   string `json:"title"`
	Excerpt string `json:"excerpt"`
	Slug    string `json:"slug"`
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
    ports:
      - "__APP_PORT__:8080"
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

Go (Echo + htmx + Alpine.js + Templ) + Cockpit CMS monolith, with Redis
cache-aside in front of the CMS.

## Local development

```bash
gosite infra up      # shared Postgres + Redis on __NETWORK__
gosite start         # app (air hot reload) + Cockpit
```

| Service | URL |
| --- | --- |
| App | http://localhost:__APP_PORT__ |
| Cockpit | http://localhost:__CMS_PORT__ |

Editing any `.go` or `.templ` file triggers `templ generate` + rebuild via air.

## Caching

`GET /articulos` reads through Redis (`__PROJECT__:articles:v1`, TTL 10m).
The `X-Cache` response header reports `HIT` or `MISS`. Point a Cockpit publish
webhook at `POST /cache/purge` (header `X-Api-Key: $COCKPIT_API_TOKEN`) to
invalidate on demand.

## Production (Coolify)

`docker-compose.prod.yml` publishes no host ports and takes every value from
the environment. In Coolify: create a Docker Compose resource from this repo,
select `docker-compose.prod.yml`, then set `SERVICE_FQDN_APP`,
`SERVICE_FQDN_CMS`, `REDIS_URL`, `DATABASE_URL` and `COCKPIT_API_TOKEN`.
EOF
}
