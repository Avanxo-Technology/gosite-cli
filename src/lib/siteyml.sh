#!/usr/bin/env bash
#
# gosite.yml, from bash.
#
# The file is a strict subset of YAML that core's Go parser
# (core/internal/siteconfig) reads too: "key: value" lines, and "- item" lists
# under a key with no value (or "key: []"). No nesting, no multi-line values.
# Keeping to that subset is what lets both sides read it without a YAML library.

# siteyml_get <file> <key> -> the scalar value, unquoted; empty when absent.
siteyml_get() {
  local file="$1" key="$2" line value
  [[ -f "${file}" ]] || return 0
  line="$(grep -E "^${key}:" "${file}" | tail -1 || true)"
  [[ -n "${line}" ]] || return 0
  value="${line#"${key}:"}"
  value="${value%% #*}"
  value="$(printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ "${value}" == "[]" ]] && return 0
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  printf '%s' "${value}"
}

# siteyml_list <file> <key> -> one item per line.
siteyml_list() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 0
  awk -v key="${key}" '
    /^[^[:space:]#-][^:]*:/ {
      split($0, kv, ":")
      inlist = (kv[1] == key)
      next
    }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      sub(/[[:space:]]+#.*$/, "", item)
      sub(/[[:space:]]+$/, "", item)
      gsub(/^["\047]|["\047]$/, "", item)
      if (item != "") print item
    }
  ' "${file}"
}

# siteyml_set_list <file> <key> [item...] -> rewrites that list in place,
# keeping every other line (and its comments) as it was.
siteyml_set_list() {
  local file="$1" key="$2"; shift 2
  local tmp block item
  if [[ $# -eq 0 ]]; then
    block="${key}: []"
  else
    block="${key}:"
    for item in "$@"; do block+=$'\n'"  - ${item}"; done
  fi
  tmp="$(mktemp)"
  # The block goes through the environment: BSD awk (macOS) rejects a newline
  # inside a -v value.
  SITEYML_BLOCK="${block}" awk -v key="${key}" '
    BEGIN { block = ENVIRON["SITEYML_BLOCK"] }
    /^[^[:space:]#-][^:]*:/ {
      split($0, kv, ":")
      if (kv[1] == key) { print block; skipping = 1; done = 1; next }
      skipping = 0
    }
    skipping && (/^[[:space:]]*-/ || /^[[:space:]]*$/) { next }
    { skipping = 0; print }
    END { if (!done) print block }
  ' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}
