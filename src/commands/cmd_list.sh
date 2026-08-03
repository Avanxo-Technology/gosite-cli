#!/usr/bin/env bash
#
# gosite list
#
# Lists the gosite projects found under the current directory (or under
# GOSITE_WORKSPACE) with their ports and container status.
#

cmd_list() {
  require_dependencies

  local root="${GOSITE_WORKSPACE:-${PWD}}"
  info "Projects under ${root}"

  printf "\n${C_BOLD}%-22s %-8s %-8s %-12s %-12s${C_NC}\n" "PROJECT" "APP" "CMS" "APP STATUS" "CMS STATUS"
  printf "%s\n" "--------------------------------------------------------------------"

  local found=0 marker dir
  while IFS= read -r marker; do
    dir="$(dirname "${marker}")"
    (
      # Subshell so one project's marker never leaks into the next.
      # shellcheck source=/dev/null
      source "${marker}"
      local app_status cms_status
      app_status="$(_status_of "${GOSITE_PROJECT}-app")"
      cms_status="$(_status_of "${GOSITE_PROJECT}-cms")"
      printf "%-22s %-8s %-8s %-12s %-12s\n" \
        "${GOSITE_PROJECT}" "${GOSITE_APP_PORT}" "${GOSITE_CMS_PORT}" "${app_status}" "${cms_status}"
    )
    found=$(( found + 1 ))
  done < <(find "${root}" -maxdepth 3 -name "${GOSITE_MARKER}" -type f 2>/dev/null | sort)

  if [[ "${found}" -eq 0 ]]; then
    printf "${C_DIM}No projects found. Create one with 'gosite create <name>'.${C_NC}\n"
    return 0
  fi

  printf "\n"
  cmd_infra_status_hint
}

_status_of() {
  if container_running "$1"; then
    printf "${C_GREEN}running${C_NC}"
  elif container_exists "$1"; then
    printf "${C_YELLOW}stopped${C_NC}"
  else
    printf "${C_DIM}-${C_NC}"
  fi
}

cmd_infra_status_hint() {
  if container_running "${GOSITE_REDIS_HOST}" && container_running "${GOSITE_PG_HOST}"; then
    ok "Shared infrastructure is running."
  else
    warn "Shared infrastructure is down. Run 'gosite infra up'."
  fi
}
