#!/usr/bin/env bash
#
# Local TLS and DNS support for *.<TLD> domains.
#
# Certificates are issued by mkcert, whose CA is trusted by the system, so
# https://<project>.test loads without browser warnings. DNS is expected to be
# a dnsmasq wildcard pointing *.<TLD> at 127.0.0.1.
#

project_domain()     { printf '%s.%s' "$1" "${GOSITE_TLD}"; }
project_cms_domain() { printf 'cms.%s.%s' "$1" "${GOSITE_TLD}"; }

# --- DNS ---------------------------------------------------------------------
# True when the resolver actually answers for an arbitrary name under the TLD,
# which is the only check that matters. A wildcard is required so new projects
# work without touching any config.
dns_resolves() {
  local probe="gosite-dns-probe.${GOSITE_TLD}"
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "${probe}" 2>/dev/null | grep -q '^ip_address: 127\.0\.0\.1'
  elif command -v getent >/dev/null 2>&1; then
    getent hosts "${probe}" 2>/dev/null | grep -q '^127\.0\.0\.1'
  else
    return 1
  fi
}

dns_setup_hint() {
  printf 'gosite can do this for you:  gosite setup\n\n'
  printf 'Or, by hand:\n\n'

  case "$(host_platform 2>/dev/null || echo unknown)" in
    macos)
      cat <<EOF
    brew install dnsmasq
    echo 'address=/.${GOSITE_TLD}/127.0.0.1' >> \$(brew --prefix)/etc/dnsmasq.d/gosite-${GOSITE_TLD}.conf
    sudo brew services restart dnsmasq
    sudo mkdir -p /etc/resolver
    echo 'nameserver 127.0.0.1' | sudo tee /etc/resolver/${GOSITE_TLD}
EOF
      ;;
    debian|linux)
      # systemd-resolved holds port 53, so dnsmasq cannot take it until the
      # stub listener is off; resolved then forwards the TLD back to dnsmasq.
      cat <<EOF
    sudo apt-get install -y dnsmasq
    sudo sed -i 's/^#\\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    printf '[Resolve]\\nDNS=127.0.0.1\\nDomains=~${GOSITE_TLD}\\n' | sudo tee /etc/systemd/resolved.conf.d/gosite.conf
    printf 'address=/.${GOSITE_TLD}/127.0.0.1\\nlisten-address=127.0.0.1\\n' | sudo tee /etc/dnsmasq.d/gosite-${GOSITE_TLD}.conf
    sudo systemctl restart systemd-resolved && sudo systemctl enable --now dnsmasq
EOF
      ;;
    *)
      cat <<EOF
    Point *.${GOSITE_TLD} at 127.0.0.1 with whatever resolver this system uses.
    dnsmasq does it with:  address=/.${GOSITE_TLD}/127.0.0.1
EOF
      ;;
  esac

  printf '\nVerify with:  getent hosts anything.%s\n' "${GOSITE_TLD}"
}

# --- certificates ------------------------------------------------------------
mkcert_available() { command -v mkcert >/dev/null 2>&1; }

# The CA exists on disk, so mkcert can sign with it. NOT the same as the system
# trusting it - see system_ca_trusted.
mkcert_ca_installed() {
  local root; root="$(mkcert -CAROOT 2>/dev/null)" || return 1
  [[ -n "${root}" && -f "${root}/rootCA.pem" ]]
}

mkcert_ca_path() {
  local root; root="$(mkcert -CAROOT 2>/dev/null)" || return 1
  printf '%s/rootCA.pem' "${root}"
}

# True when the operating system's own trust store contains the mkcert CA -
# what curl, wget, git and Safari consult.
#
# Worth checking separately, and the reason is a real trap: on Ubuntu
# 'mkcert -install' prints "Installing to the system store is not yet supported
# on this Linux" and exits 0. The CA is created, mkcert can sign, every check
# based on "does rootCA.pem exist" passes - and curl still refuses the
# certificate. Trust has to be installed by hand there, which is what
# gosite setup does.
system_ca_trusted() {
  local root; root="$(mkcert_ca_path)" || return 1
  [[ -f "${root}" ]] || return 1

  case "$(host_platform)" in
    macos)
      security verify-cert -c "${root}" >/dev/null 2>&1
      ;;
    *)
      # Compare the certificate body rather than a subject line: the system
      # bundle is base64 with no human-readable subjects in it. One line from
      # the middle of the PEM is unique enough to identify it.
      local marker bundle
      marker="$(sed -n '3p' "${root}")"
      [[ -n "${marker}" ]] || return 1
      for bundle in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem /etc/pki/tls/certs/ca-bundle.crt; do
        [[ -f "${bundle}" ]] || continue
        grep -qF "${marker}" "${bundle}" && return 0
      done
      return 1
      ;;
  esac
}

