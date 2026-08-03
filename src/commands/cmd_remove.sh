#!/usr/bin/env bash
#
# gosite remove <project> [--purge]
#
# Tears down a project's containers, volumes and images. The source directory
# is only deleted with --purge, and always behind an explicit confirmation.
#

cmd_remove() {
  require_dependencies

  local purge=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge=1; shift ;;
      *)       name="$1"; shift ;;
    esac
  done

  local dir; dir="$(resolve_project_dir "${name}")"
  # shellcheck source=/dev/null
  source "${dir}/${GOSITE_MARKER}"

  warn "This removes the containers, volumes and images of '${GOSITE_PROJECT}'."
  [[ "${purge}" -eq 1 ]] && warn "--purge will also DELETE the directory ${dir}"
  confirm "Continue?" || { info "Aborted."; return 0; }

  info "Removing containers and volumes for '${GOSITE_PROJECT}'"
  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" \
    down --volumes --remove-orphans --rmi local || warn "Compose teardown reported errors; continuing."
  ok "Stack removed."

  if [[ "${purge}" -eq 1 ]]; then
    # Cockpit writes storage as root, so the bind mount may need elevation.
    info "Deleting ${dir}"
    rm -rf "${dir}" 2>/dev/null || sudo rm -rf "${dir}"
    registry_forget "${GOSITE_PROJECT}"
    ok "Directory deleted."
  else
    printf "${C_DIM}Source kept at %s (pass --purge to delete it).${C_NC}\n" "${dir}"
  fi

  printf "${C_DIM}Shared infrastructure untouched. Use 'gosite infra down' to stop it.${C_NC}\n"
}
