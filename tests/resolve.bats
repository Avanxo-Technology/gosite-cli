#!/usr/bin/env bats
# Project resolution: by explicit path/marker, by registry name, by cwd
# fallback - and a clear failure when nothing matches.

setup() {
  load helpers
  _env_reset
  # helpers.bash sources helpers.sh; resolution also needs the registry
  # helpers, which are already in scope there.
}

@test "resolves a project by registered name" {
  local dir; dir="$(make_project alpha)"
  registry_register "${dir}"

  [ "$(resolve_project_dir alpha)" == "${dir}" ]
}

@test "resolves the cwd when it holds a marker" {
  local dir; dir="$(make_project alpha)"
  run bash -c "cd '${dir}' && GOSITE_REGISTRY='$(printf '%q' "${GOSITE_REGISTRY}")' GOSITE_WORKSPACE='$(printf '%q' "${GOSITE_WORKSPACE}")' bash -c '
    source \"${BATS_TEST_DIRNAME}/../src/lib/helpers.sh\" 2>/dev/null || source \"$(printf '%q' "${BATS_TEST_DIRNAME}")/../src/lib/helpers.sh\"
    resolve_project_dir \"\"
  '"
  [ "$status" -eq 0 ]
  [ "$output" == "${dir}" ]
}

@test "an unregistered name inside the workspace still resolves" {
  local dir; dir="$(make_project alpha)"
  [ "$(resolve_project_dir alpha)" == "${dir}" ]
}

@test "an explicit existing directory path resolves directly" {
  local dir; dir="$(make_project alpha)"
  [ "$(resolve_project_dir "${dir}")" == "${dir}" ]
}

@test "unknown name fails with a helpful error" {
  run resolve_project_dir "does-not-exist-anywhere"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "not found\|no project\|unknown"
}
