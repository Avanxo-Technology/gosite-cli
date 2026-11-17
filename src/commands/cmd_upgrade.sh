#!/usr/bin/env bash
#
# gosite upgrade [name] [--force] [--no-images]
#
# Takes a thin site to this CLI's version, with every local step of the
# upgrade: core: in gosite.yml, the core module in go.mod, the generated files,
# a build with tests, the production images, and the MIGRATIONS.md sections of
# the versions crossed. It runs no git command and deploys nothing.
#
# The order matters. The new generated files are first rendered into a
# temporary copy and compared with the site's: `gosite generate` deletes a
# variable a site added by hand to a generated compose file, so the command
# stops there, before it changes anything, unless --force is given.

# cmd_generate.sh brings templates.sh, siteyml.sh and thin.sh. Sourcing those
# here as well would fail: thin.sh defines readonly variables.
# shellcheck source=cmd_generate.sh
source "${GOSITE_ROOT}/commands/cmd_generate.sh"
# shellcheck source=../lib/versions.sh
source "${GOSITE_ROOT}/lib/versions.sh"

readonly UPGRADE_CORE_MODULE="github.com/${THIN_REPO}/core"
readonly UPGRADE_IMAGE_PREFIX="gosite-upgrade"

# Removed on every exit: the temporary copy (it holds a copy of .env) and the
# images the command built. The exit status is kept: under bash 3.2 the
# trap's own status would replace it, and a failure would exit 0.
UPGRADE_TMP=""
UPGRADE_IMAGES=()
_upgrade_cleanup() {
  local status=$?
  [[ -n "${UPGRADE_TMP}" ]] && rm -rf "${UPGRADE_TMP}"
  local image
  for image in "${UPGRADE_IMAGES[@]+"${UPGRADE_IMAGES[@]}"}"; do
    docker rmi -f "${image}" >/dev/null 2>&1 || true
  done
  return "${status}"
}

cmd_upgrade() {
  local name="" force=0 images=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)     force=1; shift ;;
      --no-images) images=0; shift ;;
      -h|--help)
        cat <<USAGE
Usage: gosite upgrade [project] [--force] [--no-images]

Takes a thin site to this gosite version (${GOSITE_VERSION}). To go further,
run 'gosite update' first. Runs no git command and deploys nothing.

Steps: check the generated files in a temporary copy, set core: in gosite.yml,
go get the core module, go mod tidy, gosite generate, go build/vet/test, build
the production images, print the MIGRATIONS.md sections of the versions crossed.

Flags:
  --force      Upgrade even if a compose variable the site added would be lost
  --no-images  Do not build and check the production images
  -h, --help   Show this help
