#!/usr/bin/env bash
#
# gosite addons - install, list and remove Cockpit addons in an existing project.
#
# The work itself lives in lib/templates.sh (_install_addons, install_addon_overlays):
# this command is the discoverable front door for it, so adding an addon to a
# project made months ago does not mean knowing that `sync` has an --addons
# flag. There is one implementation, not two.
#
# An addon can have two halves. Every addon has a CMS half in cockpit/addons/.
# Some also have an application half - the blog serves its own pages - which is
# an overlay under src/templates/addons/<name>/. Installing adds files only:
# an addon with an application half wires itself from its own file, so a
# project's hand-edited router.go is never rewritten.

cmd_addons() {
  local sub="${1:-list}"
  [[ $# -gt 0 ]] && shift || true

  case "${sub}" in
    add|install)    _addons_add "$@" ;;
    remove|rm)      _addons_remove "$@" ;;
    list|ls|"")     _addons_list "$@" ;;
    -h|--help)      _addons_usage ;;
    *)
      err "Unknown 'addons' subcommand: ${sub}"
      _addons_usage
      return 127
      ;;
  esac
}

_addons_usage() {
  cat <<EOF
Usage: gosite addons <command> [addons...] [project]

  list [project]              Show gosite's addon library and what the project has
  add <name>... [project]     Install addons into a project
  remove <name>... [project]  Remove addons from a project

Flags:
  --force     On add: overwrite files you have edited since gosite wrote them
              (without it they are preserved and reported)

The project is the current directory when not named. Addon names are matched
against gosite's library, so the project can be given in any position:

  gosite addons add Blog
  gosite addons add Blog Forms my-site
  gosite addons remove Blog my-site

An addon that ships application pages (Blog) changes both halves of the project,
so the CMS image AND the application have to be rebuilt - restarting is not
enough.
EOF
}

