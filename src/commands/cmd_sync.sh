#!/usr/bin/env bash
#
# gosite sync [project] [flags]
#
# Re-applies gosite's templates to an already-scaffolded project. This is how an
# existing site picks up updates to gosite: the compose files, the Cockpit
# config, the addon library and the .env template are all single-sourced in
# src/lib/templates.sh (and src/addons/), so `create` writes them fresh and
# `sync` re-renders the same sources into a project without clobbering work.
#
# Two invariants keep that promise honest:
#
#   1. docker-compose.prod.yml is the project's file, not gosite's. No sync
#      mode writes it. Drift is reported; only the explicit
#      `--compose-prod --force` re-renders it, and only after making a
#      timestamped backup beside it.
#
#   2. Every other managed file is guarded by .gosite/manifest.tsv: if its hash
#      still matches what gosite last wrote, it is refreshed; if it differs,
#      someone edited it by hand and it is preserved and reported (unless
#      --force). Files that vanished are restored from the template.
#
# The project is resolved by name or from the current directory, then matched
# against the values stored in its .gosite.env marker - sync never guesses.
#

cmd_sync() {
  local do_compose=0 do_compose_prod=0 do_force=0 do_addons=0 do_env=0 do_build=0 do_list=0 do_report=0 strict=0 name=""
  local ADDONS=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compose)       do_compose=1; shift ;;
      --compose-prod)  do_compose_prod=1; shift ;;
      --force)         do_force=1; shift ;;
      --addons)        do_addons=1; shift; [[ -n "${1:-}" && "${1}" != -* ]] && ADDONS="$1" && shift ;;
      --env)           do_env=1; shift ;;
      --build)         do_build=1; shift ;;
      --report)        do_report=1; shift ;;
      --strict)        strict=1; shift ;;
      -h|--help)
        cat <<USAGE
Usage: gosite sync [project] [flags]

Re-apply gosite's templates to an existing project without overwriting
your work. With no flags, syncs compose files, addons and the .env template.

docker-compose.prod.yml is yours: no sync mode ever writes it. Drift is
reported; the only way to re-render it is the explicit
'--compose-prod --force' below, which backs the file up first.

Flags:
  --compose       Re-render docker-compose.yml, cockpit/config.php and the
                  build files from the current templates
  --addons        Refresh every Cockpit addon present in the project from
                  gosite's addon library (built-ins + any optional ones),
                  or install the named addons: --addons "Forms Replica"
  --env           Add any keys missing from the .env template to the project
                  .env (never overwrites existing values or secrets)
  --report        Show how the project diverges from the current templates,
                 per managed file, without writing anything
  --strict        With --report: exit non-zero when drift is found, so the
                 report can gate a pipeline
  --compose-prod  Show the structural drift of docker-compose.prod.yml
                  against the current template (read-only)
  --force         With --compose-prod: re-render docker-compose.prod.yml
                  (a timestamped .bak copy is made first and its path is
                  printed). With --compose/--addons: also refresh managed
                  files you have modified locally
  --build         After syncing, rebuild the local app/CMS images
  --list-addons   List the addons available in gosite's library and exit
  -h, --help     Show this help
