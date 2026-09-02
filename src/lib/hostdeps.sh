#!/usr/bin/env bash
#
# Host dependencies: what a machine needs before gosite can serve a project,
# how to tell whether it is there, and how it is installed on this platform.
#
# gosite's local stack is not just Docker. It needs a resolver that answers for
# *.<TLD>, a certificate authority the browser trusts, and - on Linux - that CA
# in the browser's OWN store, which is not the system's. Every one of those was
# a manual step discovered after a failure; this file is what lets 'gosite
# setup' and 'gosite doctor' talk about them by name.
#
# Nothing here changes the machine. Detection only: hostdep_status answers,
# hostdep_install_cmd returns the command that would fix it, and commands/
# cmd_setup.sh is the one place allowed to run those commands - after saying
# out loud what it is about to do.

# --- platform ----------------------------------------------------------------

# One of: macos, debian, linux, unknown.
#
# "debian" means apt is present, which is what the install commands need to be
# true; a Debian derivative that renamed apt would correctly fall through to
# "linux" and be reported rather than half-automated.
host_platform() {
  case "$(uname -s)" in
    Darwin) printf 'macos' ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then printf 'debian'; else printf 'linux'; fi
      ;;
    *) printf 'unknown' ;;
  esac
}

# Human-readable platform, for the plan gosite setup prints.
host_platform_label() {
  case "$(host_platform)" in
    macos)  printf 'macOS %s' "$(sw_vers -productVersion 2>/dev/null || echo '')" ;;
    debian)
      # shellcheck disable=SC1091
      if [[ -r /etc/os-release ]]; then
        printf '%s' "$( . /etc/os-release && printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}" )"
      else
        printf 'Debian/Ubuntu'
      fi
      ;;
    linux) printf 'Linux (unrecognised package manager)' ;;
    *)     printf '%s' "$(uname -s)" ;;
  esac
}

# True when this platform has automated install commands. Everywhere else
# gosite reports what is missing and links to the upstream instructions rather
# than guessing at a package manager.
host_platform_supported() {
  case "$(host_platform)" in
    macos|debian) return 0 ;;
    *) return 1 ;;
  esac
}

# --- individual dependencies -------------------------------------------------
#
# Each dependency answers three questions. Keeping them in one case statement
# per question - rather than one function per dependency - is what keeps the
# list readable as a list.

# hostdep_status <dep> -> ok | missing | misconfigured
#
# "misconfigured" is the state that used to cost an afternoon: the tool is
# installed and does nothing useful, because its CA was never generated or the
# resolver never learned about the TLD.
hostdep_status() {
  case "$1" in
    docker)
      command -v docker >/dev/null 2>&1 || { printf 'missing'; return; }
      docker info >/dev/null 2>&1 || { printf 'misconfigured'; return; }
      printf 'ok'
      ;;
    dnsmasq)
      # The tool matters less than the answer: what gosite needs is that a name
      # under the TLD resolves to loopback. A machine solving that another way
      # (a corporate resolver, systemd-resolved alone) is not broken.
      if dns_resolves; then printf 'ok'
      elif dnsmasq_installed; then printf 'misconfigured'
      else printf 'missing'; fi
      ;;
    mkcert)
      command -v mkcert >/dev/null 2>&1 || { printf 'missing'; return; }
      mkcert_ca_installed || { printf 'misconfigured'; return; }
      # A CA nothing trusts signs certificates nothing accepts.
      system_ca_trusted || { printf 'misconfigured'; return; }
      printf 'ok'
      ;;
    certutil)
      # Only meaningful where a Chromium/Firefox profile exists: those keep
      # their own NSS trust store and ignore the system's. No profile, nothing
      # to fix - not a finding.
      [[ -n "$(nss_databases)" ]] || { printf 'ok'; return; }
      command -v certutil >/dev/null 2>&1 || { printf 'missing'; return; }
      if nss_ca_trusted; then printf 'ok'; else printf 'misconfigured'; fi
      ;;
    *)
      if command -v "$1" >/dev/null 2>&1; then printf 'ok'; else printf 'missing'; fi
      ;;
  esac
}

# What the dependency is for, in one line. Shown beside every status so the
# list explains itself to somebody setting up their first machine.
hostdep_purpose() {
  case "$1" in
    docker)   printf 'runs every container: the proxy, the datastores and each project' ;;
    dnsmasq)  printf 'answers *.%s with 127.0.0.1 so project domains reach the proxy' "${GOSITE_TLD}" ;;
    mkcert)   printf 'issues the HTTPS certificates and installs a CA the system trusts' ;;
    certutil) printf 'puts that CA in the browser'"'"'s own store (Brave/Chrome/Firefox ignore the system'"'"'s)' ;;
    go)       printf 'builds the application outside the container' ;;
    air)      printf 'hot reload while developing' ;;
    *)        printf '' ;;
  esac
}

# The command that installs it here, or "" when this platform is not automated.
hostdep_install_cmd() {
  local platform; platform="$(host_platform)"
  case "$1:${platform}" in
    docker:macos)    printf '' ;;   # Docker Desktop is a GUI install; never automated
    docker:debian)   printf '' ;;   # the convenience script pipes root a remote file; not our call

    dnsmasq:macos)   printf 'brew install dnsmasq' ;;
    dnsmasq:debian)  printf 'sudo apt-get install -y dnsmasq' ;;

    mkcert:macos)    printf 'brew install mkcert nss' ;;
    mkcert:debian)   printf 'sudo apt-get install -y mkcert libnss3-tools ca-certificates' ;;

    certutil:macos)  printf 'brew install nss' ;;
    certutil:debian) printf 'sudo apt-get install -y libnss3-tools' ;;

    go:macos)        printf 'brew install go' ;;
    go:debian)       printf 'sudo apt-get install -y golang-go' ;;

    air:*)           printf 'go install github.com/air-verse/air@latest' ;;
    *)               printf '' ;;
  esac
}

