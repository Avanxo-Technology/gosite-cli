#!/usr/bin/env bats
# gosite upgrade on a rendered thin site, without Docker or the network: go
# and curl are stubs on PATH (docker is the helpers.bash stub), and the
# production images are skipped with --no-images. The CLI's version is the
# repository's src/VERSION, so the site's version is set relative to it.

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
  CLI_VERSION="$(cat "${GOSITE_ROOT}/VERSION")"

  # go: records its arguments, succeeds. curl: fails, as without network.
  STUBS="${GOSITE_TEST_ROOT}/stubs-${RANDOM}"
  mkdir -p "${STUBS}"
  printf '#!/usr/bin/env bash\necho "go $*" >> "%s/go.log"\nexit 0\n' "${STUBS}" > "${STUBS}/go"
  printf '#!/usr/bin/env bash\nexit 22\n' > "${STUBS}/curl"
  chmod +x "${STUBS}/go" "${STUBS}/curl"
  export PATH="${STUBS}:${PATH}"

  # Temporary files of the command land here, so a leftover copy is visible.
  export TMPDIR="${GOSITE_TEST_ROOT}/tmp-${RANDOM}"
  mkdir -p "${TMPDIR}"

  SITE="$(make_project demo)"
  render_thin_site "${SITE}" 0.1.0
}

# A thin site generated at <version>, the way create + generate write it.
render_thin_site() {
  local dir="$1" version="$2"
  (
    PROJECT_NAME="demo" PROJECT_MODULE="github.com/example/demo"
    APP_PORT="8100" CMS_PORT="8101" APP_DOMAIN="demo.test" CMS_DOMAIN="cms.demo.test"
    CMS_TOKEN="demo-token" COCKPIT_SEC_KEY="demo-sec-key" INSTALL_ADDONS=0
    DATABASE="mongodb" STORAGE_ADAPTER="s3" TAILWIND=0 S3_KEY="k" S3_SECRET="s"
    GOSITE_NETWORK="gosite-network" GOSITE_REDIS_HOST="gosite-redis"
    GOSITE_MONGO_HOST="gosite-mongo" GOSITE_MONGO_PORT="27017"
    GOSITE_MINIO_HOST="gosite-minio" GOSITE_TLD="test"
    export PROJECT_NAME PROJECT_MODULE APP_PORT CMS_PORT APP_DOMAIN CMS_DOMAIN \
      CMS_TOKEN COCKPIT_SEC_KEY INSTALL_ADDONS DATABASE STORAGE_ADAPTER TAILWIND \
      S3_KEY S3_SECRET GOSITE_NETWORK GOSITE_REDIS_HOST GOSITE_MONGO_HOST \
      GOSITE_MONGO_PORT GOSITE_MINIO_HOST GOSITE_TLD
    export GOSITE_VERSION="${version}"
    thin_write_siteyml "${dir}" Analytics
    thin_scaffold "${dir}"
    thin_set_core_version "${dir}/gosite.yml" "${version}"
    printf 'COCKPIT_SEC_KEY=demo-sec-key\nCOCKPIT_API_TOKEN=demo-token\n' > "${dir}/.env"
    thin_generate "${dir}" >/dev/null
  )
}

tree_sum() { (cd "$1" && find . -type f ! -name go.log -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum); }

upgrade() { run bash "${GOSITE_ROOT}/main.sh" upgrade "$@"; }

@test "upgrade: the local compose names GOSITE_ADDONS_DIR, not a path of this machine" {
  run grep -n 'gosite-addons:' "${SITE}/docker-compose.yml"
  [[ "${output}" == *'${GOSITE_ADDONS_DIR:?'* ]]
  run grep -q "${GOSITE_ROOT}" "${SITE}/docker-compose.yml"
  [ "${status}" -ne 0 ]
}

@test "upgrade: two installations generate the same local compose" {
  local other="${GOSITE_TEST_ROOT}/install-${RANDOM}"
  ln -s "$(cd "${GOSITE_ROOT}" && pwd)" "${other}"
  local second; second="$(make_project demo2)"
  GOSITE_ROOT="${other}" render_thin_site "${second}" 0.1.0
  diff "${SITE}/docker-compose.yml" "${second}/docker-compose.yml"
}

@test "upgrade: project_compose exports GOSITE_ADDONS_DIR" {
  compose() { printf '%s\n' "${GOSITE_ADDONS_DIR}"; }
  GOSITE_PROJECT=demo run project_compose "${SITE}" config
  [ "${output}" = "${GOSITE_ROOT}/addons" ]
}

