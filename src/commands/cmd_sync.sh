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
# The project is resolved by name or from the current directory, then matched
# against the values stored in its .gosite.env marker - sync never guesses.
#

cmd_sync() {
  local do_compose=0 do_addons=0 do_env=0 do_build=0 do_list=0 name=""
  local ADDONS=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compose)      do_compose=1; shift ;;
      --addons)       do_addons=1; shift; [[ -n "${1:-}" && "${1}" != -* ]] && ADDONS="$1" && shift ;;
      --env)          do_env=1; shift ;;
      --build)        do_build=1; shift ;;
      --list-addons)  do_list=1; shift ;;
      -h|--help)
        cat <<USAGE
Usage: gosite sync [project] [flags]

Re-apply gosite's templates to an existing project without overwriting
your work. With no flags, syncs compose files, addons and the .env template.

Flags:
  --compose      Re-render docker-compose.yml, docker-compose.prod.yml
                 and cockpit/config.php from the current templates
  --addons       Refresh every Cockpit addon present in the project from
                 gosite's addon library (built-ins + any optional ones),
                 or install the named addons: --addons "Forms Replica"
  --env          Add any keys missing from the .env template to the project
                 .env (never overwrites existing values or secrets)
  --build        After syncing, rebuild the local app/CMS images
  --list-addons  List the addons available in gosite's library and exit
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

  # No action flag -> sync everything that is safe to re-apply.
  [[ "${do_compose}" -eq 1 || "${do_addons}" -eq 1 || "${do_env}" -eq 1 ]] || {
    do_compose=1; do_addons=1; do_env=1
  }

  require_dependencies
  source "${GOSITE_ROOT}/lib/templates.sh"

  local dir; dir="$(resolve_project_dir "${name}")"
  info "Syncing gosite templates into ${dir}"

  if [[ "${do_compose}" -eq 1 ]]; then
    _sync_compose "${dir}"
  fi
  if [[ "${do_addons}" -eq 1 ]]; then
    _sync_addons "${dir}" "${ADDONS}"
  fi
  if [[ "${do_env}" -eq 1 ]]; then
    _sync_env "${dir}"
  fi

  if [[ "${do_build}" -eq 1 ]]; then
    info "Rebuilding images for '${GOSITE_PROJECT:-$(basename "${dir}")}'"
    compose -p "$(basename "${dir}")" -f "${dir}/docker-compose.yml" --project-directory "${dir}" build
  fi

  ok "Sync complete. Start the project with 'gosite start $(basename "${dir}")'"
}

# Re-renders the compose files, the Cockpit config.php and the build files the
# compose files reference (deploy/Dockerfile*, .air.toml, .dockerignore),
# resolving the __PLACEHOLDER__ tokens against the values in .gosite.env. Old
# scaffolds may lack deploy/ entirely, so it is written here - otherwise docker
# fails with "/deploy: no such file or directory".
_sync_compose() {
  local dir="$1"
  load_project_render_vars "${dir}"

  _write_compose_dev "${dir}"
  render_placeholders "${dir}/docker-compose.yml"

  _write_compose_prod "${dir}"
  render_placeholders "${dir}/docker-compose.prod.yml"
  render_placeholders "${dir}/cockpit/config.php"

  _write_air_config "${dir}"
  _write_dockerfiles "${dir}"

  ok "Re-rendered compose files, cockpit/config.php, deploy/ build files"
}

# Refreshes every addon the project already has: the built-ins are always
# copied, and any optional addon directory present under cockpit/addons/ (e.g.
# Forms, Replica) is refreshed too, so an earlier opt-in survives a sync.
# Then clears the CMS module cache so Cockpit re-registers the modules.
_sync_addons() {
  local dir="$1" want="${2:-}" target="${1}/cockpit/addons" name synced=0

  if [[ -n "${want}" ]]; then
    _install_addons "${dir}" "${want}"
  else
    _write_builtin_addons "${dir}"
    synced=1

    for name in "${target}"/*/; do
      [[ -d "${name}" ]] || continue
      name="$(basename "${name}")"
      case "${name}" in
        AssetsUpload|ModelManager|CloudStorage) continue ;;  # handled above
      esac
      if [[ -d "${GOSITE_ROOT}/addons/${name}" ]]; then
        mkdir -p "${target}/${name}"
        cp -R "${GOSITE_ROOT}/addons/${name}/." "${target}/${name}/"
        ok "Refreshed addon ${name}"
        synced=1
      else
        warn "Addon '${name}' is no longer in gosite's library; left in place."
      fi
    done
  fi

  # Cockpit caches registered addons; without clearing it, a refresh is
  # invisible until the cache expires or is wiped by hand.
  rm -f "${dir}/cockpit-storage/cache/modules.cache.php" \
        "${dir}/cockpit-storage/cache/addons.cache.php"

  [[ "${synced}" -eq 1 ]] && ok "Addons refreshed in ${target}"
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

_sync_list_addons() {
  info "Addons in gosite's library:"
  for d in "${GOSITE_ROOT}/addons"/*/; do
    [[ -d "${d}" ]] || continue
    local name; name="$(basename "${d}")"
    case "${name}" in
      AssetsUpload|ModelManager|CloudStorage) printf '  %-16s %s\n' "${name}" "(built-in, always installed)" ;;
      *) printf '  %-16s %s\n' "${name}" "(optional, opt-in via --addons)" ;;
    esac
  done
  printf '\nInstall an optional addon with: gosite sync --addons <name> (then start the project)\n'
}