USAGE
        return 0
        ;;
      *) name="$1"; shift ;;
    esac
  done

  if [[ "${do_list}" -eq 1 ]]; then
    _sync_list_addons
    return 0
  fi

  require_dependencies
  source "${GOSITE_ROOT}/lib/templates.sh"
  source "${GOSITE_ROOT}/lib/manifest.sh"

  local dir; dir="$(resolve_project_dir "${name}")"

  if [[ "${do_report}" -eq 1 ]]; then
    _sync_report "${dir}" "${strict}"
    return $?
  fi

  # No action flag -> sync everything that is safe to re-apply.
  [[ "${do_compose}" -eq 1 || "${do_addons}" -eq 1 || "${do_env}" -eq 1 || "${do_compose_prod}" -eq 1 ]] || {
    do_compose=1; do_addons=1; do_env=1
  }

  # First sync on a project scaffolded before manifests existed: adopt the
  # current contents as baseline and write nothing else on this pass - the
  # user sees the drift report before anything is applied (design D5).
  if ! manifest_exists "${dir}"; then
    manifest_ensure_adopted "${dir}"
    info "Showing the drift report; no project file has been written on this first pass."
    _sync_report "${dir}" 0
    ok "Run 'gosite sync $(basename "${dir}")' again to refresh files nobody has touched."
    return 0
  fi

  info "Syncing gosite templates into ${dir}"

  # Render the expected state once into a scratch tree; every write below
  # copies out of it behind the manifest guard.
  GOSITE_SYNC_TMP="$(mktemp -d)"
  trap 'rm -rf "${GOSITE_SYNC_TMP}"' RETURN
  local exp="${GOSITE_SYNC_TMP}/expected"
  _render_expected_tree "${exp}" "${dir}"

  if [[ "${do_compose}" -eq 1 ]]; then
    _sync_apply_expected "${dir}" "${exp}" "${do_force}" \
      docker-compose.yml cockpit/config.php .air.toml .dockerignore .env.example "deploy/"
  fi
  if [[ "${do_addons}" -eq 1 ]]; then
    _sync_addons "${dir}" "${ADDONS}" "${exp}" "${do_force}"
  fi
  if [[ "${do_env}" -eq 1 ]]; then
    _sync_env "${dir}"
    _sync_env_minio_credentials "${dir}"
    printf '%s\n' ".env" | manifest_update "${dir}"
  fi
  if [[ "${do_compose_prod}" -eq 1 ]]; then
    if [[ "${do_force}" -eq 1 ]]; then
      _sync_compose_prod_force "${dir}" "${exp}"
    else
      info "docker-compose.prod.yml drift (re-render only with --compose-prod --force):"
      _report_compose_prod_diff "${dir}" "${exp}/docker-compose.prod.yml"
    fi
  fi

  if [[ "${do_build}" -eq 1 ]]; then
    info "Rebuilding images for '${GOSITE_PROJECT:-$(basename "${dir}")}'"
    compose -p "$(basename "${dir}")" -f "${dir}/docker-compose.yml" --project-directory "${dir}" build
  fi

  ok "Sync complete. Start the project with 'gosite start $(basename "${dir}")'"
}

