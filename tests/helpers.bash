# bats-core helper sourced by every test file in tests/.
#
# Contract (task 9.4 of harden-gosite-phased):
#   - GOSITE_HOME and GOSITE_WORKSPACE point at throwaway temp dirs, so no
#     test ever touches the developer's real ~/.gosite or ~/sites.
#   - No Docker dependency: only the pure state libraries (helpers.sh,
#     manifest.sh) are under test. `docker ps` failing is tolerated by
#     design in the port allocator.
#
# Usage in a test file:
#   setup() { load helpers; _env_reset; }

# --- load-time: one teardown-able root + the libraries under test ----------
GOSITE_TEST_ROOT="$(mktemp -d "${BATS_TMPDIR}/gosite-tests.XXXXXX")"

# Colors emptied: output must not depend on a TTY.
C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_DIM='' C_BOLD='' C_NC=''
export C_RED C_GREEN C_YELLOW C_BLUE C_CYAN C_DIM C_BOLD C_NC

# config.sh first: it defines GOSITE_MARKER, port ranges and defaults that
# helpers.sh builds on. Derived paths are recomputed per test in _env_reset.
# shellcheck source=../src/lib/config.sh
source "${BATS_TEST_DIRNAME}/../src/lib/config.sh"
# shellcheck source=../src/lib/helpers.sh
source "${BATS_TEST_DIRNAME}/../src/lib/helpers.sh"
# shellcheck source=../src/lib/manifest.sh
source "${BATS_TEST_DIRNAME}/../src/lib/manifest.sh"

teardown_file() {
  [[ -n "${GOSITE_TEST_ROOT:-}" ]] && rm -rf "${GOSITE_TEST_ROOT}"
}

# --- per-test: fresh GOSITE_HOME / GOSITE_WORKSPACE state ------------------
_env_reset() {
  GOSITE_TEST_HOME="${GOSITE_TEST_ROOT}/home-${RANDOM}"
  GOSITE_TEST_WORKSPACE="${GOSITE_TEST_ROOT}/sites-${RANDOM}"
  mkdir -p "${GOSITE_TEST_HOME}" "${GOSITE_TEST_WORKSPACE}"

  # Deterministic and Docker-free: a stub `docker` answers instantly with no
  # containers. The port allocator tolerates docker failing, but with the real
  # binary a slow daemon would make the lock-timeout path non-deterministic.
  if [[ ! -x "${GOSITE_TEST_ROOT}/bin/docker" ]]; then
    mkdir -p "${GOSITE_TEST_ROOT}/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${GOSITE_TEST_ROOT}/bin/docker"
    chmod +x "${GOSITE_TEST_ROOT}/bin/docker"
  fi
  export PATH="${GOSITE_TEST_ROOT}/bin:${PATH}"

  export GOSITE_HOME="${GOSITE_TEST_HOME}"
  export GOSITE_WORKSPACE="${GOSITE_TEST_WORKSPACE}"
  export GOSITE_VERBOSE=0
  export GOSITE_ASSUME_YES=1
  # Production default: under heavy contention (8 parallel allocations, each
  # scanning with lsof) the wait can legitimately take seconds. Tests that
  # exercise the timeout path set their own short value.
  export GOSITE_LOCK_TIMEOUT=30

  # Recompute the derived paths the way a fresh CLI invocation would.
  GOSITE_REGISTRY="${GOSITE_HOME}/projects.tsv"
  GOSITE_PORTS_FILE="${GOSITE_HOME}/ports.tsv"
  export GOSITE_REGISTRY GOSITE_PORTS_FILE
}

# Creates a minimal but valid project directory with a gosite marker.
make_project() {
  local dir="${GOSITE_TEST_WORKSPACE}/$1"
  mkdir -p "${dir}"
  cat > "${dir}/${GOSITE_MARKER}" <<EOF
GOSITE_PROJECT=$1
GOSITE_MODULE=github.com/example/$1
GOSITE_APP_PORT=8100
GOSITE_CMS_PORT=8101
GOSITE_APP_DOMAIN=$1.test
GOSITE_CMS_DOMAIN=cms.$1.test
GOSITE_DATABASE=mongodb
EOF
  printf '%s\n' "${dir}"
}
