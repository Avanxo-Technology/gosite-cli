#!/usr/bin/env bash
#
# gosite list
#
# Lists the gosite projects found under the current directory (or under
# GOSITE_WORKSPACE) with their ports and container status.
#

cmd_list() {
  require_dependencies

  # Pick up any project below the cwd that is not indexed yet (a fresh clone,
  # for example), then list everything from the registry.
  local marker
  while IFS= read -r marker; do
    registry_register "$(cd "$(dirname "${marker}")" && pwd)"
  done < <(find "${GOSITE_WORKSPACE}" "${PWD}" -maxdepth 3 -name "${GOSITE_MARKER}" -type f 2>/dev/null)

  info "Registered projects"

  printf "\n${C_BOLD}%-20s %-7s %-7s %-11s %-11s %-30s %s${C_NC}\n" \
    "PROJECT" "APP" "CMS" "APP" "CMS" "URLS" "PATH"
  printf "%s\n" "-------------------------------------------------------------------------------------------"

  local found=0 name dir
  while IFS=$'\t' read -r name dir; do
    [[ -n "${name}" ]] || continue
    (
      # Subshell so one project's marker never leaks into the next.
      # shellcheck source=/dev/null
      source "${dir}/${GOSITE_MARKER}"
      printf "%-20s %-7s %-7s %-11s %-11s %-30s %s\n" \
        "${GOSITE_PROJECT}" "${GOSITE_APP_PORT}" "${GOSITE_CMS_PORT}" \
        "$(_status_of "${GOSITE_PROJECT}-app")" "$(_status_of "${GOSITE_PROJECT}-cms")" \
        "https://${GOSITE_APP_DOMAIN} https://${GOSITE_CMS_DOMAIN}" \
        "$(_short_path "${dir}")"
    )
    found=$(( found + 1 ))
  done < <(registry_entries)

  if [[ "${found}" -eq 0 ]]; then
    printf "${C_DIM}No projects found. Create one with 'gosite create <name>'.${C_NC}\n"
    return 0
  fi

  printf "\n"
  cmd_infra_status_hint
}

# Keeps the PATH column readable by collapsing $HOME to ~.
_short_path() {
  case "$1" in
    "${HOME}"/*) printf '~/%s' "${1#"${HOME}"/}" ;;
    *)           printf '%s' "$1" ;;
  esac
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
  if container_running "${GOSITE_REDIS_HOST}" && container_running "${GOSITE_PROXY_HOST}"; then
    ok "Shared infrastructure is running."
  else
    warn "Shared infrastructure is down. Run 'gosite infra up'."
  fi
}
