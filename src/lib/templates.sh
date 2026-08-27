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
  # Project .env files receive the installation's real MinIO credentials (see
  # resolve_minio_credentials in helpers.sh). Resolved once per run; the first
  # call persists generated credentials into the infra directory.
  if [[ -z "${S3_KEY:-}" || -z "${S3_SECRET:-}" ]]; then
    resolve_minio_credentials
    S3_KEY="${MINIO_ROOT_USER}"
    S3_SECRET="${MINIO_ROOT_PASSWORD}"
  fi
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
    -e "s|__ADDONS__|${INSTALL_ADDONS}|g" \
    -e "s|__TLD__|${GOSITE_TLD}|g" \
    -e "s|__DATABASE__|${DATABASE:-mongodb}|g" \
    -e "s|__STORAGE_ADAPTER__|${STORAGE_ADAPTER:-s3}|g" \
    -e "s|__S3_KEY__|${S3_KEY}|g" \
    -e "s|__S3_SECRET__|${S3_SECRET}|g" \
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
  INSTALL_ADDONS="${GOSITE_ADDONS:-0}"
  DATABASE="${GOSITE_DATABASE:-mongodb}"
  STORAGE_ADAPTER="${STORAGE_ADAPTER:-s3}"
  # CMS_TOKEN/COCKPIT_SEC_KEY live in the project's .env - read them from
  # there so a re-render reproduces exactly what create wrote (config.php
  # bakes the sec-key fallback into the file). When .env is unavailable the
  # placeholder fallback keeps a render from clobbering secrets with blanks.
  CMS_TOKEN="$(_env_value "$1" COCKPIT_API_TOKEN)"
  COCKPIT_SEC_KEY="$(_env_value "$1" COCKPIT_SEC_KEY)"
  CMS_TOKEN="${CMS_TOKEN:-__CMS_TOKEN__}"
  COCKPIT_SEC_KEY="${COCKPIT_SEC_KEY:-__COCKPIT_SEC_KEY__}"
}

# Reads KEY= from a project .env (last assignment wins, matching how dotenv
# consumers treat repeats). Prints nothing when the file or key is absent.
_env_value() {
  local envfile="$1/.env" key="$2" line
  [[ -f "${envfile}" ]] || return 0
  line="$(grep -E "^${key}=" "${envfile}" 2>/dev/null | tail -1 || true)"
  printf '%s' "${line#"${key}="}"
}

# Built-in Cockpit addons that ship with every scaffolded project. They are
# real source files in src/addons/ (the single source of truth for all addons
# - optional Forms/Replica are copied from the same place), so updating gosite
# keeps every new scaffold on the latest version of every addon.
_write_builtin_addons() {
  local addons_src="${GOSITE_ROOT}/addons"
  local target="$1/cockpit/addons"

  for name in AssetsUpload ModelManager CloudStorage AssetPathFix CachePurge; do
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
  local names="$2" addons_dir="${1}/cockpit/addons"
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

# --- template tree rendering ---------------------------------------------------
# The single source of truth for project content: src/templates/ holds every
# generated file as a real file with its real extension (design D8). Rendering
# is copy + literal __PLACEHOLDER__ substitution afterwards - no eval, no
# envsubst; template content is inert by construction.

# Files the old write_if_changed path produced without a trailing newline
# (its $(cat) stripped it). The renderer reproduces those exact bytes so the
# tree generator stays byte-identical to the heredoc generator it replaced.
_template_is_noeol() {
  case "$1" in
    .air.toml|.dockerignore|deploy/Dockerfile|deploy/Dockerfile.dev|deploy/Dockerfile.cms) return 0 ;;
    *) return 1 ;;
  esac
}

_template_in_scope() {
  local rel="$1" scope="$2"
  [[ "${scope}" == "full" ]] && return 0
  # Scope is decided on the name the project will see, not the name in the
  # repository.
  rel="$(_template_target_name "${rel}")"
  case "${rel}" in
    docker-compose.yml|docker-compose.prod.yml|cockpit/config.php|.env|.env.example|.air.toml|.dockerignore) return 0 ;;
    deploy/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Copies one template file to its destination with the byte semantics of the
# generator it replaces: gosite.env becomes the runtime marker name, noeol
# files lose their trailing newline.
# Template files whose name in the repository is not the name they get in a
# project. Both are dotfiles, and src/templates/.gitignore is itself a template
# shipped to generated projects - so git applies it to THIS directory too and
# silently ignores anything matching it. A template literally named ".env" was
# therefore never committed and never reached a release, which broke both
# create and sync. Storing it under a name git cannot ignore is what stops that
# from happening again.
_template_target_name() {
  case "$1" in
    gosite.env) printf '%s' "${GOSITE_MARKER}" ;;
    dotenv)     printf '.env' ;;
    *)          printf '%s' "$1" ;;
  esac
}

_copy_template_file() {
  local src="$1" dest="$2" rel="$3"
  local d
  d="$(_template_target_name "${rel}")"
  mkdir -p "$(dirname "${dest}/${d}")"
  cp "${src}/${rel}" "${dest}/${d}"
  if _template_is_noeol "${d}"; then
    printf '%s' "$(cat "${dest}/${d}")" > "${dest}/${d}"
  fi
}