# True when the certificate's subjectAltName covers every name given.
#
# A certificate on disk is not proof of a working certificate: one issued
# before the CMS host existed, or for a different TLD, is still a file.
cert_covers_domains() {
  local cert="$1"; shift
  local names dom

  # -text rather than '-ext subjectAltName': macOS ships LibreSSL, which does
  # not have -ext and answers "unknown option". Reading that as "the
  # certificate covers nothing" would re-issue every certificate on every
  # start, on the one platform where they were all correct.
  names="$(openssl x509 -in "${cert}" -noout -text 2>/dev/null \
           | grep -A1 'Subject Alternative Name')" || return 1
  [[ -n "${names}" ]] || return 1

  for dom in "$@"; do
    case "${names}" in
      *"DNS:${dom}"*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Issues one certificate per project covering <name>.<TLD> and *.<name>.<TLD>,
# which is what makes cms.<name>.<TLD> valid too. A wildcard only matches a
# single label, so a shared *.<TLD> certificate could not cover the CMS host.
#
# Re-issues when the certificate is missing, when it does not cover those two
# names, or when Traefik's dynamic file for it is gone. That last case is the
# one that used to look like a gosite bug: the .pem sat there, correct and
# unused, while Traefik served its own default certificate and the browser
# reported ERR_CERT_AUTHORITY_INVALID.
ensure_project_cert() {
  local name="$1"
  local cert="${GOSITE_CERTS_DIR}/${name}.pem"
  local key="${GOSITE_CERTS_DIR}/${name}-key.pem"
  local dyn="${GOSITE_DYNAMIC_DIR}/${name}.yml"
  local domain; domain="$(project_domain "${name}")"

  if [[ -f "${cert}" && -f "${key}" ]] \
     && cert_covers_domains "${cert}" "${domain}" "*.${domain}"; then
    # The certificate is good; make sure Traefik is told about it either way.
    [[ -f "${dyn}" ]] || info "Restoring Traefik's certificate config for ${domain}"
    write_cert_dynamic_config "${name}"
    return 0
  fi

  if ! mkcert_available; then
    warn "mkcert not found; HTTPS for ${domain} will not work. Run: gosite setup"
    return 1
  fi
  if ! mkcert_ca_installed; then
    warn "mkcert's local CA is not installed. Run: gosite setup"
    return 1
  fi

  # Remove first: mkcert reuses an existing file, so a certificate missing a
  # name would otherwise survive the re-issue that exists to add it.
  rm -f "${cert}" "${key}"

  mkdir -p "${GOSITE_CERTS_DIR}"
  info "Issuing certificate for ${domain} and *.${domain}"
  if ! mkcert -cert-file "${cert}" -key-file "${key}" \
        "${domain}" "*.${domain}" >/dev/null 2>&1; then
    warn "mkcert failed; continuing without HTTPS for this project."
    return 1
  fi
  chmod 0644 "${cert}" "${key}"

  write_cert_dynamic_config "${name}"
  ok "Certificate issued."
}

# Traefik picks certificates up from its watched dynamic directory, so adding a
# project never requires restarting the proxy.
write_cert_dynamic_config() {
  local name="$1"
  mkdir -p "${GOSITE_DYNAMIC_DIR}"
  cat > "${GOSITE_DYNAMIC_DIR}/${name}.yml" <<EOF
# Generated by gosite for ${name}. Do not edit.
tls:
  certificates:
    - certFile: /certs/${name}.pem
      keyFile: /certs/${name}-key.pem
EOF
}

remove_project_cert() {
  local name="$1"
  rm -f "${GOSITE_CERTS_DIR}/${name}.pem" \
        "${GOSITE_CERTS_DIR}/${name}-key.pem" \
        "${GOSITE_DYNAMIC_DIR}/${name}.yml"
}

# --- browser trust (NSS) ------------------------------------------------------
#
# Brave, Chrome, Chromium and Firefox do not read the operating system's trust
# store: each keeps an NSS database of its own. 'mkcert -install' therefore
# leaves them untouched on Linux, and a perfectly valid certificate still shows
# ERR_CERT_AUTHORITY_INVALID - the failure that looks like a broken certificate
# and is actually a missing CA in one specific place.
#
# Idempotent and never fatal: a machine with no browser, or a browser holding
# the database open, must not stop a project from starting.
install_mkcert_ca_nss() {
  mkcert_available && mkcert_ca_installed || return 0

  local dbs; dbs="$(nss_databases)"
  [[ -n "${dbs}" ]] || return 0

  if ! command -v certutil >/dev/null 2>&1; then
    warn "certutil not found, so Brave/Chrome/Firefox will not trust the local CA. Run: gosite setup --tls"
    return 1
  fi

  local root db failed=0
  root="$(mkcert -CAROOT)/rootCA.pem"

  while IFS= read -r db; do
    [[ -n "${db}" ]] || continue
    certutil -d "sql:${db}" -L 2>/dev/null | grep -q "${GOSITE_MKCERT_CA_NAME}" && continue

    if certutil -d "sql:${db}" -A -t "C,," -n "${GOSITE_MKCERT_CA_NAME}" -i "${root}" 2>/dev/null; then
      ok "Local CA trusted by ${db}"
    else
      # Almost always a running browser holding a lock on cert9.db.
      warn "Could not write to ${db}; close the browser and run 'gosite setup --tls'."
      failed=1
    fi
  done <<<"${dbs}"

  return "${failed}"
}
