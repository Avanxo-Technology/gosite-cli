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

# --- locking ------------------------------------------------------------------
# Portable mutual exclusion built on mkdir(2), which is atomic on POSIX and
# available on macOS, where flock(1) does not ship. A lock is a directory
# "<target>.lock" holding the owner pid; release removes it. Locks left behind
# by dead processes are reclaimed by checking the pid (kill -0) and, as a
# fallback for owners that died before writing their pid, the lock's age.

# Seconds to wait for a contended lock before giving up with a clear error.
: "${GOSITE_LOCK_TIMEOUT:=30}"

# A lock older than this whose pid is gone (or was never written) is orphaned.
readonly GOSITE_LOCK_STALE_SECONDS=600

_lock_release() {
  rm -rf "$1"
  debug "Lock released: $1"
}

# Returns 0 when the lock was reclaimed (removed), 1 while an owner may live.
_lock_reclaim() {
  local lockdir="$1" pid mtime now
  [[ -d "${lockdir}" ]] || return 0

  pid="$(cat "${lockdir}/pid" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    return 1
  fi

  # Pid gone or never written. Only reclaim past an age bound so a live owner
  # still between mkdir and its pid write keeps its lock.
  now="$(date +%s)"
  mtime="$(stat -f %m "${lockdir}" 2>/dev/null || stat -c %Y "${lockdir}" 2>/dev/null || echo "${now}")"
  if (( now - mtime < GOSITE_LOCK_STALE_SECONDS )); then
    return 1
  fi

  debug "Reclaiming orphaned lock ${lockdir} (pid '${pid:-?}' is gone, age $((now - mtime))s)."
  rm -rf "${lockdir}"
}

# with_lock <state-file> <function> [args...]
#
# Runs <function> while holding an exclusive lock on <state-file>. Acquiring
# is mkdir (atomic), release happens through a trap even if <function> fails,
# exits or is interrupted. Contention waits up to GOSITE_LOCK_TIMEOUT seconds.
with_lock() {
  local target="$1" fn="$2"; shift 2
  local lockdir="${target}.lock" start=$SECONDS pid="?"

  until mkdir "${lockdir}" 2>/dev/null; do
    _lock_reclaim "${lockdir}" && continue
    if (( SECONDS - start >= GOSITE_LOCK_TIMEOUT )); then
      pid="$(cat "${lockdir}/pid" 2>/dev/null || printf '?')"
      err "Timed out after ${GOSITE_LOCK_TIMEOUT}s waiting for lock ${lockdir} (held by pid ${pid})."
      return 1
    fi
    sleep 0.25
  done
  printf '%s\n' "$$" > "${lockdir}/pid"
  debug "Lock acquired: ${lockdir}"

  # Release no matter how the wrapped function ends: failure, exit() or signal.
  # Double quotes are deliberate: the CURRENT lockdir is baked into the trap
  # when it is armed, not whatever the variable holds when it fires.
  # shellcheck disable=SC2064
  trap "_lock_release '${lockdir}'" EXIT
  set +e
  "${fn}" "$@"
  local rc=$?
  set -e
  _lock_release "${lockdir}"
  trap - EXIT
  return "${rc}"
}

# Publishes stdin to <file> atomically: write a temp file in the destination's
# own directory (same filesystem, so mv(2) is a rename) and rename it into
# place. An interruption therefore leaves either the old or the new complete
# content, never a partial file.
publish_atomic() {
  local dest="$1" tmp
  tmp="$(mktemp "$(dirname "${dest}")/.gosite.XXXXXX")"
  cat > "${tmp}"
  mv "${tmp}" "${dest}"
}

# --- project registry --------------------------------------------------------
# A flat "<name>\t<path>" index so projects can be resolved by name from any
# directory. Written on create/start under a lock; reading never rewrites.

registry_register() {
  local dir="$1" name
  is_gosite_project "${dir}" || return 0
  name="$(basename "${dir}")"
  mkdir -p "$(dirname "${GOSITE_REGISTRY}")"
  [[ -f "${GOSITE_REGISTRY}" ]] || touch "${GOSITE_REGISTRY}"
  with_lock "${GOSITE_REGISTRY}" _registry_register_locked "${name}" "${dir}"
}

