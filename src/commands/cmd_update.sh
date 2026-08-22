#!/usr/bin/env bash
#
# gosite update – integrity-checked self-update.
#
# Distribution model (decided in the harden-gosite-phased change): every
# version ships as a tagged GitHub Release carrying two assets:
#
#   gosite-<version>.tar.gz          the source tree (src/ at the repo root)
#   gosite-<version>.tar.gz.sha256   plain `shasum -a 256` output
#
# The updater defaults to the latest release and verifies the downloaded
# tarball against the published checksum BEFORE anything on disk is touched.
# Only then does it stage the new tree beside the installation, move the
# current tree aside as a backup, swap, and prove the new version actually
# runs. Any failure after the swap rolls the previous installation back.
#
# Branch refs (main, feature/*) have no published checksum: installing one
# requires the explicit --allow-unverified opt-in, announced with a loud
# warning. The repository is fixed in this file - GOSITE_REPO from the
# environment is deliberately ignored (and reported), and --repo is the only
# override, always named in the confirmation prompt.

readonly GOSITE_UPDATE_REPO_DEFAULT="Avanxo-Technology/gosite-cli"

cmd_update() {
  local ref="${GOSITE_REF:-}"          # empty = latest tagged release
  local repo="${GOSITE_UPDATE_REPO_DEFAULT}"
  local allow_unverified=0 check_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref)               ref="$2"; shift 2 ;;
      --repo)              repo="$2"; shift 2 ;;
      --allow-unverified)  allow_unverified=1; shift ;;
      --check)             check_only=1; shift ;;
      -y|--yes)            export GOSITE_ASSUME_YES=1; shift ;;
      -h|--help)
        cat <<USAGE
Usage: gosite update [flags]

Update gosite to the latest tagged release from GitHub, verifying the
download against the checksum published with that release. If anything goes
wrong after the swap starts, the previous installation is restored.

Flags:
  --ref <tag|branch>   Install a specific tag (checksum-verified) or branch
                       (requires --allow-unverified). Default: latest release
  --repo <owner/name>  Download from another repository (named in the prompt)
  --allow-unverified   Proceed without a published checksum (branches, or a
                       release missing its .sha256 asset); loud warning shown
  --check              Only report whether an update is available
  -y, --yes            Skip confirmation prompt
  -h, --help           Show this help