# Names of every addon gosite ships.
_addons_available() {
  local d
  for d in "${GOSITE_ROOT}/addons"/*/; do
    [[ -d "${d}" ]] || continue
    basename "${d}"
  done
}

# Built-ins are written into every scaffold and are not opt-in, so they are not
# valid arguments to add or remove.
_addons_is_builtin() {
  case "$1" in
    Webapp) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolves an argument list into addon names and an optional project name.
#
# Addon names are a known, closed set, so anything that is not one of them is
# the project. That keeps the command readable in either order rather than
# forcing a flag for the common case.
#
# Sets: ADDON_NAMES, ADDON_PROJECT, ADDON_FORCE
_addons_parse_args() {
  ADDON_NAMES=""
  ADDON_PROJECT=""
  ADDON_FORCE=0

  local arg match available
  available="$(_addons_available)"

  for arg in "$@"; do
    case "${arg}" in
      --force) ADDON_FORCE=1; continue ;;
      -*)      fatal "Unknown flag for 'addons': ${arg}" ;;
    esac

    # Case-insensitive match against the library, so `blog` finds `Blog`.
    match="$(printf '%s\n' "${available}" | grep -ix "${arg}" || true)"

    if [[ -n "${match}" ]]; then
      ADDON_NAMES="${ADDON_NAMES:+${ADDON_NAMES} }${match}"
    elif [[ -z "${ADDON_PROJECT}" ]]; then
      ADDON_PROJECT="${arg}"
    else
      fatal "Don't know what '${arg}' is: not an addon in gosite's library, and '${ADDON_PROJECT}' was already taken as the project. Run 'gosite addons list'."
    fi
  done
}

_addons_add() {
  require_dependencies
  source "${GOSITE_ROOT}/lib/templates.sh"
  source "${GOSITE_ROOT}/lib/manifest.sh"

  _addons_parse_args "$@"

  [[ -n "${ADDON_NAMES}" ]] || fatal "Name at least one addon to add. Run 'gosite addons list' to see them."

  local one
  for one in ${ADDON_NAMES}; do
    ! _addons_is_builtin "${one}" \
      || fatal "${one} is built in: every gosite project already has it." 
  done

  local dir; dir="$(resolve_project_dir "${ADDON_PROJECT}")"
  manifest_ensure_adopted "${dir}"

  _addons_preflight "${dir}" "${ADDON_NAMES}" || return 1

  info "Installing into $(basename "${dir}"): ${ADDON_NAMES}"

  # The CMS half, plus the manifest entries, the application pages and the
  # module-cache clear that go with it.
  install_addons_into_project "${dir}" "${ADDON_NAMES}" "${ADDON_FORCE}"

  ok "Done."
  _addons_rebuild_notice "${dir}" "${ADDON_NAMES}"
}

# Refuses an install that would leave the project unable to compile.
#
# An addon's pages call into the project's own Go code, which gosite never
# rewrites - sync preserves internal/*.go on purpose. A project scaffolded
# before those seams existed therefore has to be brought up to date by hand
# first. Installing anyway would "succeed" and break the build, so this stops
# and names every file and the exact thing missing from it.
_addons_preflight() {
  local dir="$1" names="$2" one unmet blocked=0

  for one in ${names}; do
    addon_has_overlay "${one}" || continue

    unmet="$(addon_unmet_requirements "${dir}" "${one}")"
    [[ -n "${unmet}" ]] || continue

    blocked=1
    err "${one} needs application code this project does not have yet:"
    printf '%s\n' "${unmet}" | while IFS=$'\t' read -r path marker; do
      if [[ -f "${dir}/${path}" ]]; then
        printf '    %-40s missing: %s\n' "${path}" "${marker}"
      else
        printf '    %-40s missing entirely\n' "${path}"
      fi
    done
  done

  [[ "${blocked}" -eq 0 ]] || {
    printf '\n'
    warn "gosite never rewrites your Go source, so it cannot fix these for you."
    printf "  Apply the corresponding changes from gosite's templates, then run this again:\n"
    printf '    %s/templates/\n' "${GOSITE_ROOT}"
    printf '  Nothing was installed.\n'
    return 1
  }

  return 0
}

_addons_remove() {
  require_dependencies
  source "${GOSITE_ROOT}/lib/templates.sh"
  source "${GOSITE_ROOT}/lib/manifest.sh"

  _addons_parse_args "$@"

  [[ -n "${ADDON_NAMES}" ]] || fatal "Name at least one addon to remove."

  local one
  for one in ${ADDON_NAMES}; do
    ! _addons_is_builtin "${one}" \
      || fatal "${one} is built in and the scaffold depends on it; removing it would break the project."
  done

  local dir; dir="$(resolve_project_dir "${ADDON_PROJECT}")"

  local lower removed=0
  for one in ${ADDON_NAMES}; do

    if [[ ! -d "${dir}/cockpit/addons/${one}" ]]; then
      warn "${one} is not installed in $(basename "${dir}")."
      continue
    fi

    rm -rf "${dir}/cockpit/addons/${one}"
    ok "Removed cockpit/addons/${one}"

    # The application half, if this addon has one. Every file it installed is
    # listed by the overlay itself, so removal is exactly the inverse of the
    # install and never guesses at paths.
    lower="$(printf '%s' "${one}" | tr '[:upper:]' '[:lower:]')"

    if addon_has_overlay "${one}"; then
      local stage rel
      stage="$(mktemp -d)"
      while IFS= read -r rel; do
        [[ -n "${rel}" ]] || continue
        [[ -f "${dir}/${rel}" ]] || continue
        rm -f "${dir}/${rel}"
        ok "Removed ${rel}"
      done < <(render_addon_overlay "${GOSITE_ROOT}/templates" "${stage}" "${lower}")
      rm -rf "${stage}"

      # Directories the addon owned outright, left behind empty.
      rmdir "${dir}/internal/${lower}" 2>/dev/null || true
    fi

    removed=$((removed + 1))
  done

  [[ "${removed}" -gt 0 ]] || return 0

  # Cockpit caches which addons are registered; without clearing it the removal
  # is invisible until the cache expires.
  rm -f "${dir}/cockpit-storage/cache/modules.cache.php" \
        "${dir}/cockpit-storage/cache/addons.cache.php"

  manifest_write_from_dir "${dir}" 2>/dev/null || true

  warn "Content the addon created is left untouched: its models and entries are still in the database, and removing them is a data decision, not an install one."
  _addons_rebuild_notice "${dir}" "${ADDON_NAMES}"
}

_addons_list() {
  source "${GOSITE_ROOT}/lib/templates.sh"

  _addons_parse_args "$@"

  # Listing works outside a project too, so resolution is only attempted when
  # it can succeed: naming a project that does not exist is still an error, but
  # running this from an unrelated directory just lists the library.
  local dir=""
  if [[ -n "${ADDON_PROJECT}" ]] || is_gosite_project "."; then
    dir="$(resolve_project_dir "${ADDON_PROJECT}")"
  fi

  if [[ -n "${dir}" ]]; then
    info "Addons in $(basename "${dir}"):"
  else
    info "Addons in gosite's library (not inside a project, so nothing is marked installed):"
  fi

  local name status extra
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue

    if _addons_is_builtin "${name}"; then
      status="built-in"
    elif [[ -n "${dir}" && -d "${dir}/cockpit/addons/${name}" ]]; then
      status="installed"
    else
      status="available"
    fi

    extra=""
    addon_has_overlay "${name}" && extra=" - also installs application pages"

    printf '  %-14s %-11s %s\n' "${name}" "${status}" "${extra}"
  done < <(_addons_available)

  printf '\nAdd one with: gosite addons add <name>%s\n' "${ADDON_PROJECT:+ ${ADDON_PROJECT}}"
}

# Says what has to be rebuilt for the change to be visible. Addons are baked
# into the CMS image, and an addon with an application half is compiled into
# the app binary, so a restart shows neither.
_addons_rebuild_notice() {
  local dir="$1" names="$2" one app=0

  for one in ${names}; do
    addon_has_overlay "${one}" && app=1
  done

  if [[ "${app}" -eq 1 ]]; then
    warn "Rebuild the CMS image AND the application - restarting is not enough:"
    printf '    gosite restart %s --build\n' "$(basename "${dir}")"
  else
    warn "The addon is baked into the CMS image, so rebuild it - restarting is not enough:"
    printf '    gosite restart %s --build\n' "$(basename "${dir}")"
  fi
}
