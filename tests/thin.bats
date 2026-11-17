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
# optional SMTP_* (0.55.0), FORMS_WEBHOOK_* (0.65.0) and RECAPTCHA_SECRET_KEY
# (0.75.0) variables on the CMS, which every site gets.
@test "templates without addons are byte-identical to the pre-Commerce release" {
  local f
  for f in docker-compose.yml docker-compose.qa.yml docker-compose.prod.yml; do
    cp "${GOSITE_ROOT}/templates-thin/generated/${f}" "${F}"
    _thin_filter_addon_blocks "${F}"
    _thin_render_app_env "${F}"
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

@test "Commerce passes the first admin's password to Medusa in every environment" {
  local f
  for f in docker-compose.yml docker-compose.qa.yml docker-compose.prod.yml; do
    cp "${GOSITE_ROOT}/templates-thin/generated/${f}" "${F}"
    _thin_filter_addon_blocks "${F}" Commerce
    # Empty by default: the seed then makes a password and prints it once.
    grep -qE 'COMMERCE_ADMIN_PASSWORD(=|: ")\$\{COMMERCE_ADMIN_PASSWORD:-\}' "${F}"
  done
}

@test "Commerce stores upload to S3 and QA/prod route only the Admin on shop" {
  local f env router
  for f in docker-compose.yml docker-compose.qa.yml docker-compose.prod.yml; do
    cp "${GOSITE_ROOT}/templates-thin/generated/${f}" "${F}"
    _thin_filter_addon_blocks "${F}" Commerce
    # Medusa gets the bucket in every environment (one S3_BUCKET per service).
    [ "$(grep -c 'S3_BUCKET' "${F}")" -ge 2 ]
  done
  for env in qa prod; do
    cp "${GOSITE_ROOT}/templates-thin/generated/docker-compose.${env}.yml" "${F}"
    _thin_filter_addon_blocks "${F}" Commerce
    router="__PROJECT__-shop"
    [[ "${env}" == qa ]] && router="__PROJECT__-qa-shop"
    grep -q "routers.${router}.rule=Host(\`\${SERVICE_FQDN_SHOP}\`) && (PathPrefix(\`/app\`)" "${F}"
    # Never the service's name (Coolify) and never the store API.
    ! grep -q "routers.__PROJECT__-${env}-medusa\." "${F}"
    ! grep -q 'PathPrefix(`/store`)' "${F}"
    # Coolify's magic variable only in its bare form.
    ! grep -q 'SERVICE_FQDN_SHOP:' "${F}"
  done
  # QA's and production's routers must differ (one Traefik).
  ! grep -q '__PROJECT__-shop\.' "${GOSITE_ROOT}/templates-thin/generated/docker-compose.qa.yml"
}

@test "app_env names reach the app service of QA and production, at its indent" {
  local env
  for env in qa prod; do
    cp "${GOSITE_ROOT}/templates-thin/generated/docker-compose.${env}.yml" "${F}"
    _thin_filter_addon_blocks "${F}"
    _thin_render_app_env "${F}" EELZAP_API_KEY WRAP_WEB_FORM_SECRET
    ! grep -q 'gosite:app-env' "${F}"
    grep -qx '      - EELZAP_API_KEY=${EELZAP_API_KEY:-}' "${F}"
    grep -qx '      - WRAP_WEB_FORM_SECRET=${WRAP_WEB_FORM_SECRET:-}' "${F}"
    # In the app service, before the CMS service starts.
    [ "$(grep -n 'EELZAP_API_KEY' "${F}" | cut -d: -f1)" -lt "$(grep -n "^  __PROJECT__-${env}-cms:" "${F}" | cut -d: -f1)" ]
    [ "$(grep -n 'EELZAP_API_KEY' "${F}" | cut -d: -f1)" -gt "$(grep -n "^  __PROJECT__-${env}-app:" "${F}" | cut -d: -f1)" ]
  done
}

@test "app_env keeps working with Commerce enabled" {
  cp "${GOSITE_ROOT}/templates-thin/generated/docker-compose.prod.yml" "${F}"
  _thin_filter_addon_blocks "${F}" Commerce
  _thin_render_app_env "${F}" UPSTASH_SEARCH_INDEX
  grep -A1 'COMMERCE_URL=' "${F}" | grep -q "app_env in gosite.yml"
  grep -qx '      - UPSTASH_SEARCH_INDEX=${UPSTASH_SEARCH_INDEX:-}' "${F}"
}

@test "app_env rejects a name that is not a variable name" {
  cp "${GOSITE_ROOT}/templates-thin/generated/docker-compose.prod.yml" "${F}"
  run _thin_render_app_env "${F}" 'BAD-NAME'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a variable name"* ]]
  run _thin_render_app_env "${F}" 'X=1'
  [ "$status" -ne 0 ]
}

@test "app_env rejects a name the app service already sets" {
  cp "${GOSITE_ROOT}/templates-thin/generated/docker-compose.prod.yml" "${F}"
  _thin_filter_addon_blocks "${F}"
  run _thin_render_app_env "${F}" REDIS_URL
  [ "$status" -ne 0 ]
  [[ "$output" == *"REDIS_URL is already set"* ]]
}

@test "app_env may repeat a name another service sets" {
  # SMTP_HOST is the CMS's; the app can read its own.
  cp "${GOSITE_ROOT}/templates-thin/generated/docker-compose.prod.yml" "${F}"
  _thin_filter_addon_blocks "${F}"
  _thin_render_app_env "${F}" SMTP_HOST
  [ "$(grep -c -- '- SMTP_HOST=' "${F}")" -eq 2 ]
}

@test "the store's Postgres user and database default to medusa in every environment" {
  local f
  for f in docker-compose.yml docker-compose.qa.yml docker-compose.prod.yml; do
    cp "${GOSITE_ROOT}/templates-thin/generated/${f}" "${F}"
    _thin_filter_addon_blocks "${F}" Commerce
    grep -q 'postgres://${MEDUSA_DB_USER:-medusa}:${MEDUSA_DB_PASSWORD}@' "${F}"
    grep -q '5432/${MEDUSA_DB_NAME:-medusa}?sslmode=disable' "${F}"
    grep -q 'POSTGRES_USER.*${MEDUSA_DB_USER:-medusa}' "${F}"
    grep -q 'POSTGRES_DB.*${MEDUSA_DB_NAME:-medusa}' "${F}"
  done
}

@test "gosite_env_flag: true-ish values enable, false-ish and unknown values fall back to the default" {
  local src="${BATS_TEST_TMPDIR}/flag.php" probe="${BATS_TEST_TMPDIR}/probe.php"
  {
    printf '<?php\n'
    awk '/^    function gosite_env_flag/,/^    }$/' "${GOSITE_ROOT}/templates-thin/generated/cockpit/config.core.php" | sed 's/^    //'
  } > "${src}"
  cat > "${probe}" <<PHP
<?php
require '${src}';
\$out = [];
foreach (['1', 'true', 'YES', ' on ', '0', 'off', 'maybe', ''] as \$v) {
    putenv("F=\$v");
    \$out[] = \$v . '=' . (gosite_env_flag('F') ? 'T' : 'F');
}
putenv('F=maybe');
\$out[] = 'default-true=' . (gosite_env_flag('F', true) ? 'T' : 'F');
putenv('F');
\$out[] = 'unset=' . (gosite_env_flag('F') ? 'T' : 'F');
echo implode(' ', \$out);
PHP
  run php "${probe}"
  [ "$status" -eq 0 ]
  [ "$output" = "1=T true=T YES=T  on =T 0=F off=F maybe=F =F default-true=T unset=F" ]
}

# Site-owned Cockpit addons (cockpit/site-addons/): copied into the CMS image
# when present, never written by generate, never allowed to shadow a gosite
# addon.
make_site_addon() {
  mkdir -p "$1/cockpit/site-addons/$2"
  printf '<?php\n' > "$1/cockpit/site-addons/$2/bootstrap.php"
}

@test "Dockerfile.cms without site addons is byte-identical to the template without the marker" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}" tpl="${GOSITE_ROOT}/templates-thin/generated/deploy/Dockerfile.cms"
  mkdir -p "${dir}/cockpit/site-addons"
  cp "${tpl}" "${F}"
  _thin_render_site_addons "${F}" "${dir}"
  grep -v '^# gosite:site-addons$' "${tpl}" > "${F}.want"
  # grep adds a final newline the template does not have.
  printf '%s' "$(cat "${F}.want")" > "${F}.want"
  cmp "${F}.want" "${F}"
}

