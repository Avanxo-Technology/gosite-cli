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
# shellcheck source=../lib/manifest.sh
source "${GOSITE_ROOT}/lib/manifest.sh"

cmd_create() {
  local PROJECT_NAME="" here=0 ADDONS="" INSTALL_ADDONS=0 ADDONS_PROMPT=1
  local STORAGE_PROMPT=1 DATABASE_PROMPT=1 TAILWIND_PROMPT=1
  # Tailwind is on by default but prompted; --no-tailwind swaps it for a small
  # stylesheet. Either way the generated markup is clean: no orphan utility classes.
  TAILWIND=1
  # S3/MinIO uploads and the shared MongoDB are the defaults; the prompts below
  # can switch them per project.
  STORAGE_ADAPTER=s3
  DATABASE=mongodb
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --here)         here=1; shift ;;
      --no-tailwind)  TAILWIND=0; TAILWIND_PROMPT=0; shift ;;
      --tailwind)     TAILWIND=1; TAILWIND_PROMPT=0; shift ;;
      --addons)       INSTALL_ADDONS=1; ADDONS_PROMPT=0; [[ -n "${2:-}" ]] || fatal "--addons needs a list of addon names"; ADDONS="$2"; shift 2 ;;
      --no-addons)    INSTALL_ADDONS=0; ADDONS_PROMPT=0; shift ;;
      --storage)      [[ -n "${2:-}" ]] || fatal "--storage needs a value (s3|local)"; STORAGE_ADAPTER="$2"; STORAGE_PROMPT=0; shift 2 ;;
      --database)     [[ -n "${2:-}" ]] || fatal "--database needs a value (mongodb|local)"; DATABASE="$2"; DATABASE_PROMPT=0; shift 2 ;;
      -*)             fatal "Unknown flag for 'create': $1 (expected --here, --no-tailwind, --tailwind, --no-addons, --addons, --storage, --database)" ;;
      *)              PROJECT_NAME="$1"; shift ;;
    esac
  done

  validate_project_name "${PROJECT_NAME}"
  require_dependencies
  _prompt_tailwind
  _prompt_addons
  _prompt_storage
  _prompt_database

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
  # Selection and reservation are one locked operation, so two concurrent
  # creations can never pick the same port.
  if ! allocate_ports "${PROJECT_NAME}" "${GOSITE_PORT_MIN}"; then
    exit 1
  fi
  read -r APP_PORT CMS_PORT <<< "${GOSITE_ALLOCATED_PORTS}"
  # Render vars: templates.sh reads these while expanding __PLACEHOLDER__
  # tokens, so they are assigned-but-unused from this file's point of view.
  # shellcheck disable=SC2034
  CMS_TOKEN="$(random_secret 24)"
  # shellcheck disable=SC2034
  COCKPIT_SEC_KEY="$(random_secret 32)"
  APP_DOMAIN="$(project_domain "${PROJECT_NAME}")"
  CMS_DOMAIN="$(project_cms_domain "${PROJECT_NAME}")"

  # A failed scaffold used to leave a half-written directory behind that
  # `gosite remove` could not clean up, because the marker file is written last.
  # Remove it on any non-zero exit instead - and release the port reservation,
  # so a failed create does not leak reserved ports.
  trap 'rc=$?; rm -rf "${PROJECT_DIR}"; release_ports "${PROJECT_NAME}"; err "Scaffold failed; removed ${PROJECT_DIR}."' ERR

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

  # Every generated source is a real file under src/templates/ (design D8);
  # the tree renderer picks the styling flavor and reproduces the exact byte
  # layout the old heredoc writers produced.
  render_template_tree "${GOSITE_ROOT}/templates" "${PROJECT_DIR}" full

  _write_builtin_addons "${PROJECT_DIR}"

  # An addon that also has an application side (the blog serves its own pages)
  # overlays its Go package, its router wiring and its templates now, so the
  # placeholder pass below covers them like every other generated file.
  if [[ "${INSTALL_ADDONS}" -eq 1 ]]; then
    local addon
    for addon in ${ADDONS}; do
      addon_has_overlay "${addon}" || continue
      render_addon_overlay "${GOSITE_ROOT}/templates" "${PROJECT_DIR}" \
        "$(printf '%s' "${addon}" | tr '[:upper:]' '[:lower:]')" >/dev/null
      info "Added the ${addon} application pages"
    done
  fi

  local f
  while IFS= read -r f; do render_placeholders "${f}"; done < <(
    find "${PROJECT_DIR}" -type f ! -name '*.png' ! -name '*.ico'
  )
  # A surviving __TOKEN__ means a template and the substitution list drifted
  # apart - fail the scaffold naming the file and the token (design D8).
  assert_no_placeholders "${PROJECT_DIR}"

  # go.sum must be committed: the production image builds with the default
  # GOFLAGS and refuses to compile without verified module checksums.
  _resolve_dependencies "${PROJECT_DIR}"

  # Optional Cockpit addons (Forms + Replica), copied from gosite's own
  # src/addons/ library; --no-addons skips them. Built-in addons were already
  # written by _write_builtin_addons.
  [[ "${INSTALL_ADDONS}" -eq 1 ]] && _install_addons "${PROJECT_DIR}" "${ADDONS}"

  # Issue the local TLS certificate covering <name>.test and cms.<name>.test.
  ensure_project_cert "${PROJECT_NAME}" || true

  # Record what gosite just wrote, so future syncs can tell untouched files
  # apart from hand-edited ones.
  manifest_write_from_dir "${PROJECT_DIR}"

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
# Prompt the user about Tailwind CSS interactively. When --no-tailwind or
# --tailwind is used the prompt is skipped. If -y/--yes is set, skips with
# the default (Tailwind on).
_prompt_tailwind() {
  [[ "${TAILWIND_PROMPT}" -eq 0 ]] && return 0
  [[ "${GOSITE_ASSUME_YES}" -eq 1 ]] && return 0

  printf "\n"
  printf "${C_BOLD}Styling${C_NC}\n"
  printf "  ${C_DIM}A CSS reset is always included via CDN.${C_NC}\n"

  printf "${C_YELLOW}?${C_NC} Use Tailwind CSS ${C_DIM}(utility-first CSS framework, loaded from CDN)${C_NC} [Y/n] "
  local reply
  read -r reply
  if [[ "${reply}" =~ ^[Nn]$ ]]; then
    TAILWIND=0
    info "Using plain CSS (static/styles.css)."
  else
    # Render var: render_template_tree picks the styling flavor from it.
    # shellcheck disable=SC2034
    TAILWIND=1
    ok "Tailwind CSS enabled."
  fi
}

