#!/usr/bin/env bash
#
# Shared project templates for gosite. Used by `create` (write everything fresh)
# and by `sync` (re-render the same files into an existing project from the
# placeholders in its .gosite.env marker).
#
# Templates are written with __PLACEHOLDER__ tokens and rendered afterwards via
# render_placeholders, so heredocs can stay fully quoted and never mangle
# Go/compose "${VAR}" syntax.
#
# Note: __REDIS_PORT__ renders to the IN-NETWORK port (6379), not the
# host-published one. Project containers always reach the shared services by
# container name on gosite-network, never through the host.

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
    -e "s|__REDIS_HOST__|${GOSITE_REDIS_HOST}|g" \
    -e "s|__REDIS_PORT__|6379|g" \
    -e "s|__MONGO_HOST__|${GOSITE_MONGO_HOST}|g" \
    -e "s|__MONGO_PORT__|${GOSITE_MONGO_PORT}|g" \
    -e "s|__MINIO_HOST__|${GOSITE_MINIO_HOST}|g" \
    -e "s|__CMS_TOKEN__|${CMS_TOKEN}|g" \
    -e "s|__COCKPIT_SEC_KEY__|${COCKPIT_SEC_KEY}|g" \
    -e "s|__TAILWIND__|${TAILWIND}|g" \
    -e "s|__ADDONS__|${ADDONS_ENABLED}|g" \
    -e "s|__TLD__|${GOSITE_TLD}|g" \
    -e "s|__DATABASE__|${DATABASE:-mongodb}|g" \
    -e "s|__STORAGE_ADAPTER__|${STORAGE_ADAPTER:-s3}|g" \
    "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

# Reads a project's .gosite.env marker into the render variables, so the
# compose/env templates can be re-rendered for an existing project with the
# exact values it was created with.
load_project_render_vars() {
  local marker="$1/.gosite.env"
  [[ -f "${marker}" ]] || fatal "No ${marker} found; not a gosite project."
  # shellcheck source=/dev/null
  source "${marker}"
  PROJECT_NAME="${GOSITE_PROJECT}"
  PROJECT_MODULE="${GOSITE_MODULE}"
  APP_PORT="${GOSITE_APP_PORT}"
  CMS_PORT="${GOSITE_CMS_PORT}"
  TAILWIND="${GOSITE_TAILWIND:-0}"
  APP_DOMAIN="${GOSITE_APP_DOMAIN}"
  CMS_DOMAIN="${GOSITE_CMS_DOMAIN}"
  ADDONS_ENABLED="${GOSITE_ADDONS:-0}"
  DATABASE="${GOSITE_DATABASE:-mongodb}"
  STORAGE_ADAPTER="${STORAGE_ADAPTER:-s3}"
  # CMS_TOKEN/COCKPIT_SEC_KEY live in .env; without them render them to their
  # .env placeholders so a re-render never clobbers secrets with blanks.
  CMS_TOKEN="${CMS_TOKEN:-__CMS_TOKEN__}"
  COCKPIT_SEC_KEY="${COCKPIT_SEC_KEY:-__COCKPIT_SEC_KEY__}"
}

# Built-in Cockpit addons that ship with every scaffolded project. They are
# real source files in src/addons/ (the single source of truth for all addons
# - optional Forms/Replica are copied from the same place), so updating gosite
# keeps every new scaffold on the latest version of every addon.
_write_builtin_addons() {
  local addons_src="${GOSITE_ROOT}/addons"
  local target="$1/cockpit/addons"

  for name in AssetsUpload ModelManager CloudStorage; do
    mkdir -p "${target}/${name}"
    cp -R "${addons_src}/${name}/." "${target}/${name}/"
  done
}

