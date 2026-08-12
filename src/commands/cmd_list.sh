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

  local found=0 name dir
  while IFS=$'\t' read -r name dir; do
    [[ -n "${name}" ]] || continue
    (
      # Subshell so one project's marker never leaks into the next.
      # shellcheck source=/dev/null
      source "${dir}/${GOSITE_MARKER}"

      local app_status cms_status
      app_status="$(_status_short "${GOSITE_PROJECT}-app")"
      cms_status="$(_status_short "${GOSITE_PROJECT}-cms")"

      printf "\n${C_BOLD}%s${C_NC}  %s %s\n" \
        "${GOSITE_PROJECT}" "${app_status}" "${cms_status}"
      printf "  ${C_DIM}Site: %s${C_NC}\n" "$(hyperlink "https://${GOSITE_APP_DOMAIN}" "https://${GOSITE_APP_DOMAIN}")"
      printf "  ${C_DIM}CMS:  %s${C_NC}\n" "$(hyperlink "https://${GOSITE_CMS_DOMAIN}" "https://${GOSITE_CMS_DOMAIN}")"
    )
    found=$(( found + 1 ))
  done < <(registry_entries)

  if [[ "${found}" -eq 0 ]]; then
    printf "\n${C_DIM}No projects found. Create one with 'gosite create <name>'.${C_NC}\n"
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

_status_short() {
  if container_running "$1"; then
    printf "${C_GREEN}●${C_NC}"
  elif container_exists "$1"; then
    printf "${C_YELLOW}●${C_NC}"
  else
    printf "${C_DIM}○${C_NC}"
  fi
}

cmd_infra_status_hint() {
  if container_running "${GOSITE_REDIS_HOST}" && container_running "${GOSITE_PROXY_HOST}"; then
    ok "Shared infrastructure is running."
  else
    warn "Shared infrastructure is down. Run 'gosite infra up'."
  fi
}