# render_template_tree <template-root> <dest> [scope]
#
# Renders the template tree into <dest>:
#   1. every base file (everything outside flavors/)
#   2. the styling flavor's files, overlaid (views + styles.css)
#   3. the flavor's MEMORY.md.part appended to MEMORY.md
#
# scope=sync restricts the copy to the files sync manages; create uses the
# default full scope. Placeholder substitution is NOT done here - callers run
# render_placeholders afterwards, exactly as the heredoc flow always did.
render_template_tree() {
  local src="$1" dest="$2" scope="${3:-full}"
  local flavor="plain"
  [[ "${TAILWIND:-0}" -eq 1 ]] && flavor="tailwind"

  mkdir -p "${dest}"

  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#./}"
    _template_in_scope "${rel}" "${scope}" || continue
    _copy_template_file "${src}" "${dest}" "${rel}"
  done < <(cd "${src}" && find . -type f ! -path './flavors/*' ! -path './addons/*' -print0)

  if [[ "${scope}" == "full" ]]; then
    while IFS= read -r -d '' f; do
      rel="${f#./}"
      [[ "${rel}" == *.part ]] && continue
      _copy_template_file "${src}/flavors/${flavor}" "${dest}" "${rel}"
    done < <(cd "${src}/flavors/${flavor}" 2>/dev/null && find . -type f -print0)

    if [[ -f "${src}/flavors/${flavor}/MEMORY.md.part" ]]; then
      cat "${src}/flavors/${flavor}/MEMORY.md.part" >> "${dest}/MEMORY.md"
    fi
  fi
}

# render_addon_overlay <template-root> <dest> <addon>
#
# Applies the application-side half of an optional addon: the Go package it
# brings, the file that wires it into the router, and its page templates for the
# current styling flavor.
#
# Addons are overlays rather than base template files so a project that did not
# ask for one never carries its code. The wiring is always a file of its own -
# never an edit to router.go - because projects edit that file by hand and sync
# preserves it; installing is therefore only ever adding files.
#
# Placeholder substitution is NOT done here; callers run render_placeholders on
# what this wrote, exactly like the rest of the tree.
#
# Prints every path it wrote, relative to <dest>, so callers can record them in
# the sync manifest.
render_addon_overlay() {
  local src="$1" dest="$2" addon="$3"
  local root="${src}/addons/${addon}"
  local flavor="plain"
  [[ "${TAILWIND:-0}" -eq 1 ]] && flavor="tailwind"

  [[ -d "${root}" ]] || return 0

  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#./}"
    _copy_template_file "${root}" "${dest}" "${rel}"
    printf '%s\n' "${rel}"
  done < <(cd "${root}" && find . -type f ! -path './flavors/*' -print0)

  while IFS= read -r -d '' f; do
    rel="${f#./}"
    _copy_template_file "${root}/flavors/${flavor}" "${dest}" "${rel}"
    printf '%s\n' "${rel}"
  done < <(cd "${root}/flavors/${flavor}" 2>/dev/null && find . -type f -print0)
}

# Reports what an addon's application half needs but the project does not have.
#
# gosite never rewrites internal/*.go: that is the project's own source, which
# sync preserves on purpose. An addon whose pages call into it can therefore
# only be installed where those seams already exist - otherwise the install
# succeeds and the project stops compiling, which is a worse outcome than
# refusing.
#
# Prints one "path<TAB>marker" line per unmet requirement; prints nothing and
# returns 0 when the project is ready.
addon_unmet_requirements() {
  local dir="$1" addon="$2"
  local lower req
  lower="$(printf '%s' "${addon}" | tr '[:upper:]' '[:lower:]')"
  req="${GOSITE_ROOT}/templates/addons/${lower}/REQUIRES"

  [[ -f "${req}" ]] || return 0

  local path marker
  while IFS=$'\t' read -r path marker; do
    [[ -n "${path}" ]] || continue
    case "${path}" in \#*) continue ;; esac
    [[ -n "${marker}" ]] || continue

    if [[ ! -f "${dir}/${path}" ]] || ! grep -qF "${marker}" "${dir}/${path}"; then
      printf '%s\t%s\n' "${path}" "${marker}"
    fi
  done < "${req}"
}

# Does gosite ship an application-side overlay for this Cockpit addon?
addon_has_overlay() {
  [[ -d "${GOSITE_ROOT}/templates/addons/$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ]]
}

# A rendered file must never keep a __PLACEHOLDER__ token: a template and the
# substitution list drifting apart is a bug, not a silent degradation.
assert_no_placeholders() {
  local dir="$1" f tok bad=0
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    while IFS= read -r tok; do
      err "Unresolved placeholder ${tok} in ${f}"
      bad=1
    done < <(grep -oE '__[A-Z][A-Z0-9_]*__' "${f}" | sort -u)
  done < <(grep -rIlE '__[A-Z][A-Z0-9_]*__' "${dir}" 2>/dev/null || true)
  [[ "${bad}" -eq 0 ]] || fatal "Rendering left __PLACEHOLDER__ tokens behind; the templates and the substitution list are out of sync."
}


# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# BUILD FILES. The Dockerfiles, .air.toml and .dockerignore that make the
# compose files buildable. Shared by create and sync so a synced project always
# has the files the re-rendered compose files reference (otherwise docker fails
# with "/deploy: no such file or directory" on old scaffolds).
# -----------------------------------------------------------------------------

# Writes a file only when its content changed. On an overwrite of an existing
# file the previous version is kept as <file>.gosite.bak, so a gosite sync
# never silently destroys a user-customized Dockerfile or .air.toml.


