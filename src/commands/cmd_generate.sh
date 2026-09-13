#!/usr/bin/env bash
#
# gosite generate - rewrite a thin site's generated files from gosite.yml.
#
# Not a return of 'gosite sync'. sync was removed because it decided, file by
# file, whether gosite still owned something - and got it silently wrong on
# real projects. generate never has to decide: it only runs on thin sites,
# where the generated files (compose, Dockerfiles, cockpit/config.core.php) are
# gosite's by construction and every local change has its own override file.
# A generated file that lost its header was edited anyway, and is reported and
# left alone rather than overwritten.

# shellcheck source=../lib/templates.sh
source "${GOSITE_ROOT}/lib/templates.sh"
# shellcheck source=../lib/siteyml.sh
source "${GOSITE_ROOT}/lib/siteyml.sh"
# shellcheck source=../lib/thin.sh
source "${GOSITE_ROOT}/lib/thin.sh"

cmd_generate() {
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        printf 'Usage: gosite generate [project]\n\n'
        printf 'Rewrites the compose files, Dockerfiles and cockpit/config.core.php of a\n'
        printf 'thin site from its gosite.yml. Never touches site/, theme/, static/,\n'
        printf 'docker-compose.override.yml or cockpit/config.local.php.\n'
        return 0 ;;
      -*) fatal "Unknown flag for 'generate': $1" ;;
      *)  name="$1"; shift ;;
    esac
  done

  local dir; dir="$(resolve_project_dir "${name}")"
  # Checked here, not only inside thin_generate: that runs in a process
  # substitution below, where fatal would end the subshell and not the command.
  thin_is_project "${dir}" || fatal "$(basename "${dir}") has no gosite.yml: 'gosite generate' only manages thin sites. Upgrade other projects with MIGRATIONS.md."
  info "Generating $(basename "${dir}") from gosite.yml"

  local rel
  while IFS= read -r rel; do
    ok "Wrote ${rel}"
  done < <(thin_generate "${dir}")

  # thin_generate ran in a subshell above, so count the skipped files here.
  local f skipped=0
  while IFS= read -r -d '' f; do
    f="${f#./}"
    if [[ -f "${dir}/${f}" ]] && ! head -n 3 "${dir}/${f}" | grep -q "${THIN_GENERATED_MARK}"; then
      warn "Left ${f} alone: it no longer carries the '${THIN_GENERATED_MARK}' header. Move the change to docker-compose.override.yml or cockpit/config.local.php, delete the file, and run 'gosite generate' again."
      skipped=$((skipped + 1))
    fi
  done < <(cd "$(thin_template_root)/generated" && find . -type f -print0)

  [[ "${skipped}" -eq 0 ]] || return 1
  printf '  Rebuild for the changes to take effect: gosite restart %s --build\n' "$(basename "${dir}")"
}
