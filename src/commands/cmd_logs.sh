#!/usr/bin/env bash
#
# gosite logs [project] [app|cms] [-n N] [--no-follow]
#
# Tails a project's container logs. Follows by default, since the common case
# is watching air rebuild while editing.
#

cmd_logs() {
  require_dependencies

  local name="" service="" tail_n="100" follow=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      app|cms)      service="$1"; shift ;;
      -n|--tail)    tail_n="${2:-100}"; shift 2 ;;
      --no-follow)  follow=0; shift ;;
      -f|--follow)  follow=1; shift ;;
      -*)           fatal "Unknown flag for 'logs': $1 (expected -n N, --no-follow, app|cms)" ;;
      *)            name="$1"; shift ;;
    esac
  done

  local dir; dir="$(resolve_project_dir "${name}")"
  # shellcheck source=/dev/null
  source "${dir}/${GOSITE_MARKER}"

  local args=(logs "--tail=${tail_n}")
  [[ "${follow}" -eq 1 ]] && args+=(--follow)
  [[ -n "${service}" ]] && args+=("${service}")

  if [[ -n "${service}" ]]; then
    info "Logs for '${GOSITE_PROJECT}' (${service})"
  else
    info "Logs for '${GOSITE_PROJECT}' (app + cms)"
  fi
  [[ "${follow}" -eq 1 ]] && printf "${C_DIM}Ctrl-C to stop following.${C_NC}\n"

  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" \
    --project-directory "${dir}" "${args[@]}"
}