_registry_register_locked() {
  local name="$1" dir="$2" tmp
  # Drop any previous entry for this name, append the current path.
  tmp="$(mktemp "$(dirname "${GOSITE_REGISTRY}")/.gosite.XXXXXX")"
  grep -v -e "^${name}	" "${GOSITE_REGISTRY}" > "${tmp}" 2>/dev/null || true
  printf '%s\t%s\n' "${name}" "${dir}" >> "${tmp}"
  sort -o "${tmp}" "${tmp}"
  mv "${tmp}" "${GOSITE_REGISTRY}"
}

registry_forget() {
  [[ -f "${GOSITE_REGISTRY}" ]] || return 0
  with_lock "${GOSITE_REGISTRY}" _registry_forget_locked "$1"
}

_registry_forget_locked() {
  local name="$1" tmp
  tmp="$(mktemp "$(dirname "${GOSITE_REGISTRY}")/.gosite.XXXXXX")"
  grep -v -e "^${name}	" "${GOSITE_REGISTRY}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${GOSITE_REGISTRY}"
}

# Prints "<name>\t<path>\t<available|unavailable>" for every registered
# project. Pure read: entries whose directory has disappeared are reported as
# unavailable instead of being silently rewritten out of existence - pruning
# only happens through registry_prune ('gosite list --prune'), under lock.
registry_entries() {
  [[ -f "${GOSITE_REGISTRY}" ]] || return 0
  # The third var absorbs any trailing columns so a stray tab can never end
  # up inside the path.
  local name path rest state
  while IFS=$'\t' read -r name path rest; do
    [[ -n "${name}" ]] || continue
    if is_gosite_project "${path}"; then
      state="available"
    else
      state="unavailable"
    fi
    printf '%s\t%s\t%s\n' "${name}" "${path}" "${state}"
  done < "${GOSITE_REGISTRY}"
}

registry_lookup() {
  registry_entries | awk -F'\t' -v n="$1" '$1 == n { print $2; exit }'
}

# Removes registry entries whose project directory no longer exists. The only
# maintenance path that mutates the registry on account of missing dirs, and
# it runs under the registry lock.
registry_prune() {
  [[ -f "${GOSITE_REGISTRY}" ]] || return 0
  with_lock "${GOSITE_REGISTRY}" _registry_prune_locked
}

