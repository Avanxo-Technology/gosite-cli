#!/usr/bin/env bats
#
# The gosite-medusa entrypoint refuses to start without its secrets: Medusa
# would otherwise fall back to the default secret "supersecret".

setup() {
  ENTRYPOINT="${BATS_TEST_DIRNAME}/../services/medusa/entrypoint.sh"
  # Stop right before the entrypoint touches /app or Medusa.
  SCRIPT="$(sed 's#^cd /app#exit 0#' "${ENTRYPOINT}")"
}

run_entrypoint() {
  run env -i PATH=/usr/bin:/bin "$@" bash -c "${SCRIPT}"
}

@test "entrypoint refuses to start without secrets" {
  run_entrypoint
  [ "$status" -eq 1 ]
  [[ "$output" == *"JWT_SECRET COOKIE_SECRET DATABASE_URL must be set"* ]]
}

@test "entrypoint refuses a blank secret" {
  run_entrypoint JWT_SECRET=a "COOKIE_SECRET= " DATABASE_URL=x
  [ "$status" -eq 1 ]
  [[ "$output" == *"COOKIE_SECRET must be set"* ]]
}

@test "entrypoint starts with every secret set" {
  run_entrypoint JWT_SECRET=a COOKIE_SECRET=b DATABASE_URL=x
  [ "$status" -eq 0 ]
}
