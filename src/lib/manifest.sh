#!/usr/bin/env bash
#
# Per-project manifest of gosite-managed files: ".gosite/manifest.tsv".
#
# One "<relpath>\t<sha256>\t<gosite version>" row per managed file, recorded
# when gosite writes it. The manifest is what lets sync tell "gosite wrote this
# and nobody touched it" (safe to refresh) apart from "someone edited this by
# hand" (preserve and report). Projects scaffolded before manifests existed
# adopt one from their current contents on their first post-upgrade sync -
# deliberately without writing any template file in that first pass.
#

manifest_path() {
  printf '%s\n' "$1/.gosite/manifest.tsv"
}

manifest_exists() {
  [[ -f "$(manifest_path "$1")" ]]
}

# Every relative path sync manages: files rendered from templates plus the
# addon library copied into cockpit/addons/. The set is the union of what is
# on disk and what the manifest still records - so a deleted file keeps being
# tracked (and reported missing) instead of silently dropping out of the
# managed universe.
# Relative paths under internal/ and static/ that the template tree provides -
# the base tree, both styling flavors, and every addon overlay. Printed one per
# line; callers filter to what the project actually has.
_managed_template_paths() {
  local root="${GOSITE_ROOT}/templates" base

  [[ -d "${root}" ]] || return 0

  for base in "${root}" "${root}"/flavors/* "${root}"/addons/*/ "${root}"/addons/*/flavors/*; do
    [[ -d "${base}" ]] || continue
    ( cd "${base}" 2>/dev/null && find internal static -type f 2>/dev/null | sed 's|^\./||' ) || true
  done
}

managed_files() {
  local dir="$1" f mpath
  {
    printf '%s\n' \
      docker-compose.yml \
      docker-compose.prod.yml \
      cockpit/config.php \
      .env \
      .env.example \
      .air.toml \
      .dockerignore

    if [[ -d "${dir}/deploy" ]]; then
      for f in "${dir}/deploy"/*; do
        [[ -f "${f}" ]] && printf 'deploy/%s\n' "$(basename "${f}")"
      done
    fi

    if [[ -d "${dir}/cockpit/addons" ]]; then
      while IFS= read -r f; do
        printf '%s\n' "${f#"${dir}"/}"
      done < <(find "${dir}/cockpit/addons" -type f | sort)
    fi

    # The application sources gosite ships.
    #
    # Derived from the template tree rather than listed here: a hardcoded list
    # is what caused this to miss internal/ entirely once `sync --app` started
    # writing there, so `create` recorded nothing under it and every one of
    # those files looked unmanaged. A project could then have its own work
    # silently overwritten, or - worse - end up with some files refreshed and
    # others preserved, and not compile.
    #
    # Only paths gosite actually ships are listed, so a project's own handlers,
    # pages and images stay out of the manifest and out of sync's way.
    _managed_template_paths

    # Entries recorded by an earlier write cover files that have since been
    # deleted from the project.
    mpath="$(manifest_path "${dir}")"
    if [[ -f "${mpath}" ]]; then
      awk -F'\t' 'NF >= 2 { print $1 }' "${mpath}"
    fi
  } | LC_ALL=C sort -u
}

manifest_get() {
  local dir="$1" rel="$2"
  [[ -f "$(manifest_path "${dir}")" ]] || return 0
  awk -F'\t' -v p="${rel}" '$1 == p { print $2; exit }' "$(manifest_path "${dir}")"
}

# Writes the manifest from the CURRENT contents of every managed file present.
# Files that do not exist are skipped (adopted projects may lack optional ones).
# The only thing this ever creates is .gosite/manifest.tsv itself.
manifest_write_from_dir() {
  local dir="$1" mpath rel hash count=0 tmp
  mkdir -p "${dir}/.gosite"
  tmp="$(mktemp "${dir}/.gosite/.manifest.XXXXXX")"
  : > "${tmp}"
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    [[ -f "${dir}/${rel}" ]] || continue
    hash="$(sha256_file "${dir}/${rel}")"
    printf '%s\t%s\t%s\n' "${rel}" "${hash}" "${GOSITE_VERSION}" >> "${tmp}"
    count=$(( count + 1 ))
  done < <(managed_files "${dir}")
  mv "${tmp}" "$(manifest_path "${dir}")"
  debug "Manifest written (${count} entries): $(manifest_path "${dir}")"
}

# First sync after upgrading from a pre-manifest scaffold: adopt whatever is on
# disk as the baseline so nothing is overwritten during that first run, and the
# modified-vs-fresh distinction works normally from then on. Only the new
# manifest appears; no project file is touched.
manifest_ensure_adopted() {
  local dir="$1"
  manifest_exists "${dir}" && return 0
  info "No manifest found (.gosite/manifest.tsv); adopting current files as baseline - nothing will be overwritten on this first pass"
  manifest_write_from_dir "${dir}"
  ok "Adopted $(awk 'END { print NR }' "$(manifest_path "${dir}")") managed files into a new manifest"
}

# Updates the manifest entries for the relative paths read on stdin to the
# current content of those files, leaving every other entry untouched. This is
# how sync records what it just wrote: entries for preserved (hand-edited)
# files keep the hash of what gosite last wrote, not the local edits.
# Drops one entry from the manifest, for a file gosite has removed. Without
# this the entry lingers and the file keeps being reported as managed - and,
# worse, a later sync would see it "missing" and restore it.
manifest_forget() {
  local dir="$1" rel="$2"
  manifest_exists "${dir}" || return 0
  with_lock "$(manifest_path "${dir}")" _manifest_forget_locked "${dir}" "${rel}"
}

_manifest_forget_locked() {
  local dir="$1" rel="$2" file tmp
  file="$(manifest_path "${dir}")"
  [[ -f "${file}" ]] || return 0
  tmp="$(mktemp "$(dirname "${file}")/.gosite.XXXXXX")"
  grep -v -F -e "${rel}	" "${file}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${file}"
}

manifest_update() {
  local dir="$1" rel
  local -a rels=()
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] && rels+=("${rel}")
  done
  [[ ${#rels[@]} -gt 0 ]] || return 0
  with_lock "$(manifest_path "${dir}")" _manifest_update_locked "${dir}" "${rels[@]}"
}

_manifest_update_locked() {
  local dir="$1"; shift
  local mpath; mpath="$(manifest_path "${dir}")"
  if [[ ! -f "${mpath}" ]]; then
    manifest_write_from_dir "${dir}"
    return 0
  fi

  local tmp
  tmp="$(mktemp "$(dirname "${mpath}")/.gosite.XXXXXX")"
  # Keep every entry except the ones being refreshed...
  awk -v upd="$*" -F'\t' '
    BEGIN { n = split(upd, u, " "); for (i = 1; i <= n; i++) drop[u[i]] = 1 }
    !($1 in drop) { print }
  ' "${mpath}" > "${tmp}"
  # ...then re-record the refreshed ones from their current content.
  local rel
  for rel in "$@"; do
    [[ -f "${dir}/${rel}" ]] || continue
    printf '%s\t%s\t%s\n' "${rel}" "$(sha256_file "${dir}/${rel}")" "${GOSITE_VERSION}" >> "${tmp}"
  done
  sort -o "${tmp}" "${tmp}"
  mv "${tmp}" "${mpath}"
}
