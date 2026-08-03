#!/usr/bin/env bash
#
# gosite stop [project]
#
# Stops a project's containers. Volumes, images and the shared infrastructure
# are left untouched - use `gosite remove` for a full teardown.
#

cmd_stop() {
  require_dependencies
  local dir; dir="$(resolve_project_dir "${1:-}")"

  # shellcheck source=/dev/null
  source "${dir}/${GOSITE_MARKER}"

  info "Stopping '${GOSITE_PROJECT}'"
  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" down
  ok "'${GOSITE_PROJECT}' stopped."
}
