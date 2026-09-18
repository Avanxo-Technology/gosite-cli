#!/usr/bin/env bats
# Addon-gated rendering in src/lib/thin.sh: a `# gosite:addon <Name>` block
# survives only while the addon is listed in gosite.yml, and its markers never
# reach the project. Plus the per-store secrets generate writes to .env.

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
  F="${GOSITE_TEST_ROOT}/compose-${RANDOM}.yml"
}

write_compose() {
  cat > "$1" <<'EOF'
services:
  app:
    image: app
  # gosite:addon Commerce
  medusa:
    image: medusa
  # gosite:end
  cms:
    image: cms
EOF
}

@test "filter keeps a block whose addon is listed" {
  write_compose "${F}"
  _thin_filter_addon_blocks "${F}" Commerce Blog
  run cat "${F}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"image: medusa"* ]]
  [[ "${output}" == *"image: app"* ]]
  [[ "${output}" == *"image: cms"* ]]
}

@test "filter drops a block whose addon is not listed" {
  write_compose "${F}"
  _thin_filter_addon_blocks "${F}" Blog
  run cat "${F}"
  [[ "${output}" != *"medusa"* ]]
  [[ "${output}" == *"image: app"* ]]
  [[ "${output}" == *"image: cms"* ]]
}

@test "filter removes the markers even on a kept block" {
  write_compose "${F}"
  _thin_filter_addon_blocks "${F}" Commerce
  ! grep -q 'gosite:addon' "${F}"
  ! grep -q 'gosite:end' "${F}"
}

@test "filter matches the addon name case-insensitively" {
  write_compose "${F}"
  _thin_filter_addon_blocks "${F}" commerce
  grep -q 'image: medusa' "${F}"
}

@test "filter with no addons drops every block" {
  write_compose "${F}"
  _thin_filter_addon_blocks "${F}"
  ! grep -q 'medusa' "${F}"
}

@test "filter leaves a file with no blocks byte-identical" {
  printf 'services:\n  app:\n    image: app\n' > "${F}"
  cp "${F}" "${F}.before"
  _thin_filter_addon_blocks "${F}" Commerce
  diff -u "${F}.before" "${F}"
}

make_project_yml() {
  local dir="$1"
  mkdir -p "${dir}"
  cat > "${dir}/gosite.yml" <<'EOF'
project: demo
addons:
  - Commerce
EOF
  : > "${dir}/.env"
}

@test "commerce secrets are generated into .env" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_project_yml "${dir}"
  thin_ensure_commerce_secrets "${dir}"
  grep -q '^JWT_SECRET=..' "${dir}/.env"
  grep -q '^COOKIE_SECRET=..' "${dir}/.env"
  grep -q '^MEDUSA_DB_PASSWORD=..' "${dir}/.env"
}

@test "regenerating never rotates existing commerce secrets" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_project_yml "${dir}"
  printf 'JWT_SECRET=keep-me\n' >> "${dir}/.env"
  thin_ensure_commerce_secrets "${dir}"
  grep -q '^JWT_SECRET=keep-me$' "${dir}/.env"
  [ "$(grep -c '^JWT_SECRET=' "${dir}/.env")" -eq 1 ]
}

@test "a site without Commerce gets no commerce secrets" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  mkdir -p "${dir}"
  printf 'project: demo\naddons:\n  - Blog\n' > "${dir}/gosite.yml"
  : > "${dir}/.env"
  cp "${dir}/.env" "${dir}/.env.before"
  thin_ensure_commerce_secrets "${dir}"
  diff -u "${dir}/.env.before" "${dir}/.env"
}
