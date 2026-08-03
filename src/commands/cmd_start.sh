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

  registry_register "${dir}"
  ensure_cockpit_storage "${dir}"
  ensure_network

  # Projects created before a certificate existed get one on first start.
  [[ -n "${GOSITE_APP_DOMAIN:-}" ]] && ensure_project_cert "${GOSITE_PROJECT}" >/dev/null 2>&1 || true

  container_running "${GOSITE_PROXY_HOST}" || warn "Proxy is not running; local domains will not resolve. Run 'gosite infra up'."
  container_running "${GOSITE_REDIS_HOST}" || warn "Redis is not running. Run 'gosite infra up' or the app will fail to boot."

  info "Starting '${GOSITE_PROJECT}' (air hot reload)"
  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" up -d --build

  if [[ -n "${GOSITE_APP_DOMAIN:-}" ]]; then
    ok "App -> https://${GOSITE_APP_DOMAIN}"
    ok "CMS -> https://${GOSITE_CMS_DOMAIN}"
    printf "${C_DIM}Also on http://localhost:%s and http://localhost:%s.${C_NC}\n" \
      "${GOSITE_APP_PORT}" "${GOSITE_CMS_PORT}"
  else
    ok "App -> http://localhost:${GOSITE_APP_PORT}"
    ok "CMS -> http://localhost:${GOSITE_CMS_PORT}"
  fi
  printf "${C_DIM}Edit any .go/.html file and air rebuilds automatically. Logs: gosite start --logs${C_NC}\n"

  if [[ "${follow}" -eq 1 ]]; then
    compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" logs -f --tail=50
  fi
}