# Copies the optional Cockpit addons (default Forms + Replica) into
# <project>/cockpit/addons/. They ship with gosite in src/addons/, so the copy
# is local and offline - updating gosite updates every future scaffold. When a
# project dir already has them, a re-run overwrites the files in place (useful
# for pulling newer addon versions into an existing project).
_install_addons() {
  local dir="$1" names="$2" addons_dir="${1}/cockpit/addons"
  info "Installing Cockpit addons: ${names}"
  mkdir -p "${addons_dir}"

  for name in ${names}; do
    if [[ -d "${GOSITE_ROOT}/addons/${name}" ]]; then
      mkdir -p "${addons_dir}/${name}"
      cp -R "${GOSITE_ROOT}/addons/${name}/." "${addons_dir}/${name}/"
      ok "Installed ${name}"
    else
      warn "Addon '${name}' not found in gosite's addon library; check the name (try: gosite sync --list-addons)."
    fi
  done

  ok "Addons installed into ${addons_dir}"
}

_write_compose_dev() {
  # LOCAL ONLY: ports mapped to localhost, source bind-mounted, air hot reload,
  # attached to the external shared network for Redis.
  cat > "$1/docker-compose.yml" <<'EOF'
# Local development stack for __PROJECT__.
# Redis and MongoDB are NOT defined here: they are the shared gosite
# infrastructure, reachable by container name on the external network.
# Start them with `gosite infra up`.

services:
  app:
    build:
      context: .
      dockerfile: deploy/Dockerfile.dev
    container_name: __PROJECT__-app
    restart: unless-stopped
    env_file: .env
    environment:
      PORT: "8080"
      APP_ENV: development
      REDIS_URL: "redis://__REDIS_HOST__:__REDIS_PORT__/0"
      COCKPIT_URL: "http://__PROJECT__-cms:80"
      # The app carries the Mongo connection parts too, so direct database
      # access (if added) uses the shared infra with the same credentials
      # logic as cockpit/config.php.
      MONGO_HOST: "__MONGO_HOST__"
      MONGO_PORT: "__MONGO_PORT__"
      MONGO_DB: "__PROJECT__"
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
    build:
      context: .
      dockerfile: deploy/Dockerfile.cms
    container_name: __PROJECT__-cms
    restart: unless-stopped
    environment:
      # Cockpit reads these through config.php's ${VAR} resolution.
      COCKPIT_SESSION_NAME: "__PROJECT__"
      COCKPIT_SEC_KEY: "${COCKPIT_SEC_KEY}"
      COCKPIT_MEMORY_SERVER: "redis://__REDIS_HOST__:6379"
      COCKPIT_DATABASE: "__DATABASE__"
      MONGO_HOST: "__MONGO_HOST__"
      MONGO_PORT: "__MONGO_PORT__"
      MONGO_DB: "__PROJECT__"
      STORAGE_ADAPTER: "${STORAGE_ADAPTER}"
      S3_URL: "${S3_URL}"
      S3_BUCKET: "${S3_BUCKET}"
      S3_REGION: "${S3_REGION}"
      S3_KEY: "${S3_KEY}"
      S3_SECRET: "${S3_SECRET}"
      S3_PREFIX: "${S3_PREFIX}"
      S3_PUBLIC_URL: "${S3_PUBLIC_URL}"
      S3_ACL: "${S3_ACL:-}"
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
      # Config and addons are baked into the image by Dockerfile.cms, not
      # bind-mounted: relative mounts resolve against the directory where
      # Coolify stores the pasted compose file, not the repo checkout, and
      # silently mount empty directories. Storage stays on a volume.
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
# port declared in the labels below. The stack is self-contained - it brings its
# own MongoDB and Redis - so the only thing Coolify has to supply is the domain
# names and the secrets.
#
# Required variables in Coolify:
#   SERVICE_FQDN_APP     e.g. __PROJECT__.example.com
#   SERVICE_FQDN_CMS     e.g. cms.__PROJECT__.example.com
#   COCKPIT_API_TOKEN    shared token between the app and Cockpit
#   COCKPIT_SEC_KEY      Cockpit's signing key - the image ships a public
#                        default, so this must be set to something private
#   MONGO_USER           MongoDB root user
#   MONGO_PASSWORD       MongoDB root password
#
# Optional: MONGO_DB (defaults to the project name).

services:
  app:
    build:
      context: .
      dockerfile: deploy/Dockerfile
    restart: unless-stopped
    environment:
      - APP_ENV=production
      - PORT=8080
      - SERVICE_FQDN_APP
      - REDIS_URL=redis://redis:6379/0
      - COCKPIT_URL=http://cms:80
      - COCKPIT_API_TOKEN=${COCKPIT_API_TOKEN}
      # Mongo parts so the app can build a credential-aware URI (see
      # buildMongoURI in internal/config) exactly like the CMS does.
      - MONGO_HOST=mongo
      - MONGO_PORT=27017
      - MONGO_USER=${MONGO_USER}
      - MONGO_PASSWORD=${MONGO_PASSWORD}
      - MONGO_DB=${MONGO_DB:-__PROJECT__}
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
      redis:
        condition: service_healthy
      cms:
        condition: service_started

  cms:
    build:
      context: .
      dockerfile: deploy/Dockerfile.cms
    restart: unless-stopped
    environment:
      # Read by cockpit/config.php through Cockpit's ${VAR} resolution.
      - COCKPIT_SEC_KEY=${COCKPIT_SEC_KEY}
      - COCKPIT_MEMORY_SERVER=redis://redis:6379
      - COCKPIT_DATABASE=${COCKPIT_DATABASE:-mongodb}
      - MONGO_HOST=mongo
      - MONGO_PORT=27017
      - MONGO_USER=${MONGO_USER}
      - MONGO_PASSWORD=${MONGO_PASSWORD}
      - MONGO_DB=${MONGO_DB:-__PROJECT__}
      # S3 storage (optional — only used when STORAGE_ADAPTER=s3)
      - STORAGE_ADAPTER=${STORAGE_ADAPTER:-local}
      - S3_URL=${S3_URL}
      - S3_BUCKET=${S3_BUCKET}
      - S3_REGION=${S3_REGION}
      - S3_KEY=${S3_KEY}
      - S3_SECRET=${S3_SECRET}
      - S3_PREFIX=${S3_PREFIX}
      - S3_PUBLIC_URL=${S3_PUBLIC_URL}
      - S3_ACL=${S3_ACL:-}
    volumes:
      # Uploads and cache still live on disk even when the data is in MongoDB.
      # Config and addons are NOT mounted here: Dockerfile.cms bakes the
      # committed cockpit/config.php and addons/ into the image. Relative bind
      # mounts (./cockpit/config.php, ./addons) resolve against the directory
      # where Coolify stores the pasted compose file, not the repo checkout, so
      # they silently mount empty directories. After a deploy that changes an
      # addon, clear storage/cache/modules.cache.php once so the CMS re-registers
      # it on the next boot.
      - cockpit-storage:/var/www/html/storage
    labels:
      - coolify.managed=true
      - traefik.enable=true
      - traefik.http.routers.__PROJECT__-cms.rule=Host(`${SERVICE_FQDN_CMS}`)
      - traefik.http.routers.__PROJECT__-cms.entrypoints=https
      - traefik.http.routers.__PROJECT__-cms.tls=true
      - traefik.http.routers.__PROJECT__-cms.tls.certresolver=letsencrypt
      - traefik.http.services.__PROJECT__-cms.loadbalancer.server.port=80
    depends_on:
      mongo:
        condition: service_healthy

  mongo:
    image: mongo:8.0
    restart: unless-stopped
    environment:
      - MONGO_INITDB_ROOT_USERNAME=${MONGO_USER}
      - MONGO_INITDB_ROOT_PASSWORD=${MONGO_PASSWORD}
    volumes:
      - mongo-data:/data/db
    healthcheck:
      # Gate the CMS on a real ping, not just the container being up: Cockpit
      # fails at boot if it cannot reach the database.
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  redis:
    image: redis:8-alpine
    restart: unless-stopped
    # Page cache only: evict rather than refuse writes when memory runs out.
    command: ["redis-server", "--appendonly", "yes", "--maxmemory-policy", "allkeys-lru"]
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

volumes:
  cockpit-storage:
  mongo-data:
  redis-data:
EOF

  # Cockpit configures its database in PHP, not through environment variables:
  # the image has no COCKPIT_DATABASE_* handling. This file is merged over
  # Cockpit's defaults at boot, and its ${VAR} references are resolved from the
  # container environment.
  mkdir -p "$1/cockpit"
  cat > "$1/cockpit/config.php" <<'EOF'
<?php

// Cockpit configuration, merged over the defaults in bootstrap.php.
// Used in both local development and production: local mounts this into the
// CMS container; deployment bakes it into the image via Dockerfile.cms.
//
// Values are read with getenv() directly. Cockpit's DotEnv ${VAR} resolution
// does not run reliably on all images for values baked into config.php.

$mongoUser = (string)getenv('MONGO_USER');
$mongoPass = (string)getenv('MONGO_PASSWORD');
$mongoHost = getenv('MONGO_HOST') ?: 'localhost';
$mongoPort = getenv('MONGO_PORT') ?: '27017';

// Credentials are optional: the shared gosite-mongo runs without auth, and an
// empty user:pass@ in the URI makes the Mongo driver attempt SCRAM auth and
// fail with "Authentication failed". Only append credentials when both exist.
$mongoAuth = ($mongoUser !== '' && $mongoPass !== '')
    ? rawurlencode($mongoUser).':'.rawurlencode($mongoPass).'@'
    : '';

// Storage engine chosen at scaffold time: 'mongodb' (default, the shared infra
// or the project's own Mongo) or 'local' (mongolite files inside the
// container's storage/data - handy for throwaway tests with no infra).
$useLocal = getenv('COCKPIT_DATABASE') === 'local';
$mongoDb  = getenv('MONGO_DB') ?: '__PROJECT__';

$config = [

    // Content storage. MongoDB: models and entries live on the shared infra
    // (gosite-mongo in dev, own Mongo in prod), never in local files. Local:
    // mongolite sqlite under storage/data, fully self-contained.
    'database' => $useLocal
        ? [
            'server' => 'mongolite:///var/www/html/storage/data',
            'options' => ['db' => $mongoDb],
            'driverOptions' => [],
        ]
        : [
            'server' => 'mongodb://'.$mongoAuth.$mongoHost.':'.$mongoPort,
            'options' => ['db' => $mongoDb],
            'driverOptions' => [],
        ],

    // Store content model definitions alongside the data (in MongoDB when not
    // in local mode, in storage/content files when local), never as a mix.
    'content' => [
        'models' => [
            'storage' => $useLocal ? 'files' : 'database',
        ],
    ],

    // App memory/options: on the shared infrastructure instead of Cockpit's
    // default local redislite file (storage/data/app.memory.sqlite). Cockpit
    // core's memory driver only supports redislite or Redis (not MongoDB), so
    // the infra Redis is used - dev on the shared gosite-redis (DB 1, off the
    // app's page-cache DB 0), production on the project's own redis service. A
    // per-project key prefix stops projects sharing the infra Redis from
    // colliding. In local mode memory stays in the redislite file.
    'memory' => $useLocal
        ? ['server' => 'redislite:///var/www/html/storage/data/app.memory.sqlite', 'options' => []]
        : [
            'server' => getenv('COCKPIT_MEMORY_SERVER') ?: 'redis://gosite-redis:6379',
            'options' => [
                'database' => 1,
                'prefix' => $mongoDb.':',
            ],
        ],

    // The image ships a hardcoded, publicly known key. Overriding it is what
    // stops anyone from forging a session against a deployed site.
    'sec-key' => getenv('COCKPIT_SEC_KEY') ?: '__COCKPIT_SEC_KEY__',

    'session' => [
        'name' => '__PROJECT__',
    ],
];

// S3-compatible asset storage (MinIO in dev, AWS/Backblaze/R2 in prod).
// Enabled per environment with STORAGE_ADAPTER=s3; the CloudStorage addon
// reads this config and wires uploads to the Flysystem S3 adapter the core
// image already ships (no composer step, no Pro license). The keys match the
// Cockpit Pro CloudStorage docs, so the config stays valid if the real Pro
// addon is ever installed.
if (getenv('STORAGE_ADAPTER') === 's3') {
    $config['cloudStorage'] = [
        'uploads' => [
            'url'    => getenv('S3_URL') ?: null,
            'key'    => getenv('S3_KEY'),
            'secret' => getenv('S3_SECRET'),
            'region' => getenv('S3_REGION') ?: 'auto',
            'bucket' => getenv('S3_BUCKET'),
            'prefix' => getenv('S3_PREFIX') ?: '',
            // null = bucket policy handles access (required for "Bucket owner
            // enforced" buckets where ACLs are disabled). Set S3_ACL=yes to
            // switch to public-read ACL.
            'visibility' => getenv('S3_ACL') === 'yes' ? 'public' : null,
            // Browser-reachable base for asset URLs: https://minio.<TLD> for
            // local MinIO, a CDN or bucket endpoint in production. When unset
            // the addon keeps Cockpit's own /storage/uploads proxy (which only
            // works while files stay on disk).
            'public_url' => getenv('S3_PUBLIC_URL') ?: '',
        ],
    ];

    // Generated thumbnails go to S3 too, so the browser can load them through
    // the public URL. The default `tmp://thumbs` storage resolves to a disk
    // path because docs_root is unset on this image, and pointing it at the
    // local `#uploads` mount would die with the S3 adapter. Requires the
    // public_url above to be set.
    $config['assets']['storage'] = 'uploads://thumbs';
}

return $config;
EOF
}
# -----------------------------------------------------------------------------
_write_env_files() {
  cat > "$1/.env" <<'EOF'
# Local development environment. Not committed.
APP_ENV=development
PORT=8080
REDIS_URL=redis://__REDIS_HOST__:__REDIS_PORT__/0
COCKPIT_URL=http://__PROJECT__-cms:80
COCKPIT_API_TOKEN=__CMS_TOKEN__
COCKPIT_SEC_KEY=__COCKPIT_SEC_KEY__

# S3-compatible storage for assets (optional — set STORAGE_ADAPTER=s3 to enable).
# MinIO runs in the shared gosite infra (native TLS with mkcert certs); these
# defaults point at it. For production, set these from the Coolify dashboard
# (AWS S3, Backblaze, etc.).
# A custom S3_URL implies path-style addressing (MinIO, R2, Backblaze); leave
# S3_URL unset for AWS S3 virtual-hosted addressing.
STORAGE_ADAPTER=__STORAGE_ADAPTER__
S3_URL=https://__MINIO_HOST__:9000
S3_BUCKET=assets
S3_REGION=us-east-1
S3_KEY=minioadmin
S3_SECRET=minioadmin
S3_PREFIX=
# S3_VERIFY=false is required for the local MinIO (self-signed mkcert cert, not
# in the CMS container's trust store). Set it to true (or unset) in production
# when the bucket endpoint has a valid TLS certificate.
S3_VERIFY=false
# Public base for CMS asset URLs (used when STORAGE_ADAPTER=s3). For local
# MinIO this is the HTTPS Traefik route (minio.__TLD__), so the app and the
# browser load assets CDN-style instead of through the /storage/uploads proxy.
# In production point this at a CDN or bucket endpoint.
S3_PUBLIC_URL=https://minio.__TLD__/assets
EOF

  cat > "$1/.env.example" <<'EOF'
# Copy to .env for local dev; set the same keys in the Coolify UI for prod.
# Runtime environment. development/dev/local render the cache-purge button,
# which posts without a token; anything else (or unset) means production.
APP_ENV=production
PORT=8080
REDIS_URL=redis://__REDIS_HOST__:__REDIS_PORT__/0
COCKPIT_URL=http://__PROJECT__-cms:80
COCKPIT_API_TOKEN=change-me
COCKPIT_SEC_KEY=change-me

# S3-compatible storage for assets (optional — set STORAGE_ADAPTER=s3 to enable).
# In production, use AWS S3, Backblaze B2, or any S3-compatible provider.
# Leave S3_URL unset for AWS (virtual-hosted); set it for custom endpoints.
# STORAGE_ADAPTER=s3
# S3_URL=https://s3.us-east-1.amazonaws.com
# S3_BUCKET=my-project-assets
# S3_REGION=us-east-1
# S3_KEY=AKIA...
# S3_SECRET=...
# S3_PREFIX=production
# S3_PUBLIC_URL=https://cdn.example.com/my-assets   # browser-reachable base for asset URLs
# S3_ACL=yes          # set to "yes" to enable public-read ACL (default: null, bucket policy handles access)
# S3_VERIFY=true      # TLS cert verification for the bucket endpoint (default true)
EOF

  # Marker file consumed by list/start/stop/remove.
  cat > "$1/${GOSITE_MARKER}" <<'EOF'
GOSITE_PROJECT=__PROJECT__
GOSITE_MODULE=__MODULE__
GOSITE_APP_PORT=__APP_PORT__
GOSITE_CMS_PORT=__CMS_PORT__
GOSITE_TAILWIND=__TAILWIND__
GOSITE_APP_DOMAIN=__DOMAIN__
GOSITE_CMS_DOMAIN=__CMS_DOMAIN__
GOSITE_NETWORK=__NETWORK__
GOSITE_ADDONS=__ADDONS__
GOSITE_DATABASE=__DATABASE__
EOF
}

