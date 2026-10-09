#!/usr/bin/env bash
#
# gosite docs [topic]
#
# Prints the agent notes shipped with the installed CLI (src/knowledge/).
# No argument lists the topics with their first heading; a topic prints the
# note unchanged. Read-only: it never writes, starts Docker or needs the network.
#
# Inside a site, one line goes to stderr when the site records a gosite or core
# version that differs from this CLI's. Thin sites record it in gosite.yml
# (core:); legacy sites keep their marker in .gosite.env, which records none.
#

# shellcheck source=../lib/siteyml.sh
source "${GOSITE_ROOT}/lib/siteyml.sh"

# Topic names, one per line, in byte order so the listing reads the same on
# macOS and Linux.
_docs_topics() {
  local file
  for file in "${GOSITE_ROOT}/knowledge"/*.md; do
    [[ -f "${file}" ]] || continue
    file="${file##*/}"
    printf '%s\n' "${file%.md}"
  done | LC_ALL=C sort
}

# _docs_has_topic <topic> -> 0 when the topic is one of the listed names.
_docs_has_topic() {
  local name
  while IFS= read -r name; do
    [[ "${name}" == "$1" ]] && return 0
  done < <(_docs_topics)
  return 1
}

# _docs_title <file> -> the first line starting with '#', hashes removed.
_docs_title() {
  sed -n -E '/^#/{s/^#+[[:space:]]*//;p;q;}' "$1"
}

# _docs_site_version -> the version the nearest site above $PWD records, with a
# leading 'v' removed. Prints nothing when there is no site or it records none.
_docs_site_version() {
  local dir="${PWD}" version
  while :; do
    if [[ -f "${dir}/gosite.yml" ]]; then
      version="$(siteyml_get "${dir}/gosite.yml" core)"
      printf '%s' "${version#v}"
      return 0
    fi
    # Legacy marker: it records no gosite version, so there is nothing to compare.
    [[ -f "${dir}/${GOSITE_MARKER}" ]] && return 0
    [[ "${dir}" == "/" ]] && return 0
    dir="${dir%/*}"
    dir="${dir:-/}"
  done
}

# _docs_version_line -> one stderr line when the site's version differs from the CLI's.
_docs_version_line() {
  local cli="${GOSITE_VERSION#v}" site
  site="$(_docs_site_version)"
  [[ -n "${site}" && "${site}" != "${cli}" ]] || return 0
  printf 'note: this site records gosite %s; these notes come from gosite %s\n' \
    "${site}" "${cli}" >&2
}

cmd_docs() {
  local topic="${1:-}" name

  if [[ -z "${topic}" ]]; then
    while IFS= read -r name; do
      printf '%-32s %s\n' "${name}" "$(_docs_title "${GOSITE_ROOT}/knowledge/${name}.md")"
    done < <(_docs_topics)
    return 0
  fi

  # Only names from the listing are read, so a topic can never name a path.
  if ! _docs_has_topic "${topic}"; then
    err "Unknown docs topic: ${topic}"
    printf 'Topics: %s\n' "$(_docs_topics | paste -sd ' ' -)" >&2
    exit 1
  fi

  _docs_version_line
  cat "${GOSITE_ROOT}/knowledge/${topic}.md"
}