USAGE
        return 0
        ;;
      *) fatal "Unknown option: $1 (try 'gosite update --help')" ;;
    esac
  done

  # The environment never chooses the update source.
  if [[ -n "${GOSITE_REPO:-}" ]]; then
    warn "Ignoring GOSITE_REPO from the environment: the update source is fixed for integrity. Use --repo <owner>/<name> to choose a different repository explicitly."
  fi

  # --- locate current install -------------------------------------------------
  local share_dir prefix bin_dir
  share_dir="$(cd -P "${GOSITE_ROOT}/.." && pwd)"
  prefix="$(cd -P "${share_dir}/../.." && pwd)"
  bin_dir="${prefix}/bin"

  local current_version="${GOSITE_VERSION}"
  info "Current version: ${current_version}"

  # --- resolve target ---------------------------------------------------------
  # A tag with a published Release -> checksum-verified install. Anything
  # else (branch, tag without release) -> no checksum exists, so it can only
  # be installed with the explicit opt-out.
  local tag="" remote_version="" verified=1
  if ! tag="$(_update_release_tag "${repo}" "${ref}")"; then
    verified=0
    if [[ -z "${ref}" ]]; then
      fatal "No published release found in ${repo}. Publish a tagged Release carrying gosite-<version>.tar.gz and gosite-<version>.tar.gz.sha256 assets, or update from a branch explicitly: gosite update --ref <branch> --allow-unverified"
    fi
  fi

  if [[ "${verified}" -eq 1 ]]; then
    remote_version="${tag#v}"
    info "Latest release:  ${tag} (${remote_version})"
    if [[ "${current_version}" == "${remote_version}" ]]; then
      ok "Already up to date."
      return 0
    fi
  else
    info "Target: ${repo}@${ref} (no published checksum for this ref)"
  fi

  if [[ "${check_only}" -eq 1 ]]; then
    if [[ "${verified}" -eq 1 ]]; then
      warn "An update is available: ${current_version} -> ${remote_version}"
    else
      info "An update from ${repo}@${ref} is available (version known after download; needs --allow-unverified)."
    fi
    return 0
  fi

  # --- consent ----------------------------------------------------------------
  if [[ "${verified}" -eq 0 ]]; then
    if [[ "${allow_unverified}" -eq 1 ]]; then
      warn "!!! --allow-unverified: the archive from ${repo}@${ref} has NO published checksum and will NOT be integrity-checked. Proceed only if you trust this source. !!!"
    else
      fatal "Ref '${ref}' has no published release/checksum in ${repo}; refusing to install unverified. To proceed anyway: gosite update --ref ${ref} --allow-unverified"
    fi
  fi

  local prompt="Update gosite from ${current_version} to ${remote_version}?"
  if [[ "${repo}" != "${GOSITE_UPDATE_REPO_DEFAULT}" ]]; then
    prompt="Update gosite from ${current_version} to ${remote_version} from NON-DEFAULT repository ${repo}?"
  fi
  confirm "${prompt}" || { info "Aborted."; return 0; }

  # --- download + verify ------------------------------------------------------
  local tmp_root
  tmp_root="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_root}'" EXIT

  local tarball="${tmp_root}/gosite.tar.gz"

  if [[ "${verified}" -eq 1 ]]; then
    local base_url="https://github.com/${repo}/releases/download/${tag}"
    info "Downloading gosite-${remote_version}.tar.gz..."
    _update_fetch_to "${base_url}/gosite-${remote_version}.tar.gz" "${tarball}" \
      || fatal "Could not download the release tarball from ${base_url}."

    local published
    published="$(_update_fetch "${base_url}/gosite-${remote_version}.tar.gz.sha256" 2>/dev/null)" \
      || fatal "No published checksum for ${tag} (expected asset: gosite-${remote_version}.tar.gz.sha256); refusing to install unverified. To proceed anyway: gosite update --ref ${tag} --allow-unverified"
    published="$(printf '%s' "${published}" | awk 'NR==1{print $1}')"

    local actual_digest
    actual_digest="$(sha256_file "${tarball}")"
    if [[ "${actual_digest}" != "${published}" ]]; then
      fatal "Checksum mismatch: downloaded archive is ${actual_digest}, published checksum is ${published}. Installation untouched."
    fi
    ok "Checksum verified: ${actual_digest}"
  else
    info "Downloading ${repo}@${ref} (unverified)..."
    _update_fetch_to "https://api.github.com/repos/${repo}/tarball/${ref}" "${tarball}" \
      || fatal "Could not download ${repo}@${ref}."
  fi

  # --- validate archive -------------------------------------------------------
  info "Verifying archive layout..."
  mkdir -p "${tmp_root}/x"
  tar -xzf "${tarball}" -C "${tmp_root}/x" --strip-components=1 \
    || fatal "Archive is not a valid gzipped tar."

  [[ -f "${tmp_root}/x/src/main.sh" ]] \
    || fatal "Downloaded archive does not contain src/main.sh. Installation untouched."

  local extracted_version
  extracted_version="$(tr -d '[:space:]' < "${tmp_root}/x/src/VERSION" 2>/dev/null || true)"
  if [[ "${verified}" -eq 1 ]] && [[ "${extracted_version}" != "${remote_version}" ]]; then
    fatal "Downloaded archive version (${extracted_version:-none}) doesn't match expected (${remote_version}). Installation untouched."
  fi

  # --- determine privilege level ----------------------------------------------
  local sudo_cmd=""
  if [[ "${EUID}" -ne 0 && "${share_dir}" == /usr/local/* ]]; then
    command -v sudo >/dev/null 2>&1 || fatal "System install requires sudo."
    warn "Administrator privileges required to update ${share_dir}."
    sudo_cmd="sudo"
    sudo -v || fatal "Could not obtain administrator privileges."
  fi

  # --- stage, back up, swap (rollback on any failure) -------------------------
  info "Replacing installed files..."

  local stamp new_src backup
  stamp="$(date +%Y%m%d%H%M%S)"
  new_src="${share_dir}/src.new.$$"
  backup="${share_dir}/src.bak.${stamp}"

  # Stage the new tree beside the current one (same filesystem), with final
  # permissions already applied, so the swap itself is two renames.
  if ! ${sudo_cmd} cp -R "${tmp_root}/x/src" "${new_src}"; then
    fatal "Could not stage the new files; installation untouched."
  fi
  ${sudo_cmd} find "${new_src}" -type f -name '*.sh' -exec chmod 0644 {} +
  ${sudo_cmd} find "${new_src}" -type d -exec chmod 0755 {} +
  ${sudo_cmd} chmod 0755 "${new_src}/main.sh"

  if ! ${sudo_cmd} mv "${share_dir}/src" "${backup}"; then
    ${sudo_cmd} rm -rf "${new_src}"
    fatal "Could not back up the current installation; installation untouched."
  fi

  if ! ${sudo_cmd} mv "${new_src}" "${share_dir}/src"; then
    ${sudo_cmd} mv "${backup}" "${share_dir}/src" \
      || err "ROLLBACK FAILED: previous tree is still available at ${backup}"
    fatal "Staging the new files failed; previous installation restored."
  fi

  # The new version must actually run before the update is committed.
  local -a runner=("${bin_dir}/gosite")
  if [[ ! -x "${runner[0]}" ]]; then
    runner=(bash "${share_dir}/src/main.sh")
  fi
  local new_version=""
  new_version="$("${runner[@]}" version 2>/dev/null | sed 's/gosite //')" || new_version=""

  local version_ok=1
  [[ -n "${new_version}" ]] || version_ok=0
  if [[ "${verified}" -eq 1 && "${new_version}" != "${remote_version}" ]]; then
    version_ok=0
  fi

  if [[ "${version_ok}" -eq 0 ]]; then
    ${sudo_cmd} rm -rf "${share_dir}/src"
    ${sudo_cmd} mv "${backup}" "${share_dir}/src" \
      || err "ROLLBACK FAILED: previous tree is still available at ${backup}"
    fatal "Updated binary failed to run${new_version:+ (reported version: ${new_version})}; previous installation restored."
  fi

  # Commit: drop the backup; the EXIT trap removes the scratch tree.
  ${sudo_cmd} rm -rf "${backup}"
  ok "Done. Updated gosite ${current_version} -> ${new_version}"
}

# --- helpers -------------------------------------------------------------------

_update_fetch() {   # <url> -> stdout
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    return 127
  fi
}

_update_fetch_to() { # <url> <file>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    return 127
  fi
}

# Resolves a ref to its Release tag. Empty ref = latest release. Prints the
# tag name; returns 1 when no Release exists for the ref.
_update_release_tag() {
  local repo="$1" want="$2" url json tag
  if [[ -z "${want}" ]]; then
    url="https://api.github.com/repos/${repo}/releases/latest"
  else
    url="https://api.github.com/repos/${repo}/releases/tags/${want}"
  fi

  json="$(_update_fetch "${url}" 2>/dev/null)" || return 1

  if command -v python3 >/dev/null 2>&1; then
    tag="$(printf '%s' "${json}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
  fi
  if [[ -z "${tag}" ]]; then
    tag="$(printf '%s' "${json}" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
  fi
  [[ -n "${tag}" ]] || return 1
  printf '%s\n' "${tag}"
}
