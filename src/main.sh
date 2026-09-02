#!/usr/bin/env bash
#
# gosite - local dev environments + Coolify-ready production files
# for a Go (Echo/htmx/Alpine/Templ) + Cockpit CMS monolith.
#
# This file is the global entrypoint. It is symlinked into /usr/local/bin,
# so it must resolve its own real location before sourcing sibling modules.
#
set -euo pipefail

# --- resolve real script location (follows the symlink chain) -----------------
__source="${BASH_SOURCE[0]}"
while [[ -L "${__source}" ]]; do
  __dir="$(cd -P "$(dirname "${__source}")" && pwd)"
  __source="$(readlink "${__source}")"
  [[ "${__source}" != /* ]] && __source="${__dir}/${__source}"
done
# Assign first, readonly after: `readonly X` on an unset variable would make
# the following assignment fail, and `readonly X="$(...)"` (SC2155) masks the
# command's failure. An empty GOSITE_ROOT still fails loudly at the first
# source below.
GOSITE_ROOT="$(cd -P "$(dirname "${__source}")" && pwd)"
readonly GOSITE_ROOT
export GOSITE_ROOT

# --- metadata ----------------------------------------------------------------
GOSITE_VERSION="$(cat "${GOSITE_ROOT}/VERSION" 2>/dev/null || echo "0.0.0")"
readonly GOSITE_VERSION
export GOSITE_VERSION

# --- colors (disabled when not a TTY or when NO_COLOR is set) ----------------
# The C_* variables are this CLI's cross-module interface: assigned here,
# consumed by every sourced module's output helpers.
# shellcheck disable=SC2034
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly C_RED='\033[0;31m'
  readonly C_GREEN='\033[0;32m'
  readonly C_YELLOW='\033[1;33m'
  readonly C_BLUE='\033[0;34m'
  readonly C_CYAN='\033[0;36m'
  readonly C_DIM='\033[2m'
  readonly C_BOLD='\033[1m'
  readonly C_NC='\033[0m'
else
  readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_DIM='' C_BOLD='' C_NC=''
fi

# --- global flags ------------------------------------------------------------
GOSITE_VERBOSE=0
GOSITE_ASSUME_YES=0
export GOSITE_VERBOSE GOSITE_ASSUME_YES

# --- load modules ------------------------------------------------------------
# shellcheck source=lib/config.sh
source "${GOSITE_ROOT}/lib/config.sh"
# shellcheck source=lib/helpers.sh
source "${GOSITE_ROOT}/lib/helpers.sh"
# shellcheck source=lib/hostdeps.sh
source "${GOSITE_ROOT}/lib/hostdeps.sh"
# shellcheck source=lib/tls.sh
source "${GOSITE_ROOT}/lib/tls.sh"
# shellcheck source=dispatcher.sh
source "${GOSITE_ROOT}/dispatcher.sh"

# --- flag parsing ------------------------------------------------------------
# Global flags are consumed here; everything after the first non-flag token is
# handed over to the dispatcher untouched so subcommands keep their own flags.
parse_global_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)  GOSITE_VERBOSE=1; shift ;;
      -y|--yes)      GOSITE_ASSUME_YES=1; shift ;;
      --no-color)    export NO_COLOR=1; shift ;;
      -V|--version)  printf "gosite %s\n" "${GOSITE_VERSION}"; exit 0 ;;
      -h|--help)     set -- "help"; break ;;
      --)            shift; break ;;
      -*)            fatal "Unknown global flag: $1 (try 'gosite help')" ;;
      *)             break ;;
    esac
  done
  GOSITE_ARGS=("$@")
}

main() {
  parse_global_flags "$@"
  # "${arr[@]+"${arr[@]}"}" keeps an empty array from injecting one empty
  # argument under bash 3.2 + set -u, where "${arr[@]:-}" expands to a single "".
  dispatch "${GOSITE_ARGS[@]+"${GOSITE_ARGS[@]}"}"
}

main "$@"
