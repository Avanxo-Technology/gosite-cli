#!/usr/bin/env bash
#
# gosite setup - prepare this machine to serve local projects.
#
# The one place in gosite allowed to install packages and edit files outside
# $HOME. Everything it does was, until now, a manual step somebody had to
# rediscover on every new machine: a resolver for *.<TLD>, mkcert's CA in the
# system trust store, and that same CA in the browser's own store.
#
# Three rules, because this touches /etc:
#
#   1. It says what it will do before doing any of it, one line per action,
#      naming every file it will write and every service it will restart. Then
#      it asks. --yes skips the question; --dry-run stops after the plan.
#   2. It is idempotent. Every step checks first and is skipped when already
#      satisfied, so running it twice is not a way to break a machine. Files
#      are written whole into gosite's own drop-ins rather than appended to
#      somebody else's config, and anything replaced is backed up first.
#   3. It never runs unattended without being told to. Piped into bash with no
#      terminal to ask at, it prints the plan and exits without touching
#      anything.
#

cmd_setup() {
  local dry_run=0 do_dns=1 do_tls=1 undo=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  dry_run=1; shift ;;
      --yes|-y)   GOSITE_ASSUME_YES=1; shift ;;
      --dns)      do_tls=0; shift ;;
      --tls)      do_dns=0; shift ;;
      --undo)     undo=1; shift ;;
      -h|--help)
        cat <<USAGE
Usage: gosite setup [--dry-run] [--yes] [--dns|--tls] [--undo]

Prepare this machine for gosite: a resolver for *.${GOSITE_TLD}, mkcert's
certificate authority in the system trust store, and that CA in the browser
stores that keep their own (Brave, Chrome, Firefox).

Prints everything it is about to install, write and restart, then asks before
touching anything. Safe to run again: every step is skipped when already done.

Flags:
  --dry-run  Show the plan and stop
  --yes, -y  Do not ask (for scripts and CI)
  --dns      Only the resolver half
  --tls      Only the certificate half
  --undo     Remove what gosite wrote (drop-ins and resolver entries)
  -h, --help Show this help

Exit codes: 0 nothing to do (or everything succeeded), 10 with --dry-run when
steps are pending, 1 on failure or when the answer was no.
USAGE
        return 0
        ;;
      *) fatal "Unknown flag for 'setup': $1" ;;
    esac
  done

  [[ "${undo}" -eq 1 ]] && { _setup_undo; return $?; }

  info "Preparing $(host_platform_label)"

  if ! host_platform_supported; then
    warn "gosite has no automated setup for this platform."
    printf "\n"
    dns_setup_hint
    return 1
  fi

  # --- plan ------------------------------------------------------------------
  GOSITE_SETUP_PLAN=()
  [[ "${do_dns}" -eq 1 ]] && _setup_plan_dns
  [[ "${do_tls}" -eq 1 ]] && _setup_plan_tls

  if [[ "${#GOSITE_SETUP_PLAN[@]}" -eq 0 ]]; then
    ok "Nothing to do: this machine is already set up."
    _setup_verify
    return $?
  fi

  printf "\n${C_BOLD}gosite setup will:${C_NC}\n\n"
  local entry action needs_sudo description sudo_needed=0
  for entry in "${GOSITE_SETUP_PLAN[@]}"; do
    IFS=$'\t' read -r action needs_sudo description <<<"${entry}"
    if [[ "${needs_sudo}" -eq 1 ]]; then
      sudo_needed=1
      printf "  ${C_YELLOW}sudo${C_NC}  %s\n" "${description}"
    else
      printf "        %s\n" "${description}"
    fi
  done
  printf "\n"
  [[ "${sudo_needed}" -eq 1 ]] && \
    printf "${C_DIM}The lines marked sudo change files outside your home directory. Anything replaced is backed up beside itself with a .gosite.bak suffix.${C_NC}\n\n"

  # Exit 10 means "there is work pending". The installer reads it to decide
  # whether to offer to run this for real; 0 would be indistinguishable from
  # a machine that is already set up.
  [[ "${dry_run}" -eq 1 ]] && { info "--dry-run: nothing was changed."; return 10; }

  # Piped into bash there is no terminal to ask at, and silently editing /etc
  # is exactly what this command exists to stop happening.
  if [[ "${GOSITE_ASSUME_YES}" -ne 1 ]] && [[ ! -t 0 ]] && ! { : >/dev/tty; } 2>/dev/null; then
    warn "No terminal to confirm at; nothing was changed."
    printf "Run it yourself when you are ready:  ${C_CYAN}gosite setup${C_NC}\n"
    return 1
  fi

  _setup_confirm "Continue?" || { info "Cancelled; nothing was changed."; return 1; }

  # --- apply -----------------------------------------------------------------
  local failed=0
  for entry in "${GOSITE_SETUP_PLAN[@]}"; do
    IFS=$'\t' read -r action needs_sudo description <<<"${entry}"
    info "${description}"
    "${action}" || { warn "Step failed: ${description}"; failed=1; }
  done

  printf "\n"
  _setup_verify || failed=1

  [[ "${failed}" -eq 0 ]] || return 1
  ok "This machine is ready. Next: gosite infra up"
}