# -----------------------------------------------------------------------------
# Prompt the user to pick Cockpit addons interactively. When --no-addons or
# --addons is used the prompt is skipped. If -y/--yes is set, skips with none.
_prompt_addons() {
  [[ "${ADDONS_PROMPT}" -eq 0 ]] && return 0
  [[ "${GOSITE_ASSUME_YES}" -eq 1 ]] && return 0

  printf "\n"
  printf "${C_BOLD}Cockpit addons${C_NC}\n"
  printf "  ${C_DIM}Optional: public forms, a blog, content replication.${C_NC}\n"

  local selected=""

  printf "${C_YELLOW}?${C_NC} Install Forms ${C_DIM}(public form submissions with anti-spam, CSV export)${C_NC} [y/N] "
  local reply
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]] && selected="Forms"

  printf "${C_YELLOW}?${C_NC} Install Blog ${C_DIM}(articles at /{blog}/{slug}, with CMS models and pages)${C_NC} [y/N] "
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]] && selected="${selected:+${selected} }Blog"

  printf "${C_YELLOW}?${C_NC} Install Replica ${C_DIM}(content replication between Cockpit instances)${C_NC} [y/N] "
  read -r reply
  [[ "${reply}" =~ ^[Yy]$ ]] && selected="${selected:+${selected} }Replica"

  if [[ -n "${selected}" ]]; then
    ADDONS="${selected}"
    INSTALL_ADDONS=1
    ok "Will install: ${selected}"
  else
    info "No addons selected."
  fi
}

# -----------------------------------------------------------------------------
# Ask where uploaded assets live. Default is S3/MinIO (shared infra); 'local'
# keeps uploads on the project disk. Skipped by --storage or -y/--yes.
_prompt_storage() {
  [[ "${STORAGE_PROMPT}" -eq 0 ]] && return 0
  [[ "${GOSITE_ASSUME_YES}" -eq 1 ]] && return 0

  printf "\n"
  printf "${C_BOLD}Asset uploads${C_NC}\n"
  printf "  ${C_DIM}Where the CMS keeps uploaded files.${C_NC}\n"

  printf "${C_YELLOW}?${C_NC} Uploads ${C_DIM}(default: S3/MinIO)${C_NC} [S3/local] "
  local reply
  read -r reply
  case "${reply}" in
    l|L|local) STORAGE_ADAPTER=local ;;
    *)         STORAGE_ADAPTER=s3 ;;
  esac
  ok "Asset uploads: ${STORAGE_ADAPTER}"
}

# -----------------------------------------------------------------------------
# Ask where content lives. Default is MongoDB (shared infra); 'local' uses the
# self-contained mongolite storage. Skipped by --database or -y/--yes.
_prompt_database() {
  [[ "${DATABASE_PROMPT}" -eq 0 ]] && return 0
  [[ "${GOSITE_ASSUME_YES}" -eq 1 ]] && return 0

  printf "\n"
  printf "${C_BOLD}Content database${C_NC}\n"
  printf "  ${C_DIM}Where Cockpit stores content models and entries.${C_NC}\n"

  printf "${C_YELLOW}?${C_NC} Database ${C_DIM}(default: MongoDB)${C_NC} [Mongo/local] "
  local reply
  read -r reply
  case "${reply}" in
    l|L|local) DATABASE=local ;;
    *)         DATABASE=mongodb ;;
  esac
  ok "Database: ${DATABASE}"
}


# file in handlers/, and the whole surface of the app stays readable.

# -----------------------------------------------------------------------------
# Environment settings in one place, so no os.Getenv call is ever buried in a
# handler. Its own package because handlers, cms and main all read it.

# -----------------------------------------------------------------------------
# HANDLERS. One file per route, plus the shared pieces: the dependency struct
# and the Response helper every handler replies through.

# -----------------------------------------------------------------------------
# The cache-aside pattern, written once. Every cached endpoint calls HTML and
# passes a render function, so no handler repeats Get/Set/error handling.

# -----------------------------------------------------------------------------
# The only package that knows how to talk to Cockpit.

# -----------------------------------------------------------------------------
# Markup only, one component per file, rendered with the standard library's
# html/template and embedded with go:embed.
#
# The markup differs between the two styling modes on purpose: with Tailwind
# the components carry utility classes, without it they carry semantic class
# names styled by static/app.css. Neither mode leaves classes that do nothing.

# --- Tailwind flavour ---------------------------------------------------------

# --- plain CSS flavour --------------------------------------------------------

# -----------------------------------------------------------------------------
# Context files for AI assistants. MEMORY.md is the short entry point loaded
# first; ARCHITECTURE.md is the reference it points at.

# -----------------------------------------------------------------------------