# -----------------------------------------------------------------------------
# BUILD FILES. The Dockerfiles, .air.toml and .dockerignore that make the
# compose files buildable. Shared by create and sync so a synced project always
# has the files the re-rendered compose files reference (otherwise docker fails
# with "/deploy: no such file or directory" on old scaffolds).
# -----------------------------------------------------------------------------

# Writes a file only when its content changed. On an overwrite of an existing
# file the previous version is kept as <file>.gosite.bak, so a gosite sync
# never silently destroys a user-customized Dockerfile or .air.toml.
write_if_changed() {
  local dest="$1"
  local content
  content="$(cat)"

  if [[ -f "${dest}" ]] && printf '%s' "${content}" | cmp -s - "${dest}"; then
    return 0
  fi

  if [[ -f "${dest}" ]]; then
    cp -f "${dest}" "${dest}.gosite.bak"
    warn "Backed up previous '${dest}' to '${dest}.gosite.bak'"
  fi
  mkdir -p "$(dirname "${dest}")"
  printf '%s' "${content}" > "${dest}"
}

_write_air_config() {
  write_if_changed "$1/.air.toml" <<'EOF'
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

_write_dockerfiles() {
  mkdir -p "$1/deploy"

  # Production image: compile a static binary, ship it on alpine.
  write_if_changed "$1/deploy/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1

# --- stage 1: build ----------------------------------------------------------
FROM golang:1.26-alpine AS builder

ARG GO_BUILD_CPUS=2

RUN apk add --no-cache git ca-certificates
WORKDIR /src

# Dependencies first so the module cache survives source-only changes.
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 produces a fully static binary that runs on a bare alpine.
# GOMAXPROCS + -p limit parallel compilation to 2 CPUs so the build does not
# saturate a 6-core server. Override with GO_BUILD_CPUS=6 in Coolify if needed.
RUN CGO_ENABLED=0 GOOS=linux GOMAXPROCS=${GO_BUILD_CPUS} go build -p=${GO_BUILD_CPUS} \
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
  write_if_changed "$1/deploy/Dockerfile.dev" <<'EOF'
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
  # directories.
  #
  # mongodb is asserted explicitly: if the base image ever drops it, the build
  # fails loudly instead of the CMS silently falling back to mongolite. The
  # stock image ships install-php-extensions and the Flysystem S3 adapter + AWS
  # SDK under lib/vendor/ (it has no composer binary, so a composer step would
  # fail the build).
  write_if_changed "$1/deploy/Dockerfile.cms" <<'EOF'
FROM cockpithq/cockpit:core-2.14.0

RUN install-php-extensions mongodb

COPY cockpit/config.php /var/www/html/config/config.php
COPY cockpit/addons/ /var/www/html/addons/
EOF

  write_if_changed "$1/.dockerignore" <<'EOF'
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