USAGE
        return 0 ;;
      -*) fatal "Unknown flag for 'upgrade': $1 (expected --force or --no-images)" ;;
      *)  name="$1"; shift ;;
    esac
  done

  local dir; dir="$(resolve_project_dir "${name}")"
  local site; site="$(basename "${dir}")"
  thin_is_project "${dir}" \
    || fatal "${site} has no gosite.yml: 'gosite upgrade' only upgrades thin sites. Upgrade other projects with MIGRATIONS.md."

  local old new="${GOSITE_VERSION}"
  old="$(siteyml_get "${dir}/gosite.yml" core)"
  [[ -n "${old}" ]] || fatal "${dir}/gosite.yml has no 'core:' line."
  if [[ "${old}" == "${new}" ]]; then
    ok "${site} is already at ${new}. Nothing to do."
    return 0
  fi
  if _versions_newer "${old}" "${new}"; then
    fatal "${site} is at ${old}, newer than this gosite (${new}). Run 'gosite update' first."
  fi

  command -v go >/dev/null 2>&1 || fatal "Go is not installed; it is needed to update go.mod and test the site."
  if [[ "${images}" -eq 1 ]]; then
    docker_running || fatal "Docker is not running; it is needed to build the images. Start it, or use --no-images."
  fi

  trap _upgrade_cleanup EXIT
  info "Upgrading ${site} ${old} -> ${new}"

  # --- 1. check in a temporary copy ------------------------------------------
  # Created here, not inside the $( ) below: a variable set in that subshell
  # would never reach the EXIT trap, and the copy holds .env.
  UPGRADE_TMP="$(mktemp -d)"
  local lost
  lost="$(_upgrade_check_copy "${dir}" "${new}" "${UPGRADE_TMP}/site")" || fatal "Could not render ${new} in a temporary copy; ${site} is unchanged."
  if [[ -n "${lost}" ]]; then
    _upgrade_report_lost "${lost}"
    if [[ "${force}" -eq 0 ]]; then
      err "Stopped before changing anything: ${site} is unchanged. Use --force to upgrade anyway."
      return 1
    fi
    warn "Continuing because of --force: these variables will be lost."
  else
    ok "Checked in a temporary copy: no compose variable would be lost"
  fi

  # --- 2. version, module, generated files -----------------------------------
  thin_set_core_version "${dir}/gosite.yml" "${new}" || fatal "Could not set core: in ${dir}/gosite.yml."
  ok "core: ${new} in gosite.yml"
  _upgrade_go_get "${dir}" "${new}" || _upgrade_fail "go get ${UPGRADE_CORE_MODULE}@v${new}"
  (cd "${dir}" && go mod tidy) || _upgrade_fail "go mod tidy"
  ok "go.mod requires the core at v${new}"
  cmd_generate "${dir}" || _upgrade_fail "gosite generate"

  # --- 3. build and test ------------------------------------------------------
  local step
  for step in build vet test; do
    info "go ${step} ./..."
    (cd "${dir}" && go "${step}" ./...) || _upgrade_fail "go ${step}"
  done
  ok "go build, go vet, go test"

  # --- 4. production images ---------------------------------------------------
  local image_note="not checked (--no-images)"
  if [[ "${images}" -eq 1 ]]; then
    # Registered here for the EXIT trap; the build runs in the $( ) below.
    UPGRADE_IMAGES=("${UPGRADE_IMAGE_PREFIX}/${site}-app:${new}" "${UPGRADE_IMAGE_PREFIX}/${site}-cms:${new}")
    image_note="$(_upgrade_images "${dir}" "${site}" "${new}")" || _upgrade_fail "production images"
  fi

  # --- 5. manual steps --------------------------------------------------------
  _upgrade_migrations "${old}" "${new}"

  # --- summary ------------------------------------------------------------------
  printf '\n'
  ok "${site} upgraded ${old} -> ${new}"
  printf '      images:   %s\n' "${image_note}"
  if [[ -n "${lost}" ]]; then
    printf '      lost:     %s\n' "$(cut -f2 <<< "${lost}" | sort -u | tr '\n' ' ')"
  fi
  printf '      next:     read the manual steps above, review git diff (also the values in the compose files), commit\n'
  printf '      Nothing was committed or deployed.\n'
}

# _upgrade_check_copy <dir> <version> <copy> -> renders the generated files of
# <version> into <copy>, which holds only what generate reads, and prints the
# variables that would be lost ("<file>\t<name>").
_upgrade_check_copy() {
  local dir="$1" version="$2" copy="$3" rel
  mkdir -p "${copy}"
  cp "${dir}/gosite.yml" "${copy}/"
  [[ -f "${dir}/.env" ]] && cp "${dir}/.env" "${copy}/"
  # The current generated files, so a file without the generated header is
  # skipped in the copy exactly as generate skips it in the site.
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    if [[ -f "${dir}/${rel}" ]]; then
      mkdir -p "$(dirname "${copy}/${rel}")"
      cp "${dir}/${rel}" "${copy}/${rel}"
    fi
  done < <(cd "$(thin_template_root)/generated" && find . -type f -print0)

  thin_set_core_version "${copy}/gosite.yml" "${version}" || return 1
  # A subshell: thin_generate exports render variables and may call fatal.
  ( thin_generate "${copy}" >/dev/null ) || return 1
  thin_lost_compose_vars "${dir}" "${copy}"
}

_upgrade_report_lost() {
  local file name
  err "gosite generate would delete variables this site added to generated files:"
  while IFS=$'\t' read -r file name; do
    printf '      %-26s %s\n' "${file}" "${name}"
  done <<< "$1"
  printf '      Variables the app reads: list them under app_env: in gosite.yml.\n'
  printf '      Local services or settings: move them to docker-compose.override.yml.\n'
  printf '      Anything else belongs in gosite: open an issue.\n'
}

