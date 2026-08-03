#!/usr/bin/env bash
#
# Global configuration. Every value can be overridden from the environment,
# which keeps the CLI testable without touching the real system.
#

# Shared Docker network every project and the global infra attach to.
: "${GOSITE_NETWORK:=gosite-network}"

# Where the shared infrastructure compose file and its data live.
: "${GOSITE_HOME:=${HOME}/.gosite}"
: "${GOSITE_INFRA_DIR:=${GOSITE_HOME}/infra}"
: "${GOSITE_INFRA_PROJECT:=gosite-infra}"

# Shared service container names, referenced by every project as DNS hostnames.
: "${GOSITE_PG_HOST:=gosite-postgres}"
: "${GOSITE_PG_PORT:=5432}"
: "${GOSITE_PG_USER:=gosite}"
: "${GOSITE_PG_PASSWORD:=gosite}"
: "${GOSITE_REDIS_HOST:=gosite-redis}"
: "${GOSITE_REDIS_PORT:=6379}"

# Host port range used when allocating ports for new projects.
: "${GOSITE_PORT_MIN:=8000}"
: "${GOSITE_PORT_MAX:=8999}"

# Marker file that identifies a directory as a gosite project.
: "${GOSITE_MARKER:=.gosite.env}"

# Index of known projects ("<name>\t<path>"), so they can be resolved by name
# from any directory.
: "${GOSITE_REGISTRY:=${GOSITE_HOME}/projects.tsv}"

export GOSITE_NETWORK GOSITE_HOME GOSITE_INFRA_DIR GOSITE_INFRA_PROJECT \
       GOSITE_PG_HOST GOSITE_PG_PORT GOSITE_PG_USER GOSITE_PG_PASSWORD \
       GOSITE_REDIS_HOST GOSITE_REDIS_PORT \
       GOSITE_PORT_MIN GOSITE_PORT_MAX GOSITE_MARKER GOSITE_REGISTRY
