#!/usr/bin/env bats
# The repository's agent instruction files: AGENTS.md is the single source,
# CLAUDE.md imports it, and stays within its line budget.

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
}

@test "AGENTS.md exists and MEMORY.md is gone" {
  [ -f "${REPO}/AGENTS.md" ]
  [ ! -e "${REPO}/MEMORY.md" ]
}

@test "AGENTS.md stays under 120 lines" {
  lines=$(wc -l < "${REPO}/AGENTS.md")
  [ "${lines}" -lt 120 ]
}

@test "AGENTS.md names the paths that must not be searched" {
  grep -qF 'services/medusa/node_modules' "${REPO}/AGENTS.md"
  grep -qF 'CHANGELOG.md' "${REPO}/AGENTS.md"
}

@test "AGENTS.md has no per-note knowledge index" {
  run grep -E '^\| cockpit-' "${REPO}/AGENTS.md"
  [ "${status}" -ne 0 ]
}

@test "CLAUDE.md imports AGENTS.md on its first line" {
  [ "$(head -n 1 "${REPO}/CLAUDE.md")" = "@AGENTS.md" ]
}