# Reads the answer from the terminal rather than stdin, so this still works
# when the command is part of a pipeline.
_setup_confirm() {
  [[ "${GOSITE_ASSUME_YES}" -eq 1 ]] && return 0
  local reply
  if [[ -t 0 ]]; then
    printf "${C_YELLOW}?${C_NC} %s [y/N] " "$1"
    read -r reply
  elif ! { : >/dev/tty; } 2>/dev/null; then
    return 1
  else
    printf "${C_YELLOW}?${C_NC} %s [y/N] " "$1" >/dev/tty
    read -r reply </dev/tty
  fi
  [[ "${reply}" =~ ^[Yy]$ ]]
}

# One entry in the plan: the function that does it, whether it needs sudo, and
# the line the user reads before deciding.
_setup_step() {
  GOSITE_SETUP_PLAN+=("$1"$'\t'"$2"$'\t'"$3")
}

# --- planning ----------------------------------------------------------------

_setup_plan_dns() {
  if dns_resolves; then
    ok "*.${GOSITE_TLD} already resolves to 127.0.0.1"
    return 0
  fi

  case "$(host_platform)" in
    macos)
      dnsmasq_installed || \
        _setup_step _setup_macos_install_dnsmasq 0 "install dnsmasq (brew install dnsmasq)"
      _setup_step _setup_macos_dnsmasq_conf 0 \
        "write $(_setup_macos_dnsmasq_target) - address=/.${GOSITE_TLD}/127.0.0.1"
      _setup_step _setup_macos_resolver 1 \
        "create /etc/resolver/${GOSITE_TLD} - send .${GOSITE_TLD} lookups to 127.0.0.1"
      _setup_step _setup_macos_restart_dnsmasq 1 "restart dnsmasq (sudo brew services restart dnsmasq)"
      ;;
    debian)
      dnsmasq_installed || \
        _setup_step _setup_debian_install_dnsmasq 1 "install dnsmasq (apt-get install -y dnsmasq)"

      if _setup_resolved_active; then
        _setup_resolved_stub_disabled || _setup_step _setup_debian_resolved_stub 1 \
          "edit /etc/systemd/resolved.conf - DNSStubListener=no, freeing port 53 for dnsmasq"
        _setup_resolvconf_linked || _setup_step _setup_debian_resolvconf 1 \
          "point /etc/resolv.conf at /run/systemd/resolve/resolv.conf"
        _setup_step _setup_debian_resolved_dropin 1 \
          "create /etc/systemd/resolved.conf.d/gosite.conf - route .${GOSITE_TLD} to 127.0.0.1"
      fi

      _setup_step _setup_debian_dnsmasq_dropin 1 \
        "create /etc/dnsmasq.d/gosite-${GOSITE_TLD}.conf - address=/.${GOSITE_TLD}/127.0.0.1"

      # Only when NetworkManager is the one running dnsmasq. Configuring both
      # its instance and the standalone service leaves two processes fighting
      # over 127.0.0.1:53, which fails in a way that looks like DNS flapping.
      _setup_nm_uses_dnsmasq && _setup_step _setup_debian_nm_dropin 1 \
        "create /etc/NetworkManager/dnsmasq.d/gosite-${GOSITE_TLD}.conf (NetworkManager runs dnsmasq here)"

      _setup_step _setup_debian_restart 1 "restart and enable dnsmasq, restart systemd-resolved"
      ;;
  esac
}