_registry_prune_locked() {
  local name path rest removed=0
  while IFS=$'\t' read -r name path rest; do
    [[ -n "${name}" ]] || continue
    if ! is_gosite_project "${path}"; then
      warn "Pruning '${name}' from the registry: ${path} no longer exists."
      removed=$(( removed + 1 ))
    fi
  done < "${GOSITE_REGISTRY}"

  (( removed > 0 )) || return 0
  local tmp
  tmp="$(mktemp "$(dirname "${GOSITE_REGISTRY}")/.gosite.XXXXXX")"
  {
    while IFS=$'\t' read -r name path rest; do
      [[ -n "${name}" ]] || continue
      is_gosite_project "${path}" && printf '%s\t%s\n' "${name}" "${path}"
    done < "${GOSITE_REGISTRY}"
  } | sort > "${tmp}"
  mv "${tmp}" "${GOSITE_REGISTRY}"
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
# Drops Cockpit's module registry cache.
#
# Cockpit records which addons exist in storage/cache/modules.cache.php and only
# rebuilds it when its own version or env dir changes - never when an addon
# appears or disappears. Clearing it at install time is not enough and is in
# fact worse: addons are baked into the CMS image, so between the install and
# the rebuild Cockpit is still running the old image, regenerates the cache
# without the new addon, and that stale file then survives the rebuild. The
# addon is on disk inside the container and invisible in the panel.
#
# Clearing it here, on the way up, is the only point where the image and the
# cache are guaranteed to agree. Cockpit rebuilds it on the first request.
clear_cockpit_module_cache() {
  local dir="$1"
  rm -f "${dir}/cockpit-storage/cache/modules.cache.php" \
        "${dir}/cockpit-storage/cache/addons.cache.php" 2>/dev/null || true
}

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

# Checks whether a running container has a specific label value. Returns 0
# (true) when the label matches, 1 when it is missing or differs. Used by
# `gosite infra up` to detect stale Traefik labels that `docker compose up`
# would not trigger a recreation for.
container_label_matches() {
  local container="$1" label="$2" expected="$3"
  local actual
  actual="$(docker inspect "${container}" --format "{{index .Config.Labels \"${label}\"}}" 2>/dev/null)" || return 1
  [[ "${actual}" == "${expected}" ]]
}

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

# Chooses the app and CMS ports and records their reservation inside a single
# critical section, so two concurrent `gosite create` runs can never select
# the same port: selection reads the reservation file under the same lock the
# write holds, making pick-and-record one indivisible operation.
#
# On success the ports are in GOSITE_ALLOCATED_PORTS ("app cms") - a
# documented interface global read by cmd_create.
# shellcheck disable=SC2034
allocate_ports() {
  local project="$1" start="${2:-${GOSITE_PORT_MIN}}"
  GOSITE_ALLOCATED_PORTS=""
  mkdir -p "$(dirname "${GOSITE_PORTS_FILE}")"
  [[ -f "${GOSITE_PORTS_FILE}" ]] || touch "${GOSITE_PORTS_FILE}"
  with_lock "${GOSITE_PORTS_FILE}" _allocate_ports_locked "${project}" "${start}"
}

_allocate_ports_locked() {
  local project="$1" start="$2" port app_port="" cms_port=""

  # One snapshot of everything that can occupy a port, taken once per scan:
  # forking lsof per candidate port made the critical section O(ports) slow
  # and starved concurrent allocations past the lock timeout.
  GOSITE_DOCKER_PUBLISHED="$(docker ps --format '{{.Ports}}' 2>/dev/null || true)"
  GOSITE_LISTENING_PORTS="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | grep -oE '[0-9]+$' | sort -u || true)"

  for (( port = start; port <= GOSITE_PORT_MAX; port++ )); do
    _port_in_use "${port}" && continue
    app_port="${port}"
    break
  done
  if [[ -z "${app_port}" ]]; then
    err "No free port available in range ${start}-${GOSITE_PORT_MAX}; cannot create '${project}'."
    return 1
  fi

  for (( port = app_port + 1; port <= GOSITE_PORT_MAX; port++ )); do
    _port_in_use "${port}" && continue
    cms_port="${port}"
    break
  done
  if [[ -z "${cms_port}" ]]; then
    err "No second free port available after ${app_port} (range ${start}-${GOSITE_PORT_MAX})."
    return 1
  fi

  local tmp
  tmp="$(mktemp "$(dirname "${GOSITE_PORTS_FILE}")/.gosite.XXXXXX")"
  grep -v -e "^${project}	" "${GOSITE_PORTS_FILE}" > "${tmp}" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "${project}" "${app_port}" "${cms_port}" >> "${tmp}"
  mv "${tmp}" "${GOSITE_PORTS_FILE}"

  # Interface global read by cmd_create ("app cms").
  # shellcheck disable=SC2034
  GOSITE_ALLOCATED_PORTS="${app_port} ${cms_port}"
}

reserve_ports() {
  local project="$1"; shift
  mkdir -p "$(dirname "${GOSITE_PORTS_FILE}")"
  [[ -f "${GOSITE_PORTS_FILE}" ]] || touch "${GOSITE_PORTS_FILE}"
  with_lock "${GOSITE_PORTS_FILE}" _reserve_ports_locked "${project}" "$@"
}

_reserve_ports_locked() {
  local project="$1"; shift col tmp
  tmp="$(mktemp "$(dirname "${GOSITE_PORTS_FILE}")/.gosite.XXXXXX")"
  grep -v -e "^${project}	" "${GOSITE_PORTS_FILE}" > "${tmp}" 2>/dev/null || true
  printf '%s' "${project}" >> "${tmp}"
  for col in "$@"; do
    printf '\t%s' "${col}" >> "${tmp}"
  done
  printf '\n' >> "${tmp}"
  mv "${tmp}" "${GOSITE_PORTS_FILE}"
}

release_ports() {
  [[ -f "${GOSITE_PORTS_FILE}" ]] || return 0
  with_lock "${GOSITE_PORTS_FILE}" _release_ports_locked "$1"
}

_release_ports_locked() {
  local project="$1" tmp
  tmp="$(mktemp "$(dirname "${GOSITE_PORTS_FILE}")/.gosite.XXXXXX")"
  grep -v -e "^${project}	" "${GOSITE_PORTS_FILE}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${GOSITE_PORTS_FILE}"
}

_port_is_reserved() {
  [[ -f "${GOSITE_PORTS_FILE}" ]] || return 1
  awk '{ for (i = 2; i <= NF; i++) print $i }' "${GOSITE_PORTS_FILE}" | grep -qwF "$1"
}

_port_is_listening() {
  # Exact line match against the lsof snapshot; the newline framing keeps
  # 800 from matching 8000.
  case "
${GOSITE_LISTENING_PORTS:-}
" in *"
$1
"*) return 0 ;; esac
  return 1
}

# A port is unusable when gosite has reserved it, something is listening on
# it, or Docker has a container publishing it (Docker Desktop hides mappings
# from lsof). The reserved check runs first: it is the cheapest and, under
# concurrent creations, the most common hit.
_port_in_use() {
  _port_is_reserved "$1" && return 0
  _port_is_listening "$1" && return 0
  _port_is_docker_mapped "$1"
}

_port_is_docker_mapped() {
  printf '%s\n' "${GOSITE_DOCKER_PUBLISHED:-}" | grep -qE '0\.0\.0\.0:'"$1"'(->|/|$)'
}

# --- dependency checks -------------------------------------------------------
# Required tools break the CLI outright; optional ones only degrade the local
# workflow (you can still run everything inside containers).
readonly GOSITE_REQUIRED_DEPS=(docker)
readonly GOSITE_OPTIONAL_DEPS=(go air git openssl yq)

dep_hint() {
  case "$1" in
    docker) echo "https://docs.docker.com/get-docker/" ;;
    go)     echo "https://go.dev/dl/ (1.25+, required by Echo v5)" ;;
    air)    echo "go install github.com/air-verse/air@latest" ;;
    git)    echo "https://git-scm.com/downloads" ;;
    openssl) echo "used to generate project secrets" ;;
    yq)      echo "brew install yq (mikefarah v4) - enables structural YAML drift reports in 'sync --report'" ;;
    mkcert)  echo "gosite setup - issues the local HTTPS certificates" ;;
    dnsmasq) echo "gosite setup - resolves *.test to 127.0.0.1" ;;
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

