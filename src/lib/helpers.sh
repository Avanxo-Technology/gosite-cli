#!/usr/bin/env bash
#
# Shared helpers: logging, prompts, validation and dependency checks.
#

# --- logging -----------------------------------------------------------------
info()  { printf "${C_BLUE}==>${C_NC} %s\n" "$*"; }
ok()    { printf "${C_GREEN}  ok${C_NC} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}   ! ${C_NC}%s\n" "$*" >&2; }
err()   { printf "${C_RED}   x ${C_NC}%s\n" "$*" >&2; }
debug() { [[ "${GOSITE_VERBOSE}" -eq 1 ]] && printf "${C_DIM}  .. %s${C_NC}\n" "$*" >&2 || true; }
fatal() { err "$*"; exit 1; }

confirm() {
  [[ "${GOSITE_ASSUME_YES}" -eq 1 ]] && return 0
  local reply
  printf "${C_YELLOW}?${C_NC} %s [y/N] " "$1"
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# --- validation --------------------------------------------------------------
# Project names become container names, DNS hostnames and Go module paths.
validate_project_name() {
  local name="$1"
  [[ -n "${name}" ]] || fatal "A project name is required."
  [[ "${name}" =~ ^[a-z][a-z0-9-]{1,38}[a-z0-9]$ ]] || fatal \
    "Invalid project name '${name}'. Use lowercase letters, digits and dashes (3-40 chars), starting with a letter."
}

is_gosite_project() { [[ -f "${1:-.}/${GOSITE_MARKER}" ]]; }

# Resolve a project directory from an optional name argument, falling back to
# the current directory when it is already a gosite project.
resolve_project_dir() {
  local name="${1:-}"
  if [[ -n "${name}" ]]; then
    [[ -d "${name}" ]] || fatal "Project directory './${name}' does not exist."
    (cd "${name}" && pwd)
  elif is_gosite_project "."; then
    pwd
  else
    fatal "Not inside a gosite project. Pass a project name or cd into one."
  fi
}

# --- docker helpers ----------------------------------------------------------
# Supports both the compose v2 plugin and the legacy standalone binary.
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

docker_running()   { docker info >/dev/null 2>&1; }
network_exists()   { docker network inspect "$1" >/dev/null 2>&1; }
container_exists() { [[ -n "$(docker ps -aq -f "name=^$1$")" ]]; }
container_running(){ [[ -n "$(docker ps -q  -f "name=^$1$")" ]]; }

ensure_network() {
  if network_exists "${GOSITE_NETWORK}"; then
    debug "Network '${GOSITE_NETWORK}' already exists."
  else
    info "Creating shared network '${GOSITE_NETWORK}'"
    docker network create "${GOSITE_NETWORK}" >/dev/null
    ok "Network created."
  fi
}

# Find a free TCP port on the host inside the configured range.
find_free_port() {
  local start="${1:-${GOSITE_PORT_MIN}}" port
  for (( port = start; port <= GOSITE_PORT_MAX; port++ )); do
    if ! lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      printf "%s" "${port}"
      return 0
    fi
  done
  fatal "No free port available in range ${GOSITE_PORT_MIN}-${GOSITE_PORT_MAX}."
}

# --- dependency checks -------------------------------------------------------
# Required tools break the CLI outright; optional ones only degrade the local
# workflow (you can still run everything inside containers).
readonly GOSITE_REQUIRED_DEPS=(docker)
readonly GOSITE_OPTIONAL_DEPS=(go templ air git openssl)

dep_hint() {
  case "$1" in
    docker) echo "https://docs.docker.com/get-docker/" ;;
    go)     echo "https://go.dev/dl/ (1.22+)" ;;
    templ)  echo "go install github.com/a-h/templ/cmd/templ@latest" ;;
    air)    echo "go install github.com/air-verse/air@latest" ;;
    git)    echo "https://git-scm.com/downloads" ;;
    openssl) echo "used to generate project secrets" ;;
    *)      echo "" ;;
  esac
}

# require_dependencies            -> hard check, exits on missing required tool
# require_dependencies --report   -> full `gosite doctor` report
require_dependencies() {
  local report=0 missing=0 dep
  [[ "${1:-}" == "--report" ]] && report=1

  [[ "${report}" -eq 1 ]] && info "Checking local dependencies"

  for dep in "${GOSITE_REQUIRED_DEPS[@]}"; do
    if command -v "${dep}" >/dev/null 2>&1; then
      [[ "${report}" -eq 1 ]] && ok "${dep} ($(command -v "${dep}"))"
    else
      err "Missing required dependency: ${dep} -> $(dep_hint "${dep}")"
      missing=1
    fi
  done

  # docker compose ships either as a plugin or a separate binary.
  if docker compose version >/dev/null 2>&1; then
    [[ "${report}" -eq 1 ]] && ok "docker compose (v2 plugin)"
  elif command -v docker-compose >/dev/null 2>&1; then
    [[ "${report}" -eq 1 ]] && ok "docker-compose (standalone)"
  else
    err "Missing required dependency: docker compose -> https://docs.docker.com/compose/install/"
    missing=1
  fi

  for dep in "${GOSITE_OPTIONAL_DEPS[@]}"; do
    if command -v "${dep}" >/dev/null 2>&1; then
      [[ "${report}" -eq 1 ]] && ok "${dep} ($(command -v "${dep}"))"
    else
      [[ "${report}" -eq 1 ]] && warn "${dep} not found (optional) -> $(dep_hint "${dep}")"
    fi
  done

  if [[ "${report}" -eq 1 ]]; then
    if docker_running; then
      ok "Docker daemon is running."
    else
      err "Docker daemon is not reachable. Start Docker Desktop / the docker service."
      missing=1
    fi
    if network_exists "${GOSITE_NETWORK}"; then
      ok "Network '${GOSITE_NETWORK}' exists."
    else
      warn "Network '${GOSITE_NETWORK}' missing. Run 'gosite infra up'."
    fi
  fi

  [[ "${missing}" -eq 0 ]] || fatal "Resolve the errors above and try again."
  [[ "${report}" -eq 1 ]] && printf "\n${C_GREEN}All required dependencies are satisfied.${C_NC}\n"
  return 0
}

# --- misc --------------------------------------------------------------------
random_secret() {
  local len="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${len}"
  else
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c $(( len * 2 ))
  fi
}