_setup_plan_tls() {
  if ! mkcert_available; then
    case "$(host_platform)" in
      macos)  _setup_step _setup_macos_install_mkcert 0 "install mkcert and nss (brew install mkcert nss)" ;;
      debian) _setup_step _setup_debian_install_mkcert 1 "install mkcert, libnss3-tools and ca-certificates (apt-get)" ;;
    esac
  elif [[ -z "$(nss_databases)" ]] || command -v certutil >/dev/null 2>&1; then
    : # nothing extra to install
  else
    case "$(host_platform)" in
      macos)  _setup_step _setup_macos_install_certutil 0 "install nss for certutil (brew install nss)" ;;
      debian) _setup_step _setup_debian_install_certutil 1 "install libnss3-tools for certutil (apt-get)" ;;
    esac
  fi

  mkcert_available && mkcert_ca_installed || \
    _setup_step _setup_mkcert_install 0 "run mkcert -install - create the local CA and trust it"

  # On Ubuntu, 'mkcert -install' does not reach the system store: it says so
  # and exits 0. Without this step curl, wget and git keep refusing the
  # certificate while every check that only looks for rootCA.pem passes.
  if [[ "$(host_platform)" == "debian" ]] && ! system_ca_trusted; then
    _setup_step _setup_debian_system_ca 1 \
      "copy the CA to /usr/local/share/ca-certificates and run update-ca-certificates"
  fi

  if [[ -n "$(nss_databases)" ]] && ! nss_ca_trusted; then
    _setup_step _setup_nss_trust 0 \
      "add the mkcert CA to $(nss_databases | wc -l | tr -d ' ') browser trust store(s) (Brave/Chrome/Firefox)"
  fi
}

# --- file helpers ------------------------------------------------------------

# Writes content to a path that may need root, backing up anything already
# there whose content differs. Returns 1 when the file already says exactly
# this, so a re-run is a no-op rather than a rewrite.
_setup_write_root_file() {
  local path="$1" content="$2"

  if [[ -f "${path}" ]] && [[ "$(cat "${path}" 2>/dev/null)" == "${content}" ]]; then
    return 0
  fi
  if [[ -f "${path}" ]]; then
    _sudo cp -p "${path}" "${path}.gosite.bak" || true
  fi

  _sudo mkdir -p "$(dirname "${path}")"
  printf '%s\n' "${content}" | _sudo tee "${path}" >/dev/null
}

# sudo only when we are not already root, so the same code runs in a container.
_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

_setup_header() {
  printf '# Written by gosite. Remove with: gosite setup --undo\n'
}

# --- macOS steps -------------------------------------------------------------

_setup_macos_install_dnsmasq() { brew install dnsmasq; }
_setup_macos_install_mkcert()  { brew install mkcert nss; }
_setup_macos_install_certutil() { brew install nss; }

# Homebrew's dnsmasq reads etc/dnsmasq.d/*.conf when the main file says so.
# Writing our own file there keeps gosite out of a config the user may own.
_setup_macos_dnsmasq_target() {
  local prefix; prefix="$(brew --prefix 2>/dev/null || echo /usr/local)"
  printf '%s/etc/dnsmasq.d/gosite-%s.conf' "${prefix}" "${GOSITE_TLD}"
}

_setup_macos_dnsmasq_conf() {
  local prefix conf target
  prefix="$(brew --prefix 2>/dev/null || echo /usr/local)"
  conf="${prefix}/etc/dnsmasq.conf"
  target="$(_setup_macos_dnsmasq_target)"

  mkdir -p "$(dirname "${target}")"
  printf '%s\naddress=/.%s/127.0.0.1\nlisten-address=127.0.0.1\n' \
    "$(_setup_header)" "${GOSITE_TLD}" > "${target}"

  # The drop-in only matters if the main config includes the directory.
  if [[ -f "${conf}" ]] && ! grep -qE "^conf-dir=.*dnsmasq\.d" "${conf}"; then
    cp -p "${conf}" "${conf}.gosite.bak"
    printf '\n%s\nconf-dir=%s/etc/dnsmasq.d/,*.conf\n' "$(_setup_header)" "${prefix}" >> "${conf}"
  fi
}

