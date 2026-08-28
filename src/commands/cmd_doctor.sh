#!/usr/bin/env bash
#
# gosite doctor [--strict]
#
# Two jobs, both read-only:
#
#   1. Verify the local toolchain (docker, compose, go, air, ...).
#   2. Audit the registered projects and the shared infrastructure for
#      deviations from gosite's secure defaults (missing forms proxy trust,
#      empty purge token, wildcard CORS, datastores published beyond
#      loopback). Findings are reported with the exact command that fixes
#      them; nothing is ever modified by the audit itself.
#
# --strict makes the command exit non-zero when there is at least one
# finding, so the audit can gate CI or a pre-deploy check.
#

cmd_doctor() {
  local strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)  strict=1; shift ;;
      -h|--help)
        cat <<USAGE
Usage: gosite doctor [--strict]

Verify the local toolchain and audit every registered project plus the
shared infrastructure against gosite's secure defaults. Strictly read-only.

Flags:
  --strict   Exit non-zero when the audit finds any deviation
  -h, --help Show this help
USAGE
        return 0
        ;;
      *) fatal "Unknown flag for 'doctor': $1 (expected --strict)" ;;
    esac
  done

  require_dependencies --report

  # --- security audit (read-only) ---------------------------------------------
  GOSITE_AUDIT_FINDINGS=0
  info "Auditing registered projects and shared infrastructure (read-only)"

  local name dir state
  while IFS=$'\t' read -r name dir state; do
    [[ -n "${name}" ]] || continue
    if [[ "${state}" == "unavailable" ]]; then
      printf "  ${C_DIM}unavailable  %s (%s is gone; fix with 'gosite list --prune')${C_NC}\n" "${name}" "${dir}"
      continue
    fi
    _audit_project "${name}" "${dir}"
  done < <(registry_entries)

  _audit_infra

  if [[ "${GOSITE_AUDIT_FINDINGS}" -eq 0 ]]; then
    ok "Security audit: no deviations from the secure defaults."
  else
    err "Security audit: ${GOSITE_AUDIT_FINDINGS} finding(s) above."
    if [[ "${strict}" -eq 1 ]]; then
      err "Exiting non-zero (--strict)."
      exit 2
    fi
  fi
}

# One finding: scope, setting, observed value, one-line risk, remediation.
_audit_finding() {
  printf "  ${C_RED}!${C_NC} ${C_BOLD}%s${C_NC}  %s\n" "$1" "$2"
  printf "      ${C_DIM}observed:${C_NC} %s\n" "$3"
  printf "      ${C_DIM}risk:${C_NC}     %s\n" "$4"
  printf "      ${C_DIM}fix:${C_NC}      ${C_CYAN}%s${C_NC}\n" "$5"
  GOSITE_AUDIT_FINDINGS=$(( GOSITE_AUDIT_FINDINGS + 1 ))
}

_audit_project() {
  local name="$1" dir="$2"
  local config="${dir}/cockpit/config.php" envfile="${dir}/.env"

  # forms.trustedProxies: without it the Forms rate limit buckets all visitors
  # together, so one abusive client exhausts the quota for everyone.
  if [[ -f "${config}" ]] && ! grep -q "trustedProxies" "${config}"; then
    _audit_finding "${name}" "forms.trustedProxies" "absent" \
      "the Forms rate limit applies globally, not per visitor" \
      "add forms.trustedProxies to ${dir}/cockpit/config.php"
  fi

  # Empty purge token: the cache-purge endpoint answers unauthenticated in
  # any non-development deployment.
  if [[ -f "${envfile}" ]] && grep -qE '^COCKPIT_API_TOKEN=[[:space:]]*$' "${envfile}"; then
    _audit_finding "${name}" "COCKPIT_API_TOKEN" "empty" \
      "the /cache/purge endpoint is unauthenticated outside development" \
      "set COCKPIT_API_TOKEN in ${dir}/.env, then: gosite restart ${name}"
  fi

  # Wildcard CORS: the public form receiver would answer every origin.
  if [[ -f "${config}" ]] && grep -qE "allowed_origins.*\*" "${config}"; then
    _audit_finding "${name}" "forms.allowed_origins" "['*']" \
      "the public form receiver is open to every origin" \
      "list your site's origin(s) in cockpit/config.php, then: gosite restart ${name}"
  fi

  # Unlimited personal-data retention: submissions keep ip/userAgent forever.
  # Absent config = the 90-day default applies, which is fine; an explicit
  # zero means the operator chose to keep personal data indefinitely.
  # (The value regex requires 0 not followed by another digit, so 7776000
  # does not match.)
  if [[ -f "${config}" ]] && grep -qE "personal_data_retention.*=>[[:space:]]*0([^0-9]|$)" "${config}"; then
    _audit_finding "${name}" "forms.personal_data_retention" "0 (unlimited)" \
      "submissions retain ip/userAgent personal data indefinitely" \
      "set a retention window in cockpit/config.php (seconds), then: gosite restart ${name}"
  fi
}

# Shared infra: the datastores have no authentication; their only protection
# is binding to loopback. A publish address outside 127.x breaks that.
_audit_infra() {
  local svc container bindings
  for svc in mongo redis; do
    container="gosite-${svc}"
    docker inspect "${container}" >/dev/null 2>&1 || continue   # not running: not exposed

    bindings="$(docker inspect -f '{{json .HostConfig.PortBindings}}' "${container}" 2>/dev/null || echo '{}')"
    [[ "${bindings}" == "{}" || -z "${bindings}" ]] && continue  # no published ports at all

    # Any HostIp that is not loopback means the datastore is reachable from
    # the network. HostIp "" is docker's "all interfaces".
    if echo "${bindings}" | grep -qE '"HostIp":"(0\.0\.0\.0)?"'; then
      _audit_finding "infra" "${container} port binding" "${bindings}" \
        "unauthenticated datastore published beyond loopback" \
        "gosite infra down && gosite infra up"
    fi
  done
}
