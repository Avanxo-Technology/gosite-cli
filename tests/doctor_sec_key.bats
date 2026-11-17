#!/usr/bin/env bats
# gosite doctor's sec-key audit (_audit_project in cmd_doctor.sh), run on
# temporary project folders. Only the audit function is called: it reads
# files and touches neither Docker nor the registry.

setup() {
  load helpers
  _env_reset
  export GOSITE_ROOT="${BATS_TEST_DIRNAME}/../src"
  # shellcheck source=../src/commands/cmd_doctor.sh
  source "${GOSITE_ROOT}/commands/cmd_doctor.sh"
  # shellcheck disable=SC2034 # read by _audit_finding
  GOSITE_AUDIT_FINDINGS=0
  SITE="${BATS_TEST_TMPDIR}/site"
  mkdir -p "${SITE}/cockpit"
  printf 'COCKPIT_SEC_KEY=s3cr3t-value-0123\n' > "${SITE}/.env"
}

# Renders the current legacy config the way create does, with a real key.
render_current_legacy_config() {
  sed -e 's|__COCKPIT_SEC_KEY__|s3cr3t-value-0123|g' -e 's|__PROJECT__|demo|g' \
    "${GOSITE_ROOT}/templates/cockpit/config.php" > "${SITE}/cockpit/config.php"
}

@test "sec-key: the current templates have no fallback, so no finding" {
  render_current_legacy_config
  run _audit_project demo "${SITE}"
  [[ "${output}" != *"sec-key fallback"* ]]
  [[ "${output}" != *"COCKPIT_SEC_KEY"* ]]
}

@test "sec-key: a legacy config with the template placeholder is a finding" {
  render_current_legacy_config
  printf "    'sec-key' => getenv('COCKPIT_SEC_KEY') ?: '__COCKPIT_SEC_KEY__',\n" >> "${SITE}/cockpit/config.php"
  run _audit_project demo "${SITE}"
  [[ "${output}" == *"sec-key fallback"* ]]
  [[ "${output}" == *"the public template placeholder"* ]]
  [[ "${output}" == *"MIGRATIONS"* ]]
}

@test "sec-key: a key written in the config is a finding, and its value is not printed" {
  render_current_legacy_config
  printf "    'sec-key' => getenv('COCKPIT_SEC_KEY') ?: 's3cr3t-value-0123',\n" >> "${SITE}/cockpit/config.php"
  run _audit_project demo "${SITE}"
  [[ "${output}" == *"a key written in the file"* ]]
  [[ "${output}" != *"s3cr3t-value-0123"* ]]
}

@test "sec-key: a thin site's fallback is fixed with gosite generate" {
  touch "${SITE}/gosite.yml"
  printf "    'sec-key' => getenv('COCKPIT_SEC_KEY') ?: 'abc',\n" > "${SITE}/cockpit/config.core.php"
  run _audit_project demo "${SITE}"
  [[ "${output}" == *"sec-key fallback"* ]]
  [[ "${output}" == *"gosite generate"* ]]
}

@test "sec-key: .env without a key, or with the placeholder, is a finding" {
  render_current_legacy_config
  printf 'COCKPIT_API_TOKEN=t\n' > "${SITE}/.env"
  run _audit_project demo "${SITE}"
  [[ "${output}" == *"absent or a placeholder in .env"* ]]

  printf 'COCKPIT_SEC_KEY=__COCKPIT_SEC_KEY__\n' > "${SITE}/.env"
  run _audit_project demo "${SITE}"
  [[ "${output}" == *"absent or a placeholder in .env"* ]]
}