_setup_macos_resolver() {
  _setup_write_root_file "/etc/resolver/${GOSITE_TLD}" \
    "$(_setup_header)
nameserver 127.0.0.1"
}

_setup_macos_restart_dnsmasq() { _sudo brew services restart dnsmasq; }

# --- Debian/Ubuntu steps -----------------------------------------------------

_setup_debian_install_dnsmasq()  { _sudo apt-get install -y dnsmasq; }
# ca-certificates comes with update-ca-certificates, which is what puts the CA
# in the system bundle - mkcert cannot do it on this platform.
_setup_debian_install_mkcert()   { _sudo apt-get install -y mkcert libnss3-tools ca-certificates; }
_setup_debian_install_certutil() { _sudo apt-get install -y libnss3-tools; }

_setup_resolved_active() { systemctl is-active systemd-resolved >/dev/null 2>&1; }

# systemd-resolved's stub listener owns 127.0.0.53:53 and, with some
# configurations, 127.0.0.1:53 - which is the address dnsmasq needs.
_setup_resolved_stub_disabled() {
  grep -qE '^[[:space:]]*DNSStubListener[[:space:]]*=[[:space:]]*no' /etc/systemd/resolved.conf 2>/dev/null
}

_setup_debian_resolved_stub() {
  local conf=/etc/systemd/resolved.conf
  [[ -f "${conf}" ]] || return 0
  _sudo cp -p "${conf}" "${conf}.gosite.bak"
  # Both forms appear in the wild: commented-out default, and an explicit yes.
  _sudo sed -i \
    -e 's/^[[:space:]]*#[[:space:]]*DNSStubListener[[:space:]]*=.*/DNSStubListener=no/' \
    -e 's/^[[:space:]]*DNSStubListener[[:space:]]*=[[:space:]]*yes.*/DNSStubListener=no/' \
    "${conf}"
  # Neither line was there to rewrite: append it under [Resolve].
  _setup_resolved_stub_disabled || printf 'DNSStubListener=no\n' | _sudo tee -a "${conf}" >/dev/null
}

_setup_resolvconf_linked() {
  [[ "$(readlink -f /etc/resolv.conf 2>/dev/null)" == "/run/systemd/resolve/resolv.conf" ]]
}

_setup_debian_resolvconf() {
  [[ -e /run/systemd/resolve/resolv.conf ]] || return 0
  [[ -L /etc/resolv.conf ]] || _sudo cp -p /etc/resolv.conf /etc/resolv.conf.gosite.bak 2>/dev/null || true
  _sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
}

_setup_debian_resolved_dropin() {
  _setup_write_root_file "/etc/systemd/resolved.conf.d/gosite.conf" \
    "$(_setup_header)
[Resolve]
DNS=127.0.0.1
Domains=~${GOSITE_TLD}"
}

_setup_debian_dnsmasq_dropin() {
  _setup_write_root_file "/etc/dnsmasq.d/gosite-${GOSITE_TLD}.conf" \
    "$(_setup_header)
address=/.${GOSITE_TLD}/127.0.0.1
listen-address=127.0.0.1
bind-interfaces"
}

# True when NetworkManager is configured to run its own dnsmasq. Then the
# drop-in belongs in its directory, and the standalone service must not also
# claim the port.
_setup_nm_uses_dnsmasq() {
  systemctl is-active NetworkManager >/dev/null 2>&1 || return 1
  grep -rqE '^[[:space:]]*dns[[:space:]]*=[[:space:]]*dnsmasq' \
    /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/conf.d/ 2>/dev/null
}

_setup_debian_nm_dropin() {
  _setup_write_root_file "/etc/NetworkManager/dnsmasq.d/gosite-${GOSITE_TLD}.conf" \
    "$(_setup_header)
address=/.${GOSITE_TLD}/127.0.0.1"
}

