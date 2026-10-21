#!/usr/bin/env bash
#
# gosite versions local|prod [--patch DIR] [--strict]
#
# Compares the image references in the repo with the newest tags published
# on Docker Hub in the same line. Read-only by default.
#
#   local  The shared infrastructure compose and the dev files of every
#          registered project (docker-compose.yml, deploy/Dockerfile.dev,
#          deploy/Dockerfile.cms).
#   prod   The production and QA files of every registered project
#          (docker-compose.prod.yml, docker-compose.qa.yml, deploy/Dockerfile,
#          deploy/Dockerfile.cms). Production deploys from GitHub, so the repo
#          is the source of truth. This command never talks to a server.
#
# --patch DIR (prod only) writes one unified diff per file into DIR. It only
# carries patch-level updates in the current major.minor line. Minor and major
# changes are reported and left for a person. Nothing in the repo is modified.
#
# --strict exits non-zero when any reference is not at its newest tag, so the
# check can gate a pre-deploy step.
#

cmd_versions() {
  local scope="" patch_dir="" strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      local|prod) scope="$1"; shift ;;
      --patch)    [[ $# -ge 2 ]] || fatal "--patch needs a directory"; patch_dir="$2"; shift 2 ;;
      --strict)   strict=1; shift ;;
      -h|--help)
        cat <<USAGE
Usage: gosite versions <local|prod> [--patch DIR] [--strict]

Compare image references with the newest Docker Hub tags in the same line.

Scopes:
  local   Shared infra and dev files of every registered project
  prod    Prod and QA files of every registered project (read-only)

Flags:
  --patch DIR  (prod) write one diff per file for patch-level updates
  --strict     Exit non-zero when any reference is not current
  -h, --help   Show this help
