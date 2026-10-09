#!/usr/bin/env bats
# gosite docs: the agent notes shipped in src/knowledge/. Runs the repo entry
# point (src/main.sh), never the installed binary, and checks that the command
# writes nothing into the directory it runs from.

setup() {
  load helpers
  _env_reset
  MAIN="${BATS_TEST_DIRNAME}/../src/main.sh"
  KNOWLEDGE="${BATS_TEST_DIRNAME}/../src/knowledge"
  read -r CLI_VERSION < "${BATS_TEST_DIRNAME}/../src/VERSION"
  OUT="${BATS_TEST_TMPDIR}/stdout"
  ERR="${BATS_TEST_TMPDIR}/stderr"
}

# _snapshot <dir> -> every path and its checksum, so a write shows up as a diff.
_snapshot() {
  (cd "$1" && find . | LC_ALL=C sort && find . -type f -exec cksum {} \; | LC_ALL=C sort)
}

@test "list prints one line per note and exits 0" {
  run bash "${MAIN}" docs
  [ "${status}" -eq 0 ]
  expected="$(ls "${KNOWLEDGE}"/*.md | wc -l | tr -d ' ')"
  [ "$(printf '%s\n' "${output}" | wc -l | tr -d ' ')" -eq "${expected}" ]
}

@test "list is sorted by topic and shows the first heading" {
  run bash "${MAIN}" docs
  [ "${status}" -eq 0 ]
  topics="$(printf '%s\n' "${output}" | awk '{print $1}')"
  [ "${topics}" = "$(printf '%s\n' "${topics}" | LC_ALL=C sort)" ]
  printf '%s\n' "${output}" | grep -q '^medusa-admin-api  *Medusa Admin API: loading a catalogue by script or AI$'
}

@test "a known topic prints the note byte-identical to the file" {
  bash "${MAIN}" docs medusa-admin-api > "${OUT}"
  cmp "${OUT}" "${KNOWLEDGE}/medusa-admin-api.md"
}

@test "an unknown topic exits non-zero and names the topic and the valid ones on stderr" {
  run bash -c "bash '${MAIN}' docs nope >'${OUT}' 2>'${ERR}'"
  [ "${status}" -ne 0 ]
  [ ! -s "${OUT}" ]
  grep -q 'nope' "${ERR}"
  grep -q 'medusa-admin-api' "${ERR}"
  grep -q 'cockpit-api-key' "${ERR}"
}

@test "a path-like topic is rejected, not read" {
  run bash -c "bash '${MAIN}' docs ../../VERSION >'${OUT}' 2>'${ERR}'"
  [ "${status}" -ne 0 ]
  [ ! -s "${OUT}" ]
}

@test "inside a thin site with an older core, one version line goes to stderr and stdout is unchanged" {
  dir="${BATS_TEST_TMPDIR}/thin"
  mkdir -p "${dir}"
  printf 'project: demo\ncore: 0.1.0\n' > "${dir}/gosite.yml"
  before="$(_snapshot "${dir}")"

  (cd "${dir}" && bash "${MAIN}" docs medusa-admin-api > "${OUT}" 2> "${ERR}")

  cmp "${OUT}" "${KNOWLEDGE}/medusa-admin-api.md"
  [ "$(wc -l < "${ERR}" | tr -d ' ')" -eq 1 ]
  [ "$(cat "${ERR}")" = "note: this site records gosite 0.1.0; these notes come from gosite ${CLI_VERSION}" ]
  [ "$(_snapshot "${dir}")" = "${before}" ]
}

@test "a thin site found from a subdirectory still gets the version line" {
  dir="${BATS_TEST_TMPDIR}/thin-sub"
  mkdir -p "${dir}/app/deep"
  printf 'project: demo\ncore: 0.1.0\n' > "${dir}/gosite.yml"

  (cd "${dir}/app/deep" && bash "${MAIN}" docs medusa-admin-api > "${OUT}" 2> "${ERR}")

  cmp "${OUT}" "${KNOWLEDGE}/medusa-admin-api.md"
  grep -q 'this site records gosite 0.1.0' "${ERR}"
}

@test "a thin site on the CLI version prints no version line, and a leading v is ignored" {
  dir="${BATS_TEST_TMPDIR}/thin-current"
  mkdir -p "${dir}"
  printf 'project: demo\ncore: v%s\n' "${CLI_VERSION}" > "${dir}/gosite.yml"

  (cd "${dir}" && bash "${MAIN}" docs medusa-admin-api > "${OUT}" 2> "${ERR}")

  cmp "${OUT}" "${KNOWLEDGE}/medusa-admin-api.md"
  [ ! -s "${ERR}" ]
}

@test "inside a legacy site the topic list is the same and no version line is printed" {
  dir="${BATS_TEST_TMPDIR}/legacy"
  mkdir -p "${dir}"
  # Same keys as src/templates/gosite.env: the marker records no gosite version.
  cat > "${dir}/.gosite.env" <<'EOF'
GOSITE_PROJECT=demo
GOSITE_MODULE=github.com/example/demo
GOSITE_APP_PORT=8100
GOSITE_CMS_PORT=8101
GOSITE_TAILWIND=0
GOSITE_APP_DOMAIN=demo.test
GOSITE_CMS_DOMAIN=cms.demo.test
GOSITE_NETWORK=gosite
GOSITE_ADDONS=0
GOSITE_DATABASE=mongodb
EOF
  before="$(_snapshot "${dir}")"

  (cd "${dir}" && bash "${MAIN}" docs > "${OUT}" 2> "${ERR}")
  (cd "${BATS_TEST_TMPDIR}" && bash "${MAIN}" docs > "${BATS_TEST_TMPDIR}/elsewhere" 2>/dev/null)

  cmp "${OUT}" "${BATS_TEST_TMPDIR}/elsewhere"
  [ ! -s "${ERR}" ]
  (cd "${dir}" && bash "${MAIN}" docs minio-s3-ssl-fix > "${OUT}" 2> "${ERR}")
  cmp "${OUT}" "${KNOWLEDGE}/minio-s3-ssl-fix.md"
  [ ! -s "${ERR}" ]
  [ "$(_snapshot "${dir}")" = "${before}" ]
}

@test "list mode never prints the version line, even inside a mismatched site" {
  dir="${BATS_TEST_TMPDIR}/thin-list"
  mkdir -p "${dir}"
  printf 'project: demo\ncore: 0.1.0\n' > "${dir}/gosite.yml"

  (cd "${dir}" && bash "${MAIN}" docs > "${OUT}" 2> "${ERR}")

  [ ! -s "${ERR}" ]
}
