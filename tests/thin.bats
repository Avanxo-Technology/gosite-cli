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

@test "commerce secrets include the Redis password" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_project_yml "${dir}"
  thin_ensure_commerce_secrets "${dir}"
  grep -q '^MEDUSA_REDIS_PASSWORD=..' "${dir}/.env"
}

@test "a Commerce project without .env gets one with its secrets" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_project_yml "${dir}"
  rm "${dir}/.env"
  thin_ensure_commerce_secrets "${dir}"
  grep -q '^JWT_SECRET=..' "${dir}/.env"
  # GNU first, in separate assignments: GNU `stat -f` means --file-system (see
  # _mtime in helpers.sh), so a combined `||` concatenates on Linux.
  local mode
  mode="$(stat -c '%a' "${dir}/.env" 2>/dev/null)" || mode="$(stat -f '%Lp' "${dir}/.env")"
  [ "${mode}" = "600" ]
}

@test "Commerce without commerce_region stops generate" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_project_yml "${dir}"
  run thin_check_commerce "${dir}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no commerce_region"* ]]
}

@test "an unsupported commerce_region stops generate" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_project_yml "${dir}"
  printf 'commerce_region: mx\n' >> "${dir}/gosite.yml"
  run thin_check_commerce "${dir}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'mx' is not supported"* ]]
}

@test "a supported commerce_region passes" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_project_yml "${dir}"
  printf 'commerce_region: us\n' >> "${dir}/gosite.yml"
  run thin_check_commerce "${dir}"
  [ "$status" -eq 0 ]
}

@test "filter fails on a block that is never closed" {
  printf 'a\n# gosite:addon Blog\nlost\n' > "${F}"
  run _thin_filter_addon_blocks "${F}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never closed"* ]]
}

@test "filter fails on a nested block" {
  printf '# gosite:addon Blog\n# gosite:addon Commerce\n# gosite:end\n' > "${F}"
  run _thin_filter_addon_blocks "${F}" Blog Commerce
  [ "$status" -ne 0 ]
  [[ "$output" == *"nested block"* ]]
}

@test "filter fails on a stray end marker" {
  printf 'a\n# gosite:end\n' > "${F}"
  run _thin_filter_addon_blocks "${F}"
  [ "$status" -ne 0 ]
}

# The real templates, rendered without addons, must be byte-identical to the
# compose files of the release before Commerce: the six live sites regenerate
# with no diff. The fixtures are those files from commit 3d5e7da plus the
# optional SMTP_* variables on the CMS (0.55.0), which every site gets.
@test "templates without addons are byte-identical to the pre-Commerce release" {
  local f
  for f in docker-compose.yml docker-compose.qa.yml docker-compose.prod.yml; do
    cp "${GOSITE_ROOT}/templates-thin/generated/${f}" "${F}"
    _thin_filter_addon_blocks "${F}"
    diff -u "${BATS_TEST_DIRNAME}/fixtures/compose-without-addons/${f}" "${F}"
  done
}

@test "templates with Commerce keep no markers and isolate the store's data" {
  local f
  for f in docker-compose.yml docker-compose.qa.yml docker-compose.prod.yml; do
    cp "${GOSITE_ROOT}/templates-thin/generated/${f}" "${F}"
    _thin_filter_addon_blocks "${F}" Commerce
    ! grep -q 'gosite:addon\|gosite:end' "${F}"
    grep -q 'internal: true' "${F}"
    grep -q -- '--requirepass' "${F}"
    grep -q 'condition: service_healthy' "${F}"
  done
}
