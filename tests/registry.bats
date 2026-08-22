#!/usr/bin/env bats
# Registry: the project index. Covers the invariants of design D4 -
# registration under lock, pure reads, explicit pruning, no silent rewrites.

setup() {
  load helpers
  _env_reset
}

@test "register records name and path" {
  local dir; dir="$(make_project alpha)"
  run registry_register "${dir}"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${GOSITE_REGISTRY}" | tr -d ' ')" -eq 1 ]
  grep -q "^alpha	${dir}$" "${GOSITE_REGISTRY}"
}

@test "register ignores directories without a marker" {
  mkdir -p "${GOSITE_TEST_WORKSPACE}/not-a-project"
  registry_register "${GOSITE_TEST_WORKSPACE}/not-a-project"
  [ ! -f "${GOSITE_REGISTRY}" ]
}

@test "re-register updates the path instead of duplicating" {
  local dir; dir="$(make_project alpha)"
  registry_register "${dir}"
  registry_register "${dir}"
  [ "$(wc -l < "${GOSITE_REGISTRY}" | tr -d ' ')" -eq 1 ]
}

@test "entries are a pure read: missing dirs become unavailable, file untouched" {
  local dir; dir="$(make_project alpha)"
  registry_register "${dir}"

  rm -rf "${dir}"
  local before
  before="$(cat "${GOSITE_REGISTRY}")"

  run registry_entries
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^alpha	${dir}	unavailable$"
  [ "$(cat "${GOSITE_REGISTRY}")" == "${before}" ]
}

@test "lookup resolves by name and stays empty for unknown names" {
  local dir; dir="$(make_project alpha)"
  registry_register "${dir}"

  [ "$(registry_lookup alpha)" == "${dir}" ]
  [ -z "$(registry_lookup nope)" ]
}

@test "forget removes only the named entry" {
  local a b
  a="$(make_project alpha)"
  b="$(make_project beta)"
  registry_register "${a}"
  registry_register "${b}"

  registry_forget alpha
  [ "$(wc -l < "${GOSITE_REGISTRY}" | tr -d ' ')" -eq 1 ]
  grep -q "^beta	${b}$" "${GOSITE_REGISTRY}"
}

@test "prune removes vanished entries and keeps the rest, under lock" {
  local a b
  a="$(make_project alpha)"
  b="$(make_project beta)"
  registry_register "${a}"
  registry_register "${b}"
  rm -rf "${a}"

  run registry_prune
  [ "$status" -eq 0 ]
  [ ! -e "${a}" ]
  [ "$(wc -l < "${GOSITE_REGISTRY}" | tr -d ' ')" -eq 1 ]
  grep -q "^beta	${b}$" "${GOSITE_REGISTRY}"
}

@test "prune on a fully healthy registry rewrites nothing" {
  local dir; dir="$(make_project alpha)"
  registry_register "${dir}"
  local before; before="$(cat "${GOSITE_REGISTRY}")"

  registry_prune
  [ "$(cat "${GOSITE_REGISTRY}")" == "${before}" ]
}

@test "a malformed line with extra columns never leaks into the path" {
  local dir; dir="$(make_project alpha)"
  registry_register "${dir}"
  printf 'ghost	%s	garbage here\n' "${GOSITE_TEST_WORKSPACE}/ghost" >> "${GOSITE_REGISTRY}"

  run registry_entries
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ghost	${GOSITE_TEST_WORKSPACE}/ghost	unavailable$"
}

@test "concurrent registrations all land in the registry" {
  local i dirs=()
  for i in 1 2 3 4 5 6 7 8; do
    dirs+=("$(make_project "conc${i}")")
  done
  for i in 1 2 3 4 5 6 7 8; do
    registry_register "${dirs[$(( i - 1 ))]}" &
  done
  wait

  [ "$(wc -l < "${GOSITE_REGISTRY}" | tr -d ' ')" -eq 8 ]
}
