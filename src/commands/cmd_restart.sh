#!/usr/bin/env bash
#
# gosite restart [project] [--build]
#
# Recreates a project's containers. air already reloads Go and template
# changes, so this is for what it cannot pick up: .env edits, compose or
# Dockerfile changes, or a container that has wedged.
#

cmd_restart() {
  require_dependencies

  local build=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build) build=1; shift ;;
      -*)      fatal "Unknown flag for 'restart': $1 (expected --build)" ;;
      *)       name="$1"; shift ;;
    esac
  done

  local dir; dir="$(resolve_project_dir "${name}")"
  # shellcheck source=/dev/null
  source "${dir}/${GOSITE_MARKER}"

  ensure_cockpit_storage "${dir}"
  ensure_network
  container_running "${GOSITE_PROXY_HOST}" || warn "Proxy is not running; local domains will not resolve. Run 'gosite infra up'."

  info "Restarting '${GOSITE_PROJECT}'"
  local args=(up -d --force-recreate)
  [[ "${build}" -eq 1 ]] && args+=(--build)
  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" "${args[@]}"

  if [[ -n "${GOSITE_APP_DOMAIN:-}" ]]; then
    ok "App -> https://${GOSITE_APP_DOMAIN}"
    ok "CMS -> https://${GOSITE_CMS_DOMAIN}"
  else
    ok "App -> http://localhost:${GOSITE_APP_PORT}"
  fi
  printf "${C_DIM}Cockpit needs a few seconds to pass its health check before the proxy routes to it.${C_NC}\n"
}