# Applies the expected tree to the project, file by file, behind the manifest
# guard (design D5):
#   - absent file            -> restored from the template
#   - matches the recorded
#     manifest hash          -> refreshed from the current template
#   - differs from the
#     recorded hash          -> preserved and reported (unless --force)
# Only the path prefixes passed as arguments are considered; files that
# already match the current template are not rewritten. Every file actually
# written gets its manifest entry refreshed. The iteration universe is the
# union of the managed files and the rendered tree, so files the current
# templates newly ship (an old scaffold without deploy/, say) are installed
# additively - adding a file nobody has edited loses nothing.
_sync_apply_expected() {
  local dir="$1" exp="$2" force="$3"; shift 3
  local -a prefixes=("$@") written=()
  local rel dest src current recorded

  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    # Never through this path: the merge-only .env, the force-gated prod
    # compose and the identity marker itself.
    [[ "${rel}" == ".env" || "${rel}" == "docker-compose.prod.yml" || "${rel}" == "${GOSITE_MARKER}" ]] && continue
    _managed_matches_any "${rel}" "${prefixes[@]}" || continue

    src="${exp}/${rel}"
    [[ -f "${src}" ]] || continue    # nothing rendered for it (e.g. optional addon not present)
    dest="${dir}/${rel}"

    if [[ ! -f "${dest}" ]]; then
      mkdir -p "$(dirname "${dest}")"
      cp "${src}" "${dest}"
      written+=("${rel}")
      info "Restored ${rel} from the current template"
      continue
    fi

    current="$(sha256_file "${dest}")"
    if [[ "${current}" == "$(sha256_file "${src}")" ]]; then
      continue    # already matches the current template
    fi

    recorded="$(manifest_get "${dir}" "${rel}")"
    if [[ -n "${recorded}" && "${current}" != "${recorded}" ]]; then
      if [[ "${force}" -ne 1 ]]; then
        warn "Preserved ${rel} (locally modified; re-apply with: gosite sync --force)"
        continue
      fi
      warn "Force-refreshed ${rel} (local changes discarded)"
    fi

    cp "${src}" "${dest}"
    written+=("${rel}")
  done < <( { managed_files "${dir}"; { cd "${exp}" && find . -type f | sed "s|^\./||"; } 2>/dev/null; } | LC_ALL=C sort -u )

  if [[ ${#written[@]} -gt 0 ]]; then
    printf '%s\n' "${written[@]}" | manifest_update "${dir}"
    ok "Refreshed ${#written[@]} managed file(s)"
  fi
}

_managed_matches_any() {
  local rel="$1" pat
  shift
  for pat in "$@"; do
    if [[ "${pat}" == */ ]]; then
      [[ "${rel}" == "${pat}"* ]] && return 0
    else
      [[ "${rel}" == "${pat}" ]] && return 0
    fi
  done
  return 1
}

# The ONLY write path for docker-compose.prod.yml (design D6): explicit
# --compose-prod --force. Backs the existing file up beside it (timestamped,
# never deleted), re-renders from the current template and prints the backup
# path.
_sync_compose_prod_force() {
  local dir="$1" exp="$2"
  local dest="${dir}/docker-compose.prod.yml" src="${exp}/docker-compose.prod.yml"
  [[ -f "${src}" ]] || { warn "No production compose template was rendered."; return 1; }

  if [[ -f "${dest}" ]]; then
    local bak
    bak="${dest}.$(date +%Y%m%d%H%M%S).bak"
    cp -p "${dest}" "${bak}"
    ok "Backed up docker-compose.prod.yml -> ${bak}"
  fi

  cp "${src}" "${dest}"
  printf '%s\n' "docker-compose.prod.yml" | manifest_update "${dir}"
  ok "Re-rendered docker-compose.prod.yml from the current template"
}

# Refreshes every addon the project already has (built-ins are always copied,
# plus any optional addon directory present), behind the same manifest guard
# as the compose files. Then clears the CMS module cache so Cockpit
# re-registers the modules.
_sync_addons() {
  local dir="$1" want="${2:-}" exp="$3" force="${4:-0}"
  local target="${dir}/cockpit/addons" name

  if [[ -n "${want}" ]]; then
    _install_addons "${dir}" "${want}"
    # Newly installed addons join the manifest; other entries are preserved.
    local one
    for one in ${want}; do
      [[ -d "${target}/${one}" ]] || continue
      find "${target}/${one}" -type f | sed "s|^${dir}/||" | manifest_update "${dir}"
    done
  else
    _sync_apply_expected "${dir}" "${exp}" "${force}" "cockpit/addons/"
  fi

  # Cockpit caches registered addons; without clearing it, a refresh is
  # invisible until the cache expires or is wiped by hand.
  rm -f "${dir}/cockpit-storage/cache/modules.cache.php" \
        "${dir}/cockpit-storage/cache/addons.cache.php"
}

# Adds any key present in the .env template that is missing from the project
# .env. Existing values - including secrets - are never touched. The template
# is generated into a temp dir so the project's .gosite.env marker is not
# rewritten.
_sync_env() {
  local dir="$1" envfile="${1}/.env" tmp
  # Global on purpose: bash tears down locals before a RETURN trap runs, so a
  # `local tmp` referenced by the trap would be unbound under `set -u`.
  GOSITE_SYNC_TMP="$(mktemp -d)"
  trap 'rm -rf "${GOSITE_SYNC_TMP}"' RETURN
  tmp="${GOSITE_SYNC_TMP}"
  load_project_render_vars "${dir}"
  _write_env_files "${tmp}"
  render_placeholders "${tmp}/.env"

  if [[ ! -f "${envfile}" ]]; then
    cp "${tmp}/.env" "${envfile}"
    ok "No .env found; created it from the template"
    return
  fi

  local line key added=0 have=""
  while IFS= read -r line; do
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && have="${have} ${line%%=*}"
  done < "${envfile}"

  while IFS= read -r line; do
    [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    case " ${have} " in
      *" ${key} "*) continue ;;
    esac
    [[ "${added}" -gt 0 ]] || printf '\n' >> "${envfile}"
    printf '%s\n' "${line}" >> "${envfile}"
    added=$((added + 1))
  done < "${tmp}/.env"

  if [[ "${added}" -gt 0 ]]; then
    ok "Added ${added} key(s) to .env"
  else
    info ".env already has every key from the template"
  fi
}

# Projects scaffolded before gosite generated per-installation MinIO
# credentials carry the fixed minioadmin literals. When the shared infra now
# runs under real credentials, replace those two literals in place so uploads
# keep working. Deliberate non-minioadmin values are left alone.
_sync_env_minio_credentials() {
  local envfile="$1"
  [[ -f "${envfile}" ]] || return 0
  resolve_minio_credentials
  [[ "${GOSITE_MINIO_LEGACY:-0}" -eq 1 ]] && return 0   # infra still on minioadmin: nothing to migrate

  grep -q '^S3_KEY=minioadmin$\|^S3_SECRET=minioadmin$' "${envfile}" || return 0

  local tmp="${envfile}.gosite-sync.$$"
  awk -v key="${MINIO_ROOT_USER}" -v sec="${MINIO_ROOT_PASSWORD}" '
    /^S3_KEY=/     { print "S3_KEY=" key; next }
    /^S3_SECRET=/  { print "S3_SECRET=" sec; next }
    { print }
  ' "${envfile}" > "${tmp}" && mv "${tmp}" "${envfile}"

  ok "Migrated MinIO credentials in .env from minioadmin to this installation's generated pair"
}

_sync_list_addons() {
  info "Addons in gosite's library:"
  for d in "${GOSITE_ROOT}/addons"/*/; do
    [[ -d "${d}" ]] || continue
    local name; name="$(basename "${d}")"
    case "${name}" in
      AssetsUpload|ModelManager|CloudStorage|AssetPathFix|CachePurge) printf '  %-16s %s\n' "${name}" "(built-in, always installed)" ;;
      *) printf '  %-16s %s\n' "${name}" "(optional, opt-in via --addons)" ;;
    esac
  done
  printf '\nInstall an optional addon with: gosite sync --addons <name> (then start the project)\n'
}

# --- drift report -------------------------------------------------------------
# Renders what the current templates WOULD produce into a scratch directory and
# compares it against the project, per managed file. Nothing inside the project
# is created, modified or deleted: this is a pure read.

# Renders the expected state of every managed file into ${1} (a scratch dir),
# mirroring what _sync_compose/_sync_addons/_sync_env would write.
_render_expected_tree() {
  local exp="$1" dir="$2"
  load_project_render_vars "${dir}"
  mkdir -p "${exp}/cockpit/addons"

  _write_compose_dev "${exp}"
  render_placeholders "${exp}/docker-compose.yml"

  # _write_compose_prod also emits cockpit/config.php.
  _write_compose_prod "${exp}"
  render_placeholders "${exp}/docker-compose.prod.yml"
  render_placeholders "${exp}/cockpit/config.php"

  _write_env_files "${exp}"
  render_placeholders "${exp}/.env"
  render_placeholders "${exp}/.env.example"

  _write_air_config "${exp}"
  _write_dockerfiles "${exp}"

  _write_builtin_addons "${exp}"
  # Optional addons: expected content exists only for those the project has.
  local name
  for name in "$2"/cockpit/addons/*/; do
    [[ -d "${name}" ]] || continue
    name="$(basename "${name}")"
    [[ -d "${GOSITE_ROOT}/addons/${name}" ]] || continue   # no longer in library -> left as-is by sync too
    mkdir -p "${exp}/cockpit/addons/${name}"
    cp -R "${GOSITE_ROOT}/addons/${name}/." "${exp}/cockpit/addons/${name}/"
  done
}

_sync_report() {
  local dir="$1" strict="${2:-0}"
  load_project_render_vars "${dir}"

  # Scratch tree for the expected state. Global on purpose: bash tears down
  # locals before a RETURN trap runs, so a `local tmp` referenced by the trap
  # would be unbound under `set -u` (same pattern as _sync_env).
  GOSITE_REPORT_TMP="$(mktemp -d)"
  trap 'rm -rf "${GOSITE_REPORT_TMP}"' RETURN
  _render_expected_tree "${GOSITE_REPORT_TMP}/expected" "${dir}"

  info "Drift report for '${GOSITE_PROJECT}' (${dir})"

  if manifest_exists "${dir}"; then
    debug "Manifest present: $(manifest_path "${dir}")"
  else
    warn "No manifest yet: run 'gosite sync ${GOSITE_PROJECT}' once to adopt one (nothing is overwritten on that first pass)."
  fi

  local ident=0 outdated=0 modified=0 missing=0 env_gap=0 rel actual expected recorded
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    expected="${GOSITE_REPORT_TMP}/expected/${rel}"

    if [[ "${rel}" == ".env" ]]; then
      # Merge-only file: values are the user's; only the key set is gosite's.
      local env_missing
      env_missing="$(comm -13 \
        <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${dir}/.env" 2>/dev/null | sort -u) \
        <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${expected}" 2>/dev/null | sort -u))"
      if [[ -n "${env_missing}" ]]; then
        printf "  ${C_YELLOW}missing-keys${C_NC} %s ${C_DIM}(%s; 'gosite sync --env' adds them)${C_NC}\n" \
          ".env" "$(echo "${env_missing}" | tr -d '=' | tr '\n' ' ')"
        env_gap=1
      else
        ident=$(( ident + 1 ))
      fi
      continue
    fi

    actual="$(sha256_file "${dir}/${rel}" 2>/dev/null || true)"

    if [[ ! -f "${dir}/${rel}" ]]; then
      printf "  ${C_RED}missing${C_NC}    %s\n" "${rel}"
      missing=$(( missing + 1 ))
      continue
    fi

    if [[ -f "${expected}" ]] && [[ "${actual}" == "$(sha256_file "${expected}")" ]]; then
      ident=$(( ident + 1 ))
      continue
    fi

    recorded="$(manifest_get "${dir}" "${rel}")"
    if [[ -z "${recorded}" || "${actual}" != "${recorded}" ]]; then
      printf "  ${C_YELLOW}modified${C_NC}   %s ${C_DIM}(hand-edited since gosite wrote it)${C_NC}\n" "${rel}"
      modified=$(( modified + 1 ))
    else
      printf "  ${C_BLUE}outdated${C_NC}   %s ${C_DIM}(untouched, but the template moved on)${C_NC}\n" "${rel}"
      outdated=$(( outdated + 1 ))
    fi
  done < <(managed_files "${dir}")

  local prod_expected="${GOSITE_REPORT_TMP}/expected/docker-compose.prod.yml"
  _report_compose_prod_diff "${dir}" "${prod_expected}"

  if (( ident > 0 )); then
    ok "${ident} managed file(s) identical to the current templates."
  fi

  if (( modified + outdated + missing + env_gap == 0 )) \
     && _compose_prod_matches "${dir}" "${prod_expected}"; then
    ok "'${GOSITE_PROJECT}' is up to date with gosite's templates."
    return 0
  fi

  printf "\nApply changes with: gosite sync %s\n" "${GOSITE_PROJECT}"
  printf "${C_DIM}(docker-compose.prod.yml is never written by a normal sync; see 'gosite sync --help')${C_NC}\n"

  if [[ "${strict}" -eq 1 ]]; then
    err "Drift detected (modified=${modified} outdated=${outdated} missing=${missing} env-gaps=${env_gap}); exiting non-zero (--strict)."
    exit 2
  fi
  return 0
}

# Structural comparison of the production compose against what the current
# template renders. With yq (mikefarah v4): flatten both documents to leaf
# "path=value" pairs and diff them - key order and comments are not drift.
# Without yq: degrade to a normalized textual comparison and say so.
_report_compose_prod_diff() {
  # Split `local`s: bash 3.2 expands every word of one `local` before any
  # assignment lands, so "${dir}" in the same statement would be unbound.
  local dir="$1" expected="$2"
  local project="${dir}/docker-compose.prod.yml"
  [[ -f "${project}" && -f "${expected}" ]] || return 0
  [[ -s "${project}" || -s "${expected}" ]] || return 0

  printf "\n${C_BOLD}docker-compose.prod.yml comparison${C_NC}\n"

  if command -v yq >/dev/null 2>&1; then
    local diffout
    diffout="$(_compare_yaml_flattened "${expected}" "${project}")"
    if [[ -n "${diffout}" ]]; then
      printf '%s\n' "${diffout}"
    else
      ok "No structural differences against the current template."
    fi
  else
    warn "yq not found - falling back to a normalized textual comparison (less precise: reformatting may look like drift). Install yq for a structural diff."
    if ! diff -u \
          <(_text_normalize "${expected}") \
          <(_text_normalize "${project}") | grep -v '^---\|^+++' ; then
      ok "No textual differences after normalization."
    fi
  fi
}

# Exit-status twin of the comparison above: 0 when the project's production
# compose is structurally equivalent to the current template, 1 when it is
# not (or when either file is missing).
_compose_prod_matches() {
  local dir="$1" expected="$2"
  local project="${dir}/docker-compose.prod.yml"
  [[ -f "${project}" && -f "${expected}" ]] || return 1
  if command -v yq >/dev/null 2>&1; then
    local t p
    t="$(_yaml_flatten "${expected}")"
    p="$(_yaml_flatten "${project}")"
    [[ "${t}" == "${p}" ]] && return 0
    return 1
  fi
  diff -q <(_text_normalize "${expected}") <(_text_normalize "${project}") >/dev/null 2>&1
}

_yaml_flatten() {
  # "path<TAB>value" per leaf scalar, sorted, so the comparison can join on
  # the key path regardless of how the documents order or format their keys.
  yq e '.. | select(kind != "map" and kind != "seq") | (path | map(tostring) | join(".")) as $p | "\($p)\t\(.)"' "$1" | LC_ALL=C sort
}

_text_normalize() {
  sed -e 's/#.*//' -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' "$1" | grep -v '^$' | LC_ALL=C sort
}

_compare_yaml_flattened() {
  local template="$1" project="$2" tmpd
  tmpd="$(mktemp -d)"
  _yaml_flatten "${template}" > "${tmpd}/template.tsv"
  _yaml_flatten "${project}" > "${tmpd}/project.tsv"

  # Join both flattened views on the key path:
  #   ~ value differs between template and project
  #   ! path only in the project (project-local)
  #   + path only in the template (the template would add it)
  awk -F'\t' '
    NR==FNR { tpl[$1]=$2; next }
    ($1 in tpl) {
      if (tpl[$1] != $2)
        printf "  ~ %s: template=%s project=%s\n", $1, tpl[$1], $2
      delete tpl[$1]; next
    }
    { printf "  ! %s: %s (only in your project)\n", $1, $2 }
    END { for (k in tpl) printf "  + %s: %s (template adds)\n", k, tpl[k] }
  ' "${tmpd}/template.tsv" "${tmpd}/project.tsv"

  rm -rf "${tmpd}"
}
