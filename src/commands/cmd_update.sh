#!/usr/bin/env bash
#
# gosite update – pull the latest source from GitHub and replace the
# installed modules in-place.
#

cmd_update() {
  local ref="${GOSITE_REF:-main}"
  local check_only=0
  local repo="${GOSITE_REPO:-Avanxo-Technology/gosite-cli}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref)    ref="$2"; shift 2 ;;
      --check)  check_only=1 ;;
      -h|--help)
        cat <<USAGE
Usage: gosite update [flags]

Update gosite to the latest version from GitHub.

Flags:
  --ref <branch|tag>   Download a specific branch or tag (default: main)
  --check              Only check if an update is available
  -y, --yes            Skip confirmation prompt
  -v, --verbose        Verbose output
  -h, --help           Show this help
USAGE
        return 0
        ;;
      *) fatal "Unknown option: $1 (try 'gosite update --help')" ;;
    esac
  done

  # --- locate current install -------------------------------------------------
  local share_dir bin_dir
  share_dir="$(cd -P "${GOSITE_ROOT}/.." && pwd)"
  bin_dir="$(cd -P "${share_dir}/../bin" && pwd)"

  local current_version="${GOSITE_VERSION}"
  info "Current version: ${current_version}"

  # --- fetch remote version ---------------------------------------------------
  local remote_version=""
  local raw_url="https://raw.githubusercontent.com/${repo}/${ref}/src/main.sh"

  info "Checking latest version from ${repo}@${ref}..."

  if command -v curl >/dev/null 2>&1; then
    remote_version="$(curl -fsSL "${raw_url}" 2>/dev/null \
      | grep -m1 '^readonly GOSITE_VERSION=' \
      | sed 's/.*"\(.*\)".*/\1/')" || true
  elif command -v wget >/dev/null 2>&1; then
    remote_version="$(wget -qO- "${raw_url}" 2>/dev/null \
      | grep -m1 '^readonly GOSITE_VERSION=' \
      | sed 's/.*"\(.*\)".*/\1/')" || true
  else
    fatal "Neither curl nor wget is available; cannot check for updates."
  fi

  if [[ -z "${remote_version}" ]]; then
    fatal "Could not fetch remote version from ${repo}@${ref}."
  fi

  info "Latest version:  ${remote_version}"

  if [[ "${current_version}" == "${remote_version}" ]]; then
    ok "Already up to date."
    return 0
  fi

  if [[ "${check_only}" -eq 1 ]]; then
    warn "An update is available: ${current_version} -> ${remote_version}"
    return 0
  fi

  # --- confirm ----------------------------------------------------------------
  confirm "Update gosite from ${current_version} to ${remote_version}?" || {
    info "Aborted."
    return 0
  }

  # --- download tarball -------------------------------------------------------
  local tar_url="https://codeload.github.com/${repo}/tar.gz/${ref}"
  local tmp_root

  tmp_root="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_root}'" EXIT

  info "Downloading ${repo}@${ref}..."

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${tar_url}" | tar -xz -C "${tmp_root}" --strip-components=1
  else
    wget -qO- "${tar_url}" | tar -xz -C "${tmp_root}" --strip-components=1
  fi

  [[ -f "${tmp_root}/src/main.sh" ]] || fatal "Downloaded archive does not contain src/main.sh."

  # --- determine privilege level ----------------------------------------------
  local sudo_cmd=""
  if [[ "${EUID}" -ne 0 && "${share_dir}" == /usr/local/* ]]; then
    command -v sudo >/dev/null 2>&1 || fatal "System install requires sudo."
    warn "Administrator privileges required to update ${share_dir}."
    sudo_cmd="sudo"
    sudo -v || fatal "Could not obtain administrator privileges."
  fi

  # --- replace installed files ------------------------------------------------
  info "Replacing installed files..."
  ${sudo_cmd} rm -rf "${share_dir}/src"
  ${sudo_cmd} cp -R "${tmp_root}/src" "${share_dir}/src"

  ${sudo_cmd} find "${share_dir}" -type f -name '*.sh' -exec chmod 0644 {} +
  ${sudo_cmd} find "${share_dir}" -type d -exec chmod 0755 {} +
  ${sudo_cmd} chmod 0755 "${share_dir}/src/main.sh"
  ok "Files replaced."

  # --- verify -----------------------------------------------------------------
  "${bin_dir}/gosite" version >/dev/null 2>&1 || fatal "Updated binary failed to run."

  local new_version
  new_version="$("${bin_dir}/gosite" version 2>/dev/null | sed 's/gosite //')"

  ok "Done. Updated gosite ${current_version} -> ${new_version}"
}