# Where to read about it when gosite cannot install it here.
hostdep_docs() {
  case "$1" in
    docker)   printf 'https://docs.docker.com/get-docker/' ;;
    dnsmasq)  printf 'https://thekelleys.org.uk/dnsmasq/doc.html' ;;
    mkcert)   printf 'https://github.com/FiloSottile/mkcert#installation' ;;
    certutil) printf 'https://firefox-source-docs.mozilla.org/security/nss/' ;;
    go)       printf 'https://go.dev/dl/ (1.25+, required by Echo v5)' ;;
    air)      printf 'https://github.com/air-verse/air' ;;
    *)        printf '' ;;
  esac
}

# The dependencies gosite will not start without, and the ones that only make
# development nicer. dnsmasq and mkcert are in the first list on purpose: a
# project without them scaffolds fine and then serves nothing a browser will
# open, which is a worse failure than refusing up front.
readonly GOSITE_HOST_DEPS=(docker dnsmasq mkcert certutil)
readonly GOSITE_HOST_DEPS_OPTIONAL=(go air)

# dnsmasq is a daemon, so it installs into sbin - which is on root's PATH and
# often not on a user's. Looking only at `command -v` reports it missing on a
# machine that has it, and the plan then offers to install it again.
dnsmasq_installed() {
  command -v dnsmasq >/dev/null 2>&1 && return 0
  local dir
  for dir in /opt/homebrew/sbin /usr/local/sbin /usr/sbin /sbin; do
    [[ -x "${dir}/dnsmasq" ]] && return 0
  done
  return 1
}

# --- NSS (browser trust stores) ----------------------------------------------
#
# Chromium, Brave, Chrome and Firefox each carry an NSS database and consult it
# instead of the operating system's trust store. A CA installed with
# 'mkcert -install' is therefore invisible to them on Linux, which is exactly
# how a correctly issued certificate still shows ERR_CERT_AUTHORITY_INVALID.

# Every NSS database belonging to this user, one path per line.
nss_databases() {
  local base
  for base in \
    "${XDG_DATA_HOME:-${HOME}/.local/share}/pki/nssdb" \
    "${HOME}/.pki/nssdb"; do
    [[ -f "${base}/cert9.db" ]] && printf '%s\n' "${base}"
  done
  # The loop's last test decides the exit status; a missing database is not an
  # error, so do not let it become this function's.
  true

  # Firefox keeps one database per profile.
  local profiles
  for profiles in "${HOME}/.mozilla/firefox" "${HOME}/Library/Application Support/Firefox/Profiles"; do
    [[ -d "${profiles}" ]] || continue
    while IFS= read -r db; do
      [[ -n "${db}" ]] && printf '%s\n' "$(dirname "${db}")"
    done < <(find "${profiles}" -name cert9.db -maxdepth 3 2>/dev/null)
  done
}

# The name mkcert gives its CA in a trust store.
readonly GOSITE_MKCERT_CA_NAME="mkcert development CA"

# True when every NSS database this user has already trusts the mkcert CA.
# With no databases at all there is nothing to distrust, which counts as true:
# a machine with no browser is not misconfigured.
nss_ca_trusted() {
  command -v certutil >/dev/null 2>&1 || return 1

  local db
  while IFS= read -r db; do
    [[ -n "${db}" ]] || continue
    certutil -d "sql:${db}" -L 2>/dev/null | grep -q "${GOSITE_MKCERT_CA_NAME}" || return 1
  done < <(nss_databases)

  return 0
}

# --- reporting ---------------------------------------------------------------

# Prints one aligned line per dependency. Used by doctor and by the installer,
# so both describe the machine the same way.
#
# Returns 1 when at least one required dependency is not ok, so the caller can
# decide whether to offer 'gosite setup'.
hostdeps_report() {
  local dep status missing=0

  for dep in "${GOSITE_HOST_DEPS[@]}"; do
    status="$(hostdep_status "${dep}")"
    case "${status}" in
      ok) ok "$(printf '%-9s %s' "${dep}" "$(hostdep_purpose "${dep}")")" ;;
      missing)
        warn "$(printf '%-9s missing - %s' "${dep}" "$(hostdep_purpose "${dep}")")"
        missing=1
        ;;
      misconfigured)
        warn "$(printf '%-9s installed but not configured - %s' "${dep}" "$(hostdep_purpose "${dep}")")"
        missing=1
        ;;
    esac
  done

  for dep in "${GOSITE_HOST_DEPS_OPTIONAL[@]}"; do
    if [[ "$(hostdep_status "${dep}")" == "ok" ]]; then
      ok "$(printf '%-9s %s' "${dep}" "$(hostdep_purpose "${dep}")")"
    else
      printf "  ${C_DIM}-  %-9s optional - %s${C_NC}\n" "${dep}" "$(hostdep_purpose "${dep}")"
    fi
  done

  return "${missing}"
}
