#!/usr/bin/env bash
#
# gosite installer
# Copies the CLI modules into a system-wide location and symlinks the
# entrypoint into $BIN_DIR so `gosite` is available from any shell.
#
set -euo pipefail

SHARE_DIR="/usr/local/share/gosite"
BIN_DIR="/usr/local/bin"
BIN_NAME="gosite"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { printf "${BLUE}==>${NC} %s\n" "$1"; }
ok()    { printf "${GREEN} ok${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}  ! ${NC}%s\n" "$1"; }
fatal() { printf "${RED}  x ${NC}%s\n" "$1" >&2; exit 1; }

# --- privilege check ---------------------------------------------------------
# Re-exec through sudo instead of failing, so `./install.sh` just works.
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    warn "Administrator privileges are required to write to ${SHARE_DIR}."
    info "Re-running through sudo..."
    exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
  fi
  fatal "This installer must be run as root (sudo) and sudo was not found."
fi

# --- sanity checks -----------------------------------------------------------
[[ -d "${SRC_DIR}" ]]            || fatal "src/ directory not found next to install.sh."
[[ -f "${SRC_DIR}/main.sh" ]]    || fatal "src/main.sh not found."

# --- install -----------------------------------------------------------------
info "Installing gosite into ${SHARE_DIR}"
rm -rf "${SHARE_DIR}"
mkdir -p "${SHARE_DIR}"
cp -R "${SRC_DIR}" "${SHARE_DIR}/src"

# Every module must be readable; only the entrypoint needs to be executable.
find "${SHARE_DIR}" -type f -name '*.sh' -exec chmod 0644 {} +
find "${SHARE_DIR}" -type d -exec chmod 0755 {} +
chmod 0755 "${SHARE_DIR}/src/main.sh"
ok "Modules copied."

info "Linking ${SHARE_DIR}/src/main.sh -> ${BIN_DIR}/${BIN_NAME}"
mkdir -p "${BIN_DIR}"
ln -sfn "${SHARE_DIR}/src/main.sh" "${BIN_DIR}/${BIN_NAME}"
ok "Symlink created."

# --- verify ------------------------------------------------------------------
if ! command -v "${BIN_NAME}" >/dev/null 2>&1; then
  warn "${BIN_DIR} does not seem to be in your PATH. Add it to your shell profile:"
  printf '    export PATH="%s:$PATH"\n' "${BIN_DIR}"
else
  ok "gosite is available at $(command -v ${BIN_NAME})"
fi

printf "\n${GREEN}Installation complete.${NC} Run '${BIN_NAME} help' to get started.\n"
printf "To uninstall: sudo rm -rf %s %s/%s\n" "${SHARE_DIR}" "${BIN_DIR}" "${BIN_NAME}"
