#!/usr/bin/env bats
# Agent context files of a generated site, produced by the template library
# (src/lib/templates.sh, src/lib/thin.sh) without Docker or the network: the
# thin scaffold is rendered by thin_scaffold, the legacy tree by
# render_template_tree.
# cmd_create.sh itself is not sourced, because it starts the infra.

setup() {
  load helpers
  _env_reset
  export GOSITE_ROOT="${BATS_TEST_DIRNAME}/../src"
  # shellcheck source=../src/lib/siteyml.sh
  source "${GOSITE_ROOT}/lib/siteyml.sh"
  # shellcheck source=../src/lib/templates.sh
  source "${GOSITE_ROOT}/lib/templates.sh"
  # shellcheck source=../src/lib/thin.sh
  source "${GOSITE_ROOT}/lib/thin.sh"

  # Render variables, as set_fixture_vars in tests/template_fixture.sh does.
  # shellcheck disable=SC2034
  PROJECT_NAME="demo"
  PROJECT_MODULE="github.com/example/demo"
  APP_PORT="8100"
  CMS_PORT="8101"
  APP_DOMAIN="demo.test"
  CMS_DOMAIN="cms.demo.test"
  CMS_TOKEN="demo-token"
  COCKPIT_SEC_KEY="demo-sec-key"
  INSTALL_ADDONS=0
  DATABASE="mongodb"
  STORAGE_ADAPTER="s3"
  TAILWIND=0
  S3_KEY="demo-key"
  S3_SECRET="demo-secret"
  GOSITE_NETWORK="gosite-network"
  GOSITE_REDIS_HOST="gosite-redis"
  GOSITE_MONGO_HOST="gosite-mongo"
  GOSITE_MONGO_PORT="27017"
  GOSITE_MINIO_HOST="gosite-minio"
  GOSITE_TLD="test"
  THIN_CORE_VERSION="0.57.0"
  export PROJECT_NAME PROJECT_MODULE APP_PORT CMS_PORT APP_DOMAIN CMS_DOMAIN \
    CMS_TOKEN COCKPIT_SEC_KEY INSTALL_ADDONS DATABASE STORAGE_ADAPTER TAILWIND \
    S3_KEY S3_SECRET GOSITE_NETWORK GOSITE_REDIS_HOST GOSITE_MONGO_HOST \
    GOSITE_MONGO_PORT GOSITE_MINIO_HOST GOSITE_TLD THIN_CORE_VERSION
}

# Renders a thin site the way _create_thin does, minus the parts that need
# Docker (compose generation, certificates, the registry).
render_thin() {
  local dir="$1"
  mkdir -p "${dir}"
  thin_scaffold "${dir}"
}

# Renders a legacy site the way cmd_create.sh does, minus the Go-side steps.
render_legacy() {
  local dir="$1"
  mkdir -p "${dir}"
  render_template_tree "${GOSITE_ROOT}/templates" "${dir}" full
  local f
  while IFS= read -r f; do render_placeholders "${f}"; done < <(find "${dir}" -type f)
}

assert_context_files() {
  local dir="$1"
  [ -f "${dir}/AGENTS.md" ]
  [ -f "${dir}/CLAUDE.md" ]
  [ "$(head -n 1 "${dir}/CLAUDE.md")" = "@AGENTS.md" ]
  [ ! -e "${dir}/MEMORY.md" ]
  [ ! -e "${dir}/.claude/skills" ]
  [ ! -e "${dir}/.opencode/skills" ]
}

@test "thin site: AGENTS.md and CLAUDE.md; no MEMORY.md, no skills" {
  render_thin "${GOSITE_TEST_ROOT}/thin"
  assert_context_files "${GOSITE_TEST_ROOT}/thin"
}

@test "thin site: AGENTS.md is under 80 lines and has no placeholder left" {
  render_thin "${GOSITE_TEST_ROOT}/thin"
  lines=$(wc -l < "${GOSITE_TEST_ROOT}/thin/AGENTS.md")
  [ "${lines}" -lt 80 ]
  run grep -E '__[A-Z][A-Z0-9_]*__' "${GOSITE_TEST_ROOT}/thin/AGENTS.md"
  [ "${status}" -ne 0 ]
  grep -q '^# demo$' "${GOSITE_TEST_ROOT}/thin/AGENTS.md"
}

@test "thin site: AGENTS.md points to gosite docs for Medusa" {
  render_thin "${GOSITE_TEST_ROOT}/thin"
  grep -q 'gosite docs medusa-admin-api' "${GOSITE_TEST_ROOT}/thin/AGENTS.md"
}

@test "legacy site: AGENTS.md and CLAUDE.md; no MEMORY.md, no skills" {
  render_legacy "${GOSITE_TEST_ROOT}/legacy"
  assert_context_files "${GOSITE_TEST_ROOT}/legacy"
  [ -f "${GOSITE_TEST_ROOT}/legacy/ARCHITECTURE.md" ]
}

@test "legacy site: AGENTS.md has the flavor part and no placeholder left" {
  render_legacy "${GOSITE_TEST_ROOT}/legacy"
  grep -q '^## Styling' "${GOSITE_TEST_ROOT}/legacy/AGENTS.md"
  run grep -E '__[A-Z][A-Z0-9_]*__' "${GOSITE_TEST_ROOT}/legacy/AGENTS.md"
  [ "${status}" -ne 0 ]
}

@test "legacy site: AGENTS.md is under 80 lines with the plain flavor" {
  render_legacy "${GOSITE_TEST_ROOT}/legacy"
  lines=$(wc -l < "${GOSITE_TEST_ROOT}/legacy/AGENTS.md")
  [ "${lines}" -lt 80 ]
}

@test "legacy tailwind flavor appends its own part to AGENTS.md" {
  TAILWIND=1
  export TAILWIND
  render_legacy "${GOSITE_TEST_ROOT}/legacy-tw"
  grep -q 'Tailwind CSS loaded from CDN' "${GOSITE_TEST_ROOT}/legacy-tw/AGENTS.md"
  [ ! -e "${GOSITE_TEST_ROOT}/legacy-tw/MEMORY.md" ]
}

@test "legacy tailwind flavor: AGENTS.md is under 80 lines" {
  TAILWIND=1
  export TAILWIND
  render_legacy "${GOSITE_TEST_ROOT}/legacy-tw"
  lines=$(wc -l < "${GOSITE_TEST_ROOT}/legacy-tw/AGENTS.md")
  [ "${lines}" -lt 80 ]
}

@test "the scaffold's CLAUDE.md is exactly one import line" {
  render_thin "${GOSITE_TEST_ROOT}/thin"
  [ "$(wc -l < "${GOSITE_TEST_ROOT}/thin/CLAUDE.md")" -eq 1 ]
  [ "$(cat "${GOSITE_TEST_ROOT}/thin/CLAUDE.md")" = "@AGENTS.md" ]
}