# _upgrade_go_get <dir> <version>. A tag pushed seconds ago can be unknown to
# the module proxy for a while, so one retry goes straight to the source.
_upgrade_go_get() {
  local dir="$1" version="$2"
  (cd "${dir}" && go get "${UPGRADE_CORE_MODULE}@v${version}") && return 0
  warn "go get failed through the module proxy; retrying once with GOPROXY=direct"
  (cd "${dir}" && GOPROXY=direct go get "${UPGRADE_CORE_MODULE}@v${version}")
}

# Stops after the site was changed. The files stay as they are: the command
# runs no git, so 'git diff' is how the user sees and reverts them.
_upgrade_fail() {
  err "Upgrade stopped at: $1"
  err "The site's files are already changed up to that step. Fix it and run the step again, or revert with git."
  exit 1
}

# _upgrade_images <dir> <site> <version> -> builds both production images the
# way production builds them, checks the CMS one, prints a one-line note.
_upgrade_images() {
  local dir="$1" site="$2" version="$3"
  local app="${UPGRADE_IMAGE_PREFIX}/${site}-app:${version}"
  local cms="${UPGRADE_IMAGE_PREFIX}/${site}-cms:${version}"
  local addons_context="https://github.com/${THIN_REPO}.git#core/v${version}:src/addons"

  info "Building the production app image" >&2
  docker build -q -f "${dir}/deploy/Dockerfile" -t "${app}" "${dir}" >&2 || return 1
  info "Building the production CMS image (addons from core/v${version})" >&2
  docker build -q -f "${dir}/deploy/Dockerfile.cms" \
    --build-context "gosite-addons=${addons_context}" -t "${cms}" "${dir}" >&2 || return 1

  local php addon missing=()
  php="$(docker run --rm --entrypoint php "${cms}" -r 'echo PHP_VERSION;' 2>/dev/null)" || php="unknown"
  while IFS= read -r addon; do
    [[ -n "${addon}" ]] || continue
    docker run --rm --entrypoint test "${cms}" -d "/var/www/html/addons/${addon}" || missing+=("${addon}")
  done < <(siteyml_list "${dir}/gosite.yml" addons)
  if [[ "${#missing[@]}" -gt 0 ]]; then
    err "The CMS image has no addon folder for: ${missing[*]}" >&2
    return 1
  fi
  ok "Production images built; CMS on PHP ${php}" >&2
  printf 'app and CMS built and removed; CMS PHP %s' "${php}"
}

# _upgrade_migrations <old> <new> -> prints the MIGRATIONS.md sections of every
# version after <old> up to <new>, read at the new version's tag.
_upgrade_migrations() {
  local old="$1" new="$2"
  local raw="https://raw.githubusercontent.com/${THIN_REPO}/v${new}/MIGRATIONS.md"
  local page="https://github.com/${THIN_REPO}/blob/v${new}/MIGRATIONS.md"
  local text
  if ! text="$(curl -fsSL --max-time 20 "${raw}" 2>/dev/null)" || [[ -z "${text}" ]]; then
    warn "Could not fetch MIGRATIONS.md. Read the sections after ${old} up to ${new}: ${page}"
    return 0
  fi
  local sections
  sections="$(upgrade_migration_sections "${old}" "${new}" <<< "${text}")"
  if [[ -z "${sections}" ]]; then
    ok "MIGRATIONS.md has no section for the versions ${old} -> ${new}"
    return 0
  fi
  info "Manual steps for the versions crossed (MIGRATIONS.md, ${page}):"
  printf '%s\n' "${sections}"
}

# upgrade_migration_sections <old> <new> < MIGRATIONS.md -> the "## → X.Y.Z"
# sections with old < X.Y.Z <= new, in file order. Subsections stay with the
# section above them.
upgrade_migration_sections() {
  local old="$1" new="$2" line version keep=0
  local heading='^## ' versioned='^## → ([0-9]+\.[0-9]+\.[0-9]+)'
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ${heading} ]]; then
      keep=0
      if [[ "${line}" =~ ${versioned} ]]; then
        version="${BASH_REMATCH[1]}"
        if _versions_newer "${version}" "${old}" && ! _versions_newer "${version}" "${new}"; then
          keep=1
        fi
      fi
    fi
    [[ "${keep}" -eq 1 ]] && printf '%s\n' "${line}"
  done
  return 0
}
