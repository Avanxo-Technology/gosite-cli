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

# --- project registry --------------------------------------------------------
# A flat "<name>\t<path>" index so projects can be resolved by name from any
# directory. Written on create/start, self-healing on read.

registry_register() {
  local dir="$1" name
  is_gosite_project "${dir}" || return 0
  name="$(basename "${dir}")"
  mkdir -p "$(dirname "${GOSITE_REGISTRY}")"
  touch "${GOSITE_REGISTRY}"
  # Drop any previous entry for this name, then append the current path.
  local tmp; tmp="$(mktemp)"
  grep -v -e "^${name}	" "${GOSITE_REGISTRY}" > "${tmp}" 2>/dev/null || true
  printf '%s\t%s\n' "${name}" "${dir}" >> "${tmp}"
  sort -o "${tmp}" "${tmp}"
  mv "${tmp}" "${GOSITE_REGISTRY}"
}

registry_forget() {
  [[ -f "${GOSITE_REGISTRY}" ]] || return 0
  local tmp; tmp="$(mktemp)"
  grep -v -e "^$1	" "${GOSITE_REGISTRY}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${GOSITE_REGISTRY}"
}

# Prints "<name>\t<path>" for every registered project that still exists,
# rewriting the registry to drop entries whose directory is gone.
registry_entries() {
  [[ -f "${GOSITE_REGISTRY}" ]] || return 0
  local tmp; tmp="$(mktemp)"
  local name path
  while IFS=$'\t' read -r name path; do
    [[ -n "${name}" ]] || continue
    if is_gosite_project "${path}"; then
      printf '%s\t%s\n' "${name}" "${path}" >> "${tmp}"
    fi
  done < "${GOSITE_REGISTRY}"
  mv "${tmp}" "${GOSITE_REGISTRY}"
  cat "${GOSITE_REGISTRY}"
}

registry_lookup() {
  registry_entries | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }'
}

# Resolve a project directory. Resolution order:
#   1. an explicit ./<name> directory below the cwd
#   2. the registry, so any project can be reached by name from anywhere
#   3. <workspace>/<name>, in case the registry was lost
#   4. the current directory, when it is itself a project
resolve_project_dir() {
  local name="${1:-}"
  if [[ -n "${name}" ]]; then
    if is_gosite_project "${name}"; then
      (cd "${name}" && pwd)
      return 0
    fi
    local hit; hit="$(registry_lookup "${name}")"
    if [[ -n "${hit}" ]]; then
      printf '%s' "${hit}"
      return 0
    fi
    if is_gosite_project "${GOSITE_WORKSPACE}/${name}"; then
      printf '%s' "${GOSITE_WORKSPACE}/${name}"
      return 0
    fi
    fatal "Unknown project '${name}'. Run 'gosite list' to see the registered ones."
  elif is_gosite_project "."; then
    pwd
  else
    fatal "Not inside a gosite project. Pass a project name or cd into one."
  fi
}

# Cockpit's storage is bind-mounted, and a bind mount hides whatever the image
# ships at that path. The skeleton must therefore exist on the host, or Cockpit
# dies on a missing storage/cache directory. Idempotent, so it doubles as a
# repair for projects created before this was handled and for fresh clones
# (cockpit-storage/ is gitignored).
ensure_cockpit_storage() {
  local dir="$1" sub
  for sub in cache data logs tmp uploads; do
    [[ -d "${dir}/cockpit-storage/${sub}" ]] && continue
    mkdir -p "${dir}/cockpit-storage/${sub}"
    touch "${dir}/cockpit-storage/${sub}/.gitkeep"
    chmod 0777 "${dir}/cockpit-storage/${sub}"
    debug "Created missing cockpit-storage/${sub}"
  done
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

# Wraps a URL in an OSC 8 terminal hyperlink when stdout is a TTY, so the
# rendered text is clickable (iTerm2, Kitty, gnome-terminal, VS Code, ...).
# Without a TTY it prints the label unchanged.
hyperlink() {
  local url="$1" label="$2"
  if [[ -n "${C_NC}" ]]; then
    printf '\033]8;;%s\033\\%s\033]8;;\033\\' "${url}" "${label}"
  else
    printf '%s' "${label}"
  fi
}

docker_running()   { docker info >/dev/null 2>&1; }
network_exists()   { docker network inspect "$1" >/dev/null 2>&1; }
container_exists() { [[ -n "$(docker ps -aq -f "name=^$1$")" ]]; }
container_running(){ [[ -n "$(docker ps -q  -f "name=^$1$")" ]]; }
container_on_network(){ docker inspect "$1" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | grep -qw "$2"; }

ensure_network() {
  if network_exists "${GOSITE_NETWORK}"; then
    debug "Network '${GOSITE_NETWORK}' already exists."
  else
    info "Creating shared network '${GOSITE_NETWORK}'"
    docker network create "${GOSITE_NETWORK}" >/dev/null
    ok "Network created."
  fi
}

# --- port reservation ---------------------------------------------------------
# A persistent "<project>\t<app_port>\t<cms_port>" file that prevents port
# collisions between concurrent creations and survives daemon restarts.

reserve_ports() {
  mkdir -p "$(dirname "${GOSITE_PORTS_FILE}")"
  touch "${GOSITE_PORTS_FILE}"
  local tmp; tmp="$(mktemp)"
  grep -v -e "^$1	" "${GOSITE_PORTS_FILE}" > "${tmp}" 2>/dev/null || true
  printf '%s' "$1" >> "${tmp}"
  shift
  for col in "$@"; do
    printf '\t%s' "${col}" >> "${tmp}"
  done
  printf '\n' >> "${tmp}"
  mv "${tmp}" "${GOSITE_PORTS_FILE}"
}

release_ports() {
  [[ -f "${GOSITE_PORTS_FILE}" ]] || return 0
  local tmp; tmp="$(mktemp)"
  grep -v -e "^$1	" "${GOSITE_PORTS_FILE}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${GOSITE_PORTS_FILE}"
}

_port_is_reserved() {
  [[ -f "${GOSITE_PORTS_FILE}" ]] || return 1
  awk '{ for (i = 2; i <= NF; i++) print $i }' "${GOSITE_PORTS_FILE}" | grep -qwF "$1"
}

# Find a free TCP port on the host inside the configured range. Checks three
# independent sources so it works even when Docker Desktop hides its mappings
# from lsof.
find_free_port() {
  local start="${1:-${GOSITE_PORT_MIN}}" port
  for (( port = start; port <= GOSITE_PORT_MAX; port++ )); do
    lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && continue
    docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE '0\.0\.0\.0:'"${port}"'(->|/|$)' && continue
    _port_is_reserved "${port}" && continue
    printf "%s" "${port}"
    return 0
  done
  fatal "No free port available in range ${GOSITE_PORT_MIN}-${GOSITE_PORT_MAX}."
}

# --- dependency checks -------------------------------------------------------
# Required tools break the CLI outright; optional ones only degrade the local
# workflow (you can still run everything inside containers).
readonly GOSITE_REQUIRED_DEPS=(docker)
readonly GOSITE_OPTIONAL_DEPS=(go air git openssl)

dep_hint() {
  case "$1" in
    docker) echo "https://docs.docker.com/get-docker/" ;;
    go)     echo "https://go.dev/dl/ (1.25+, required by Echo v5)" ;;
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
