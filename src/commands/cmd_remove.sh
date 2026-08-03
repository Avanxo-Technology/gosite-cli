#!/usr/bin/env bash
#
# gosite remove <project> [--keep-source]
#
# Removes a project completely: containers, volumes, local images, its TLS
# certificate, its registry entry and its directory. `remove` is expected to
# remove, so deleting the source is the default; --keep-source opts out.
#
# Destructive, so it always confirms unless -y/--yes was passed.
#

cmd_remove() {
  require_dependencies

  local keep_source=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-source) keep_source=1; shift ;;
      # Kept so older muscle memory and scripts do not break: deleting the
      # source is now the default, so --purge is simply a no-op.
      --purge)       shift ;;
      -*)            fatal "Unknown flag for 'remove': $1 (expected --keep-source)" ;;
      *)             name="$1"; shift ;;
    esac
  done

  local dir; dir="$(resolve_project_dir "${name}")"
  # shellcheck source=/dev/null
  source "${dir}/${GOSITE_MARKER}"

  warn "About to remove '${GOSITE_PROJECT}':"
  printf "    containers, volumes and local images\n"
  printf "    TLS certificate for %s\n" "${GOSITE_APP_DOMAIN:-${GOSITE_PROJECT}}"
  if [[ "${keep_source}" -eq 1 ]]; then
    printf "    %s(source kept: %s)%s\n" "${C_DIM}" "${dir}" "${C_NC}"
  else
    printf "    %sthe directory %s and everything in it%s\n" "${C_RED}" "${dir}" "${C_NC}"
  fi
  confirm "Continue?" || { info "Aborted."; return 0; }

  info "Removing containers, volumes and images for '${GOSITE_PROJECT}'"
  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" \
    down --volumes --remove-orphans --rmi local || warn "Compose teardown reported errors; continuing."
  ok "Stack removed."

  remove_project_cert "${GOSITE_PROJECT}"

  if [[ "${keep_source}" -eq 1 ]]; then
    printf "${C_DIM}Source kept at %s; still listed by 'gosite list'.${C_NC}\n" "${dir}"
  else
    # Cockpit writes its storage as root, so the bind mount may need elevation.
    info "Deleting ${dir}"
    rm -rf "${dir}" 2>/dev/null || sudo rm -rf "${dir}"
    registry_forget "${GOSITE_PROJECT}"
    ok "Directory deleted."
  fi

  printf "${C_DIM}Shared infrastructure untouched. Use 'gosite infra down' to stop it.${C_NC}\n"
}
