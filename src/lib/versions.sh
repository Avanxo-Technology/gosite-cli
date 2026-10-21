#!/usr/bin/env bash
#
# Image-version helpers for 'gosite versions'. Pure functions only: they parse
# references, classify tags and query the public Docker Hub tag API. Nothing
# here writes files; callers decide what to do with the answer.
#
# A tag is split into prefix, version and suffix:
#   core-2.14.0      -> prefix "core-", version "2.14.0", suffix ""
#   1.26-alpine      -> prefix "",     version "1.26",   suffix "-alpine"
#   v3.7             -> prefix "v",    version "3.7",    suffix ""
# Only tags with the same prefix and suffix are compared.
#

# versions_split_ref <image-ref>
# Prints "<repo>\t<tag>". The tag defaults to "latest" when the reference has
# none. Digests (@sha256:...) are not split: they print an empty tag.
versions_split_ref() {
  local ref="$1" repo tag
  if [[ "${ref}" == *@* ]]; then
    printf '%s\t%s\n' "${ref%%@*}" ""
    return 0
  fi
  local last="${ref##*/}"
  if [[ "${last}" == *:* ]]; then
    repo="${ref%:*}"
    tag="${ref##*:}"
  else
    repo="${ref}"
    tag="latest"
  fi
  printf '%s\t%s\n' "${repo}" "${tag}"
}

