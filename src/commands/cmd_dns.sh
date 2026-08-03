#!/usr/bin/env bash
#
# gosite dns - report whether *.<TLD> resolves to 127.0.0.1, and how to fix it.
#

cmd_dns() {
  if dns_resolves; then
    ok "*.${GOSITE_TLD} resolves to 127.0.0.1."
    printf "${C_DIM}Any <project>.%s and cms.<project>.%s will reach the local proxy.${C_NC}\n" \
      "${GOSITE_TLD}" "${GOSITE_TLD}"
    return 0
  fi

  err "*.${GOSITE_TLD} does not resolve to 127.0.0.1."
  printf "\n"
  dns_setup_hint
  return 1
}
