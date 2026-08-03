#!/usr/bin/env bash
#
# gosite installer
#
#   Remote: curl -fsSL https://raw.githubusercontent.com/Avanxo-Technology/gosite-cli/main/install.sh | bash
#   Local:  git clone ... && cd gosite-cli && ./install.sh
#
# Installs per user into ~/.local by default (no sudo). Pass --system for a
# machine-wide install into /usr/local, which escalates through sudo.
#
# In remote mode the script has no src/ next to it, so it downloads the
# repository tarball into a temp directory and installs from there.
#
set -euo pipefail

BIN_NAME="gosite"

# Overridable so forks and release tags can be installed without editing this file.
GOSITE_REPO="${GOSITE_REPO:-Avanxo-Technology/gosite-cli}"
GOSITE_REF="${GOSITE_REF:-main}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; DIM='\033[2m'; NC='\033[0m'
info()  { printf "${BLUE}==>${NC} %s\n" "$1"; }
ok()    { printf "${GREEN} ok${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}  ! ${NC}%s\n" "$1"; }
fatal() { printf "${RED}  x ${NC}%s\n" "$1" >&2; exit 1; }

cleanup() { [[ -n "${GOSITE_TMP_ROOT:-}" ]] && rm -rf "${GOSITE_TMP_ROOT}" || true; }
trap cleanup EXIT

# --- flags -------------------------------------------------------------------
GOSITE_SYSTEM="${GOSITE_SYSTEM:-0}"
for arg in "$@"; do
  case "${arg}" in
    --system) GOSITE_SYSTEM=1 ;;
    --user)   GOSITE_SYSTEM=0 ;;
    -h|--help)
      cat <<USAGE
gosite installer

  ./install.sh             Install into ~/.local (default, no sudo)
  ./install.sh --system    Install into /usr/local for all users (uses sudo)

Environment overrides: GOSITE_REPO, GOSITE_REF, GOSITE_PREFIX
USAGE
      exit 0 ;;
    *) fatal "Unknown option: ${arg}" ;;
  esac
done

# --- install prefix ----------------------------------------------------------
if [[ "${GOSITE_SYSTEM}" -eq 1 ]]; then
  PREFIX="${GOSITE_PREFIX:-/usr/local}"
else
  PREFIX="${GOSITE_PREFIX:-${HOME}/.local}"
fi
SHARE_DIR="${PREFIX}/share/gosite"
BIN_DIR="${PREFIX}/bin"

# --- locate the payload ------------------------------------------------------
# When piped from curl, BASH_SOURCE is not a real file, so this resolves to a
# directory with no src/ and the download below takes over.
# BASH_SOURCE is unset when the script is piped into bash, hence the :- guard.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
SRC_DIR="${SELF_DIR}/src"

download_source() {
  local url="https://codeload.github.com/${GOSITE_REPO}/tar.gz/${GOSITE_REF}"
  info "Downloading ${GOSITE_REPO}@${GOSITE_REF}"

  GOSITE_TMP_ROOT="$(mktemp -d)"
  export GOSITE_TMP_ROOT

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" | tar -xz -C "${GOSITE_TMP_ROOT}" --strip-components=1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "${url}" | tar -xz -C "${GOSITE_TMP_ROOT}" --strip-components=1
  else
    fatal "Neither curl nor wget is available; cannot download the installer payload."
  fi

  [[ -f "${GOSITE_TMP_ROOT}/src/main.sh" ]] || fatal "Downloaded archive does not contain src/main.sh."
  SRC_DIR="${GOSITE_TMP_ROOT}/src"
  ok "Source downloaded."
}

[[ -f "${SRC_DIR}/main.sh" ]] || download_source

# --- privilege check (system installs only) ----------------------------------
# A user install writes only inside $HOME, so it never needs sudo. Escalation
# happens after the payload is on disk, so `curl | sudo bash` is never required.
SUDO=""
if [[ "${GOSITE_SYSTEM}" -eq 1 && "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || fatal "--system requires administrator privileges and sudo was not found."
  warn "Administrator privileges are required to write to ${SHARE_DIR}."
  SUDO="sudo"
  sudo -v || fatal "Could not obtain administrator privileges."
fi

# --- install -----------------------------------------------------------------
info "Installing gosite into ${SHARE_DIR}"
${SUDO} rm -rf "${SHARE_DIR}"
${SUDO} mkdir -p "${SHARE_DIR}"
${SUDO} cp -R "${SRC_DIR}" "${SHARE_DIR}/src"

# Every module must be readable; only the entrypoint needs to be executable.
${SUDO} find "${SHARE_DIR}" -type f -name '*.sh' -exec chmod 0644 {} +
${SUDO} find "${SHARE_DIR}" -type d -exec chmod 0755 {} +
${SUDO} chmod 0755 "${SHARE_DIR}/src/main.sh"
ok "Modules copied."

info "Linking ${SHARE_DIR}/src/main.sh -> ${BIN_DIR}/${BIN_NAME}"
${SUDO} mkdir -p "${BIN_DIR}"
${SUDO} ln -sfn "${SHARE_DIR}/src/main.sh" "${BIN_DIR}/${BIN_NAME}"
ok "Symlink created."

# --- verify ------------------------------------------------------------------
"${BIN_DIR}/${BIN_NAME}" version >/dev/null 2>&1 || fatal "Installed binary failed to run."

if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  warn "${BIN_DIR} is not in your PATH. Add this to your shell profile:"
  printf "\n    export PATH=\"%s:\$PATH\"\n\n" "${BIN_DIR}"
  case "${SHELL##*/}" in
    zsh)  printf "${DIM}    echo 'export PATH=\"%s:\$PATH\"' >> ~/.zshrc && source ~/.zshrc${NC}\n" "${BIN_DIR}" ;;
    bash) printf "${DIM}    echo 'export PATH=\"%s:\$PATH\"' >> ~/.bashrc && source ~/.bashrc${NC}\n" "${BIN_DIR}" ;;
  esac
else
  ok "gosite is on your PATH ($(command -v ${BIN_NAME} 2>/dev/null || echo "${BIN_DIR}/${BIN_NAME}"))"
fi

printf "\n${GREEN}Installation complete.${NC} Run '${BIN_NAME} doctor' to check your toolchain.\n"
printf "${DIM}Uninstall: rm -rf %s %s/%s${NC}\n" "${SHARE_DIR}" "${BIN_DIR}" "${BIN_NAME}"
