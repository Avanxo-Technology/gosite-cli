#!/usr/bin/env bash
#
# Global configuration. Every value can be overridden from the environment,
# which keeps the CLI testable without touching the real system.
#

# Shared Docker network every project and the global infra attach to.
: "${GOSITE_NETWORK:=gosite-network}"

# Where projects are created and looked for. Keeping every site under one
# directory is what makes `list` and the registry predictable.
: "${GOSITE_WORKSPACE:=${HOME}/gosites}"

# Where the shared infrastructure compose file and its data live.
: "${GOSITE_HOME:=${HOME}/.gosite}"
: "${GOSITE_INFRA_DIR:=${GOSITE_HOME}/infra}"
: "${GOSITE_INFRA_PROJECT:=gosite-infra}"

# Image versions for the shared infrastructure. Pinned and overridable.
: "${GOSITE_TRAEFIK_VERSION:=v3.7}"
: "${GOSITE_REDIS_VERSION:=8}"
: "${GOSITE_MONGO_VERSION:=8.0}"

# Shared service container names, referenced by every project as DNS hostnames.
: "${GOSITE_REDIS_HOST:=gosite-redis}"
: "${GOSITE_REDIS_PORT:=6379}"
: "${GOSITE_MONGO_HOST:=gosite-mongo}"
: "${GOSITE_MONGO_PORT:=27017}"
: "${GOSITE_MINIO_HOST:=gosite-minio}"

# Host address the shared datastores (Mongo, Redis, MinIO) publish their ports
# on. Loopback by default: they run without authentication and must not be
# reachable from the LAN. Traefik keeps binding to every interface, since
# serving the local domains is its purpose. Set GOSITE_BIND_ADDRESS=0.0.0.0
# to deliberately expose the datastores to your network.
: "${GOSITE_BIND_ADDRESS:=127.0.0.1}"

# Local domains. Projects are served at <name>.<TLD> and cms.<name>.<TLD>
# through the shared Traefik proxy, over HTTPS with mkcert certificates.
: "${GOSITE_TLD:=test}"
: "${GOSITE_PROXY_HOST:=gosite-proxy}"
: "${GOSITE_PROXY_HTTP_PORT:=80}"
: "${GOSITE_PROXY_HTTPS_PORT:=443}"
: "${GOSITE_CERTS_DIR:=${GOSITE_HOME}/certs}"
: "${GOSITE_DYNAMIC_DIR:=${GOSITE_HOME}/traefik/dynamic}"

# Host port range used when allocating ports for new projects.
: "${GOSITE_PORT_MIN:=8000}"
: "${GOSITE_PORT_MAX:=8999}"

# Marker file that identifies a directory as a gosite project.
: "${GOSITE_MARKER:=.gosite.env}"

# Index of known projects ("<name>\t<path>"), so they can be resolved by name
# from any directory.
: "${GOSITE_REGISTRY:=${GOSITE_HOME}/projects.tsv}"

# Port reservation file ("<project>\t<app_port>\t<cms_port>") so concurrent
# creations don't collide and stale reservations are cleaned on remove.
: "${GOSITE_PORTS_FILE:=${GOSITE_HOME}/ports.tsv}"

export GOSITE_NETWORK GOSITE_WORKSPACE GOSITE_HOME GOSITE_INFRA_DIR GOSITE_INFRA_PROJECT \
       GOSITE_REDIS_HOST GOSITE_REDIS_PORT \
       GOSITE_MONGO_HOST GOSITE_MONGO_PORT GOSITE_MONGO_VERSION \
       GOSITE_MINIO_HOST GOSITE_BIND_ADDRESS \
       GOSITE_PORT_MIN GOSITE_PORT_MAX GOSITE_MARKER GOSITE_REGISTRY GOSITE_PORTS_FILE \
       GOSITE_TLD GOSITE_PROXY_HOST GOSITE_PROXY_HTTP_PORT GOSITE_PROXY_HTTPS_PORT \
       GOSITE_CERTS_DIR GOSITE_DYNAMIC_DIR \
       GOSITE_TRAEFIK_VERSION GOSITE_REDIS_VERSION