_setup_debian_restart() {
  _setup_resolved_active && _sudo systemctl restart systemd-resolved || true
  _setup_nm_uses_dnsmasq && _sudo systemctl restart NetworkManager || true
  _sudo systemctl enable dnsmasq >/dev/null 2>&1 || true
  _sudo systemctl restart dnsmasq || {
    warn "dnsmasq did not restart. Usually something else holds port 53:"
    warn "  sudo ss -lnup 'sport = :53'"
    return 1
  }
}

# --- certificate steps -------------------------------------------------------

_setup_mkcert_install() {
  mkcert -install || {
    warn "mkcert -install failed. On macOS it needs Keychain authorisation."
    return 1
  }
}

_setup_nss_trust() { install_mkcert_ca_nss; }

# mkcert cannot do this on Ubuntu, so gosite does: the system bundle is what
# curl, wget and git read, and without the CA in it every tool but the browser
# still rejects the local certificates.
_setup_debian_system_ca() {
  local root; root="$(mkcert_ca_path)" || return 1
  [[ -f "${root}" ]] || { warn "No mkcert CA to install yet."; return 1; }

  if ! command -v update-ca-certificates >/dev/null 2>&1; then
    warn "update-ca-certificates is missing. Install it with: sudo apt-get install -y ca-certificates"
    return 1
  fi

  _sudo mkdir -p /usr/local/share/ca-certificates
  _sudo cp "${root}" /usr/local/share/ca-certificates/mkcert-rootCA.crt
  _sudo update-ca-certificates >/dev/null 2>&1 || {
    warn "update-ca-certificates failed; the system will not trust the local CA."
    return 1
  }
}

# --- verification ------------------------------------------------------------
#
# The same probes doctor uses. A setup that "succeeded" and left the machine
# unable to resolve a project domain has not succeeded.
_setup_verify() {
  local failed=0

  if dns_resolves; then
    ok "*.${GOSITE_TLD} resolves to 127.0.0.1"
  else
    err "*.${GOSITE_TLD} still does not resolve to 127.0.0.1"
    printf "${C_DIM}A resolver cache can lag a few seconds; try again before digging in.${C_NC}\n"
    failed=1
  fi

  if ! mkcert_available || ! mkcert_ca_installed; then
    err "mkcert CA is still missing"
    failed=1
  elif system_ca_trusted; then
    ok "mkcert CA present and trusted by the system"
  else
    err "the mkcert CA exists but the system does not trust it - curl, wget and git will still refuse"
    failed=1
  fi

  if [[ -z "$(nss_databases)" ]]; then
    : # no browser profile on this machine
  elif nss_ca_trusted; then
    ok "mkcert CA trusted by the browser stores"
  else
    warn "the CA is not in every browser store yet - close Brave/Chrome/Firefox and run 'gosite setup --tls' again"
  fi

  return "${failed}"
}

# --- undo --------------------------------------------------------------------
#
# Removes what gosite wrote and nothing else. The mkcert CA is deliberately
# left alone: other tools may have issued certificates from it, and removing a
# CA is 'mkcert -uninstall', which is the user's call to make.
_setup_undo() {
  local prefix removed=0 f
  prefix="$(brew --prefix 2>/dev/null || echo /usr/local)"

  info "Removing the files gosite setup wrote"
  for f in \
    "/etc/dnsmasq.d/gosite-${GOSITE_TLD}.conf" \
    "/etc/NetworkManager/dnsmasq.d/gosite-${GOSITE_TLD}.conf" \
    "/etc/systemd/resolved.conf.d/gosite.conf" \
    "/etc/resolver/${GOSITE_TLD}" \
    "${prefix}/etc/dnsmasq.d/gosite-${GOSITE_TLD}.conf"; do
    [[ -e "${f}" ]] || continue
    _sudo rm -f "${f}" && { ok "removed ${f}"; removed=1; }
  done

  [[ "${removed}" -eq 0 ]] && ok "Nothing to remove."

  printf "\n${C_DIM}Backups of anything replaced are beside the original with a .gosite.bak suffix.\n"
  printf "The mkcert CA is left in place; remove it yourself with 'mkcert -uninstall'.${C_NC}\n"
  printf "${C_DIM}Restart your resolver to pick this up: sudo systemctl restart dnsmasq systemd-resolved (Linux) or sudo brew services restart dnsmasq (macOS).${C_NC}\n"
}
