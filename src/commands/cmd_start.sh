#!/usr/bin/env bash
#
# gosite start [project]
#
# Brings up a project's local stack: the Go app running under air (hot reload)
# plus its own Cockpit container, both attached to the shared network.
#

cmd_start() {
  require_dependencies

  local follow=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --logs|-f) follow=1; shift ;;
      *)         name="$1"; shift ;;
    esac
  done

  local dir; dir="$(resolve_project_dir "${name}")"

  # shellcheck source=/dev/null
  source "${dir}/${GOSITE_MARKER}"

  ensure_network
  container_running "${GOSITE_REDIS_HOST}" || warn "Redis is not running. Run 'gosite infra up' or the app will fail to boot."

  info "Starting '${GOSITE_PROJECT}' (air hot reload)"
  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" up -d --build

  ok "App -> http://localhost:${GOSITE_APP_PORT}"
  ok "CMS -> http://localhost:${GOSITE_CMS_PORT}"
  printf "${C_DIM}Edit any .go/.templ file and air rebuilds automatically. Logs: gosite start --logs${C_NC}\n"

  if [[ "${follow}" -eq 1 ]]; then
    compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" logs -f --tail=50
  fi
}