@test "Dockerfile.cms copies cockpit/site-addons when the site has one" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_site_addon "${dir}" Casos
  cp "${GOSITE_ROOT}/templates-thin/generated/deploy/Dockerfile.cms" "${F}"
  _thin_render_site_addons "${F}" "${dir}"
  ! grep -q 'gosite:site-addons' "${F}"
  grep -qx 'COPY cockpit/site-addons/ /var/www/html/addons/' "${F}"
  # The template's last line keeps its ending.
  [ -n "$(tail -c 1 "${F}")" ]
}

@test "site addons are listed sorted and only folders count" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_site_addon "${dir}" Nosotros
  make_site_addon "${dir}" Casos
  : > "${dir}/cockpit/site-addons/README.md"
  run thin_site_addons "${dir}"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'Casos\nNosotros')" ]
}

@test "a site addon with a gosite addon's name stops generate, whatever its case" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_site_addon "${dir}" forms
  run thin_check_site_addons "${dir}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cockpit/site-addons/forms"* ]]
  [[ "$output" == *"gosite addon Forms"* ]]
}

@test "site addons with their own names pass the check" {
  local dir="${GOSITE_TEST_ROOT}/proj-${RANDOM}"
  make_site_addon "${dir}" Casos
  run thin_check_site_addons "${dir}"
  [ "$status" -eq 0 ]
}

@test "RECAPTCHA_SECRET_KEY reaches the CMS service and never the app" {
  local env svc
  for env in qa prod; do
    cp "${GOSITE_ROOT}/templates-thin/generated/docker-compose.${env}.yml" "${F}"
    _thin_filter_addon_blocks "${F}" Commerce
    # The service a line belongs to is the last two-space key above it.
    svc="$(awk '/^  [^ #]/ { s = $1 } /- RECAPTCHA_SECRET_KEY=/ { print s }' "${F}")"
    [ "${svc}" = "__PROJECT__-${env}-cms:" ]
  done
  cp "${GOSITE_ROOT}/templates-thin/generated/docker-compose.yml" "${F}"
  svc="$(awk '/^  [^ #]/ { s = $1 } /RECAPTCHA_SECRET_KEY: / { print s }' "${F}")"
  [ "${svc}" = "cms:" ]
}