USAGE
        return 0
        ;;
      *) fatal "Unknown argument for 'versions': $1 (expected local or prod)" ;;
    esac
  done
  [[ -n "${scope}" ]] || fatal "Choose a scope: gosite versions local|prod"
  if [[ -n "${patch_dir}" && "${scope}" != "prod" ]]; then
    fatal "--patch applies to the prod scope only"
  fi

  local files=() labels=() roots=()
  _versions_collect "${scope}"

  if [[ "${#files[@]}" -eq 0 ]]; then
    warn "No ${scope} files found in registered projects."
    return 0
  fi

  info "Image versions (${scope}): ${#files[@]} file(s)"
  printf '  %-22s %-38s %-30s %-16s %-10s %s\n' "PROJECT" "FILE:LINE" "IMAGE" "CURRENT" "STATUS" "TARGET"

  local outstanding=0 unchecked=0 patched_files=0
  local i file label row lineno repo tag changes
  changes="$(mktemp "${TMPDIR:-/tmp}/gosite-versions-changes.XXXXXX")" || fatal "Cannot create a temporary file"
  for i in "${!files[@]}"; do
    file="${files[$i]}"
    label="${labels[$i]}"
    : > "${changes}"
    while IFS=$'\t' read -r lineno repo tag; do
      [[ -n "${repo}" ]] || continue
      row="$(_versions_check_ref "${repo}" "${tag}")"
      local status target line_target shown
      IFS=$'\t' read -r status target line_target <<< "${row}"
      # When a minor or major is the reported status, the patch in the
      # current line is shown next to it: that patch can still be applied.
      shown="${target}"
      if [[ "${status}" != "patch" && -n "${line_target}" ]]; then
        shown="${target} (patch ${line_target})"
      fi
      printf '  %-22s %-38s %-30s %-16s %-10s %s\n' \
        "${label}" "$(basename "${file}"):${lineno}" "${repo}" "${tag}" "${status}" "${shown}"
      case "${status}" in
        current)   ;;
        unchecked) unchecked=$((unchecked + 1)) ;;
        *)         outstanding=$((outstanding + 1)) ;;
      esac
      if [[ -n "${patch_dir}" && -n "${line_target}" && "${line_target}" != "${tag}" ]]; then
        printf '%s\t%s\t%s\t%s\n' "${lineno}" "${repo}" "${tag}" "${line_target}" >> "${changes}"
      fi
    done < <(versions_scan_file "${file}")
    # One patch per file, carrying every change in that file.
    if [[ -n "${patch_dir}" && -s "${changes}" ]]; then
      _versions_write_patch "${file}" "${roots[$i]}" "${changes}" "${patch_dir}" \
        && patched_files=$((patched_files + 1))
    fi
  done
  rm -f "${changes}"

  if [[ -n "${patch_dir}" ]]; then
    if [[ "${patched_files}" -gt 0 ]]; then
      ok "Wrote ${patched_files} patch-level diff(s) to ${patch_dir}. The repo was not modified."
    else
      ok "No patch-level updates to write."
    fi
  fi

  if [[ "${unchecked}" -gt 0 ]]; then
    warn "${unchecked} reference(s) could not be checked (registry not supported or unreachable)."
  fi
  if [[ "${outstanding}" -eq 0 ]]; then
    ok "Every checked reference is at its newest tag in its line."
  else
    warn "${outstanding} reference(s) are not at their newest tag. 'minor', 'major', 'floating' and 'unknown' need a manual decision."
  fi

  if [[ "${strict}" -eq 1 && "${outstanding}" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# _versions_collect <scope>
# Fills the parallel files, labels and roots arrays of the caller. The root is
# the directory a patch path is made relative to, so 'git apply' run inside
# the project finds the file.
_versions_collect() {
  local scope="$1" name path state candidate
  if [[ "${scope}" == "local" && -f "${GOSITE_INFRA_DIR}/docker-compose.yml" ]]; then
    _versions_add "${GOSITE_INFRA_DIR}/docker-compose.yml" "infra" "${GOSITE_INFRA_DIR}"
  fi
  while IFS=$'\t' read -r name path state; do
    [[ "${state}" == "available" ]] || continue
    if [[ "${scope}" == "local" ]]; then
      for candidate in docker-compose.yml deploy/Dockerfile.dev deploy/Dockerfile.cms; do
        _versions_add "${path}/${candidate}" "${name}" "${path}"
      done
    else
      for candidate in docker-compose.prod.yml docker-compose.qa.yml deploy/Dockerfile deploy/Dockerfile.cms; do
        _versions_add "${path}/${candidate}" "${name}" "${path}"
      done
    fi
  done < <(registry_entries)
}

# _versions_add <file> <label> <root>: records the file when it exists.
_versions_add() {
  [[ -f "$1" ]] || return 0
  files+=("$1")
  labels+=("$2")
  roots+=("$3")
}

# _versions_check_ref <repo> <tag>
# Prints "<status>\t<target>\t<patch-target>" for one reference.
_versions_check_ref() {
  local repo="$1" tag="$2" parts prefix version filter tags
  parts="$(versions_parse_tag "${tag}")"
  if [[ -z "${parts}" ]]; then
    printf 'floating\t\t\n'
    return 0
  fi
  IFS='|' read -r prefix version _ <<< "${parts}"
  filter="${prefix}${version%%.*}"
  if ! tags="$(versions_hub_tags "${repo}" "${filter}")"; then
    printf 'unchecked\t\t\n'
    return 0
  fi
  # shellcheck disable=SC2086
  versions_classify "${tag}" ${tags}
}

# _versions_write_patch <file> <root> <changes> <dir>
# Writes one unified diff for <file> with every change listed in <changes>.
# Each change line is "<lineno>\t<repo>\t<old-tag>\t<new-tag>". The diff paths
# are relative to <root> (the project directory), so 'git apply' run inside
# the project finds the file. The repo file is not modified: the new content is
# built in a temporary copy.
#
# A replacement only fires on its own line and only when the old reference is
# followed by a space, a quote or the end of the line. That keeps "16-alpine"
# from matching inside "16-alpine3.24".
#
# perl keeps a missing final newline as it is. awk would add one and produce a
# spurious change on the last line.
_versions_write_patch() {
  local file="$1" root="$2" changes="$3" dir="$4"
  local rel tmp out safe
  mkdir -p "${dir}" || fatal "Cannot create ${dir}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gosite-versions.XXXXXX")" || return 1

  CHANGES="${changes}" perl -e '
    open my $fh, "<", $ENV{CHANGES} or die "cannot read changes: $!";
    my %by_line;
    while (my $row = <$fh>) {
      chomp $row;
      my ($ln, $repo, $old, $new) = split /\t/, $row, 4;
      push @{ $by_line{$ln} }, [$repo, $old, $new];
    }
    while (my $text = <STDIN>) {
      if (my $list = $by_line{$.}) {
        for my $c (@$list) {
          my ($repo, $old, $new) = @$c;
          my $pat = quotemeta("$repo:$old");
          $text =~ s/(?<![\w.\/-])$pat(?=[\s"\x27]|$)/$repo:$new/g;
        }
      }
      print $text;
    }
  ' < "${file}" > "${tmp}/new" || { rm -rf "${tmp}"; return 1; }

  rel="${file#"${root}"/}"
  # The project name prefixes the file name, so two projects with a
  # Dockerfile at the same relative path never write to the same patch.
  safe="$(basename "${root}")__$(printf '%s' "${rel}" | tr '/' '_')"
  out="${dir}/${safe}.patch"
  # diff exits 1 when the files differ, which is the expected case here.
  diff -u --label "a/${rel}" --label "b/${rel}" "${file}" "${tmp}/new" > "${out}" || true
  rm -rf "${tmp}"
  if [[ ! -s "${out}" ]]; then
    rm -f "${out}"
    return 1
  fi
  debug "wrote ${out}"
  return 0
}