# versions_scan_file <file>
# Prints "<line-no>\t<repo>\t<tag>" for every Dockerfile FROM and compose
# image: line. Skips variable references (${...}), the scratch image and stage
# aliases used as FROM sources (a FROM with no tag and no slash can be a stage).
versions_scan_file() {
  local file="$1" lineno=0 line ref parts repo tag
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    ref=""
    if [[ "${line}" =~ ^[[:space:]]*FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?([^[:space:]]+) ]]; then
      ref="${BASH_REMATCH[2]}"
    elif [[ "${line}" =~ ^[[:space:]]*image:[[:space:]]*[\"\']?([^\"\'[:space:]]+) ]]; then
      ref="${BASH_REMATCH[1]}"
    fi
    [[ -n "${ref}" ]] || continue
    [[ "${ref}" == *'$'* ]] && continue
    [[ "${ref}" == "scratch" ]] && continue
    if [[ "${ref}" != *:* && "${ref}" != */* && "${ref}" != *@* ]]; then
      # Bare name: a stage alias in a Dockerfile, or an implicit :latest.
      # Only compose image: lines are treated as real images here.
      [[ "${file}" == *docker-compose* ]] || continue
    fi
    parts="$(versions_split_ref "${ref}")"
    repo="${parts%%$'\t'*}"
    tag="${parts#*$'\t'}"
    printf '%s\t%s\t%s\n' "${lineno}" "${repo}" "${tag}"
  done < "${file}"
}

# versions_parse_tag <tag>
# Prints "<prefix>|<version>|<suffix>". Prints nothing when the tag has no
# leading digit after an optional non-digit prefix (for example "latest").
# The separator is "|", not a tab: a tab is whitespace to 'read', so empty
# prefix or suffix fields would collapse and shift the other fields.
versions_parse_tag() {
  local tag="$1"
  if [[ "${tag}" =~ ^([^0-9]*)([0-9]+(\.[0-9]+)*)(.*)$ ]]; then
    printf '%s|%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]}"
  fi
}

# _versions_key <version> <tag-components>: the line a version belongs to.
# When the current tag has one part, the line is the major ("16.4" -> "16").
# Otherwise it is major.minor ("1.26.10" -> "1.26", "3.7" -> "3.7").
_versions_key() {
  awk -F. -v n="$2" '{
    if (n == 1 || NF == 1) print $1
    else print $1 "." $2
  }' <<< "$1"
}

# versions_classify <current-tag> <candidate-tags...>
# Compares the current tag with candidate tags. Candidates with a different
# prefix or suffix are ignored here, so the caller can pass a raw tag list.
# Prints "<status>\t<target>\t<patch-target>":
#   floating  the current tag has no version (latest, edge); target empty
#   unknown   no candidate with the same prefix and suffix; target empty
#   minor     a newer minor (or major.minor line) in the same major exists
#   patch     a newer patch in the same major.minor line exists
#   major     a newer major line exists
#   current   nothing newer exists
# <target> is the newest version for the reported status.
# <patch-target> is the newest patch in the current line, or empty. It can be
# set together with 'minor', so a caller can still apply the patch.
versions_classify() {
  local current="$1"; shift
  local cur_parts cur_prefix cur_version cur_suffix
  cur_parts="$(versions_parse_tag "${current}")"
  if [[ -z "${cur_parts}" ]]; then
    printf 'floating\t\t\n'
    return 0
  fi
  IFS='|' read -r cur_prefix cur_version cur_suffix <<< "${cur_parts}"

  local cur_major="${cur_version%%.*}"
  local cur_components
  cur_components=$(awk -F. '{print NF}' <<< "${cur_version}")

  # _versions_key <version>: the line a version belongs to. A one-part tag
  # (postgres 16) names a major line, so every version under it shares that
  # line. A two-part or longer tag names a major.minor line.
  local cur_line
  cur_line="$(_versions_key "${cur_version}" "${cur_components}")"

  local candidate c_parts c_prefix c_version c_suffix c_components
  local same_line="" same_major="" any=""
  for candidate in "$@"; do
    c_parts="$(versions_parse_tag "${candidate}")"
    [[ -n "${c_parts}" ]] || continue
    IFS='|' read -r c_prefix c_version c_suffix <<< "${c_parts}"
    [[ "${c_prefix}" == "${cur_prefix}" && "${c_suffix}" == "${cur_suffix}" ]] || continue
    c_components=$(awk -F. '{print NF}' <<< "${c_version}")
    # A bare year-like tag (20260805) has fewer dots than the current tag
    # would suggest; require at least as many components as the current tag.
    (( c_components >= cur_components )) || continue
    any="${any}${c_version}"$'\n'
    if [[ "${c_version%%.*}" == "${cur_major}" ]]; then
      same_major="${same_major}${c_version}"$'\n'
      [[ "$(_versions_key "${c_version}" "${cur_components}")" == "${cur_line}" ]] \
        && same_line="${same_line}${c_version}"$'\n'
    fi
  done

  [[ -n "${any}" ]] || { printf 'unknown\t\t\n'; return 0; }

  local newest_line newest_major newest_any
  newest_line=$(printf '%s' "${same_line}" | sed '/^$/d' | sort -V | tail -n1)
  newest_major=$(printf '%s' "${same_major}" | sed '/^$/d' | sort -V | tail -n1)
  newest_any=$(printf '%s' "${any}" | sed '/^$/d' | sort -V | tail -n1)

  # The reported status is the most significant change still outstanding.
  # The third column always carries the newest patch in the current line,
  # so a caller can apply that patch even when a minor or major is reported.
  local line_target=""
  if _versions_newer "${newest_line}" "${cur_version}"; then
    line_target="${cur_prefix}${newest_line}${cur_suffix}"
  fi
  local major_line=""
  [[ -n "${newest_major}" ]] && major_line="$(_versions_key "${newest_major}" "${cur_components}")"

  local any_major="${newest_any%%.*}"
  if _versions_newer "${newest_any}" "${cur_version}" && [[ "${any_major}" != "${cur_major}" ]]; then
    printf 'major\t%s%s%s\t%s\n' "${cur_prefix}" "${newest_any}" "${cur_suffix}" "${line_target}"
  elif _versions_newer "${newest_major}" "${cur_version}" && [[ "${major_line}" != "${cur_line}" ]]; then
    printf 'minor\t%s%s%s\t%s\n' "${cur_prefix}" "${newest_major}" "${cur_suffix}" "${line_target}"
  elif [[ -n "${line_target}" ]]; then
    printf 'patch\t%s\t%s\n' "${line_target}" "${line_target}"
  else
    printf 'current\t%s%s%s\t\n' "${cur_prefix}" "${cur_version}" "${cur_suffix}"
  fi
}

# _versions_newer <a> <b>: succeeds when version a is strictly newer than b.
# An empty a is never newer.
_versions_newer() {
  [[ -n "$1" && "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# versions_hub_tags <repo> <name-filter>
# Prints tag names from Docker Hub that start with <name-filter>. Only
# docker.io repositories are supported. Returns 1 when the API cannot be
# reached or the repository is outside docker.io (for example ghcr.io).
versions_hub_tags() {
  local repo="$1" filter="$2" api
  case "${repo}" in
    ghcr.io/*|quay.io/*|*.*/*) return 1 ;;
  esac
  if [[ "${repo}" != */* ]]; then
    repo="library/${repo}"
  fi
  api="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&name=${filter}"
  local body
  body=$(curl -fsS --max-time 15 "${api}") || return 1
  # The API returns JSON. Extract "name" values without requiring jq.
  printf '%s' "${body}" | grep -oE '"name":"[^"]+"' | sed -E 's/^"name":"//; s/"$//'
}