@test "upgrade: a legacy site is refused" {
  local legacy; legacy="$(make_project legacy)"
  upgrade "${legacy}" --no-images
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"only upgrades thin sites"* ]]
}

@test "upgrade: a site at the CLI's version has nothing to do" {
  thin_set_core_version "${SITE}/gosite.yml" "${CLI_VERSION}"
  local before; before="$(tree_sum "${SITE}")"
  upgrade "${SITE}" --no-images
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already at ${CLI_VERSION}"* ]]
  [ "$(tree_sum "${SITE}")" = "${before}" ]
}

@test "upgrade: a site newer than the CLI asks for gosite update" {
  thin_set_core_version "${SITE}/gosite.yml" 99.0.0
  upgrade "${SITE}" --no-images
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"gosite update"* ]]
}

@test "upgrade: a hand-added compose variable stops it before any change" {
  printf '      - SITE_OWN_SETTING=${SITE_OWN_SETTING:-}\n' > "${BATS_TEST_TMPDIR}/line"
  awk -v line="$(cat "${BATS_TEST_TMPDIR}/line")" \
    '{ print } /- APP_ENV=production/ && !done { print line; done=1 }' \
    "${SITE}/docker-compose.prod.yml" > "${BATS_TEST_TMPDIR}/prod" && cp "${BATS_TEST_TMPDIR}/prod" "${SITE}/docker-compose.prod.yml"
  grep -q SITE_OWN_SETTING "${SITE}/docker-compose.prod.yml"
  local before; before="$(tree_sum "${SITE}")"

  upgrade "${SITE}" --no-images
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"docker-compose.prod.yml"*"SITE_OWN_SETTING"* ]]
  [[ "${output}" == *"app_env:"* ]]
  [ "$(tree_sum "${SITE}")" = "${before}" ]
  [ ! -e "${STUBS}/go.log" ]
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "upgrade: --force continues past the check and reports the lost variable" {
  awk '{ print } /- APP_ENV=production/ && !done { print "      - SITE_OWN_SETTING=x"; done=1 }' \
    "${SITE}/docker-compose.prod.yml" > "${BATS_TEST_TMPDIR}/prod" && cp "${BATS_TEST_TMPDIR}/prod" "${SITE}/docker-compose.prod.yml"

  upgrade "${SITE}" --no-images --force
  [ "${status}" -eq 0 ]
  [ "$(siteyml_get "${SITE}/gosite.yml" core)" = "${CLI_VERSION}" ]
  [[ "${output}" == *"lost:"*"SITE_OWN_SETTING"* ]]
  run grep -q SITE_OWN_SETTING "${SITE}/docker-compose.prod.yml"
  [ "${status}" -ne 0 ]
}

@test "upgrade: a clean site is upgraded; go runs get, tidy, build, vet, test" {
  upgrade "${SITE}" --no-images
  [ "${status}" -eq 0 ]
  [ "$(siteyml_get "${SITE}/gosite.yml" core)" = "${CLI_VERSION}" ]
  grep -q "core:${CLI_VERSION}\|core/v${CLI_VERSION}" "${SITE}/docker-compose.prod.yml"
  run cat "${STUBS}/go.log"
  [ "${lines[0]}" = "go get github.com/Avanxo-Technology/gosite-cli/core@v${CLI_VERSION}" ]
  [ "${lines[1]}" = "go mod tidy" ]
  [ "${lines[2]}" = "go build ./..." ]
  [ "${lines[3]}" = "go vet ./..." ]
  [ "${lines[4]}" = "go test ./..." ]
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "upgrade: without network the MIGRATIONS link is printed and it still succeeds" {
  upgrade "${SITE}" --no-images
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"blob/v${CLI_VERSION}/MIGRATIONS.md"* ]]
  [[ "${output}" == *"not checked (--no-images)"* ]]
  [[ "${output}" == *"Nothing was committed or deployed."* ]]
}