# sha256 of a file's content, portable across macOS/Linux toolchains.
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# --- shared MinIO credentials -------------------------------------------------
# Resolves the root credentials of the shared MinIO installation:
#   1. ${GOSITE_INFRA_DIR}/minio.env, persisted by a previous resolution (0600)
#   2. Legacy installations: an existing *gosite-miniodata volume holds data
#      created under the old fixed minioadmin/minioadmin pair - keep using it
#      and set GOSITE_MINIO_LEGACY=1 so callers can explain how to rotate
#   3. Fresh install: generate a random pair once and persist it
#
# Sets MINIO_ROOT_USER / MINIO_ROOT_PASSWORD on return. Safe to call repeatedly;
# cheap after the first call.
resolve_minio_credentials() {
  [[ -n "${MINIO_ROOT_USER:-}" && -n "${MINIO_ROOT_PASSWORD:-}" ]] && return 0

  local credfile="${GOSITE_INFRA_DIR}/minio.env"
  if [[ -f "${credfile}" ]]; then
    # shellcheck source=/dev/null
    source "${credfile}"
    return 0
  fi

  GOSITE_MINIO_LEGACY=0
  local legacy_volume=""
  legacy_volume="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep 'gosite-miniodata' | head -1 || true)"

  if [[ -n "${legacy_volume}" ]]; then
    MINIO_ROOT_USER="minioadmin"
    MINIO_ROOT_PASSWORD="minioadmin"
    GOSITE_MINIO_LEGACY=1
    export MINIO_ROOT_USER MINIO_ROOT_PASSWORD GOSITE_MINIO_LEGACY
    return 0
  fi

  mkdir -p "${GOSITE_INFRA_DIR}"
  MINIO_ROOT_USER="gosite-$(random_secret 8)"
  MINIO_ROOT_PASSWORD="$(random_secret 24)"
  local tmp="${GOSITE_INFRA_DIR}/.minio.env.$$"
  {
    printf '# Generated by gosite - shared MinIO root credentials. chmod 600.\n'
    printf 'MINIO_ROOT_USER=%s\n' "${MINIO_ROOT_USER}"
    printf 'MINIO_ROOT_PASSWORD=%s\n' "${MINIO_ROOT_PASSWORD}"
  } > "${tmp}"
  chmod 0600 "${tmp}"
  mv "${tmp}" "${credfile}"
  export MINIO_ROOT_USER MINIO_ROOT_PASSWORD
}
