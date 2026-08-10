#!/usr/bin/env bash
#
# gosite open <project>  Open a project directory in Finder (macOS)
#

cmd_open() {
  local dir; dir="$(resolve_project_dir "${1:-}")"
  open "${dir}"
  ok "Opened ${dir} in Finder"
}