@test "upgrade: MIGRATIONS sections are those after the old version up to the new one" {
  cat > "${BATS_TEST_TMPDIR}/m.md" <<'EOF'
# Migrations
## How to merge a project forward
text
## → 0.69.0 — old
skip me
## → 0.70.0 — sec-key
keep A
### a subsection
keep B
## → 0.70.1 — admin
keep C
## → 0.71.0 — cache
keep D
## → 0.72.0 — future
skip too
EOF
  # A fresh shell: this file already sourced thin.sh, whose readonly
  # variables cmd_upgrade.sh would define again.
  run bash -c 'source "$1/lib/helpers.sh"; source "$1/commands/cmd_upgrade.sh"; upgrade_migration_sections 0.69.0 0.71.0 < "$2"' _ "${GOSITE_ROOT}" "${BATS_TEST_TMPDIR}/m.md"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"keep A"*"keep B"*"keep C"*"keep D"* ]]
  [[ "${output}" != *"skip"* ]]
  [[ "${output}" != *"How to merge"* ]]
}

@test "thin_compose_var_names reads list and map forms; a missing file is empty" {
  printf 'services:\n  a:\n    environment:\n      - ONE=1\n      TWO: "2"\n      - ONE=again\n' > "${BATS_TEST_TMPDIR}/c.yml"
  run thin_compose_var_names "${BATS_TEST_TMPDIR}/c.yml"
  [ "${output}" = "$(printf 'ONE\nTWO')" ]
  run thin_compose_var_names "${BATS_TEST_TMPDIR}/none.yml"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "thin_set_core_version changes only the core line" {
  printf 'project: demo\ncore: 0.1.0\nflavor: plain\n' > "${BATS_TEST_TMPDIR}/g.yml"
  thin_set_core_version "${BATS_TEST_TMPDIR}/g.yml" 0.2.0
  [ "$(cat "${BATS_TEST_TMPDIR}/g.yml")" = "$(printf 'project: demo\ncore: 0.2.0\nflavor: plain')" ]
  printf 'project: demo\n' > "${BATS_TEST_TMPDIR}/h.yml"
  run thin_set_core_version "${BATS_TEST_TMPDIR}/h.yml" 0.2.0
  [ "${status}" -ne 0 ]
}

@test "generate: a site addon with a gosite addon's name exits non-zero and writes nothing" {
  mkdir -p "${SITE}/cockpit/site-addons/Forms"
  local before; before="$(tree_sum "${SITE}")"
  run bash "${GOSITE_ROOT}/main.sh" generate "${SITE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cockpit/site-addons/Forms"* ]]
  [[ "${output}" != *"Rebuild for the changes"* ]]
  [ "$(tree_sum "${SITE}")" = "${before}" ]
}

@test "generate: a site addon reaches the CMS Dockerfile and is left untouched" {
  mkdir -p "${SITE}/cockpit/site-addons/Casos"
  printf '<?php\n' > "${SITE}/cockpit/site-addons/Casos/bootstrap.php"
  run bash "${GOSITE_ROOT}/main.sh" generate "${SITE}"
  [ "${status}" -eq 0 ]
  grep -qx 'COPY cockpit/site-addons/ /var/www/html/addons/' "${SITE}/deploy/Dockerfile.cms"
  [ "$(cat "${SITE}/cockpit/site-addons/Casos/bootstrap.php")" = "<?php" ]
}

@test "upgrade: a site addon with a gosite addon's name stops it before any change" {
  mkdir -p "${SITE}/cockpit/site-addons/Blog"
  local before; before="$(tree_sum "${SITE}")"
  upgrade "${SITE}" --no-images
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"cockpit/site-addons/Blog"* ]]
  [ "$(tree_sum "${SITE}")" = "${before}" ]
  [ ! -e "${STUBS}/go.log" ]
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "generate: a __NAME__ token in the site's own files does not stop it" {
  mkdir -p "${SITE}/static/js/vendor"
  printf 'var c = window.__REDUX_DEVTOOLS_EXTENSION_COMPOSE__ || f;\n' > "${SITE}/static/js/vendor/lib.min.js"
  run bash "${GOSITE_ROOT}/main.sh" generate "${SITE}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Unresolved placeholder"* ]]
  grep -q __REDUX_DEVTOOLS_EXTENSION_COMPOSE__ "${SITE}/static/js/vendor/lib.min.js"
}

@test "thin_set_core_version keeps the file's mode" {
  chmod 644 "${SITE}/gosite.yml"
  thin_set_core_version "${SITE}/gosite.yml" 9.9.9
  grep -qx 'core: 9.9.9' "${SITE}/gosite.yml"
  local mode
  mode="$(stat -c '%a' "${SITE}/gosite.yml" 2>/dev/null)" || mode="$(stat -f '%Lp' "${SITE}/gosite.yml")"
  [ "${mode}" = "644" ]
}
