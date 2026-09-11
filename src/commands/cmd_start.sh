#!/usr/bin/env bash
#
# gosite start [project]
#
# Brings up a project's local stack: the Go app running under air (hot reload)
# plus its own Cockpit container, both attached to the shared network.
#

cmd_start() {
  require_dependencies

  local follow=0 name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --logs|-f) follow=1; shift ;;
      *)         name="$1"; shift ;;
    esac
  done

  local dir; dir="$(resolve_project_dir "${name}")"

  # shellcheck source=/dev/null
  source "${dir}/${GOSITE_MARKER}"

  registry_register "${dir}"
  ensure_cockpit_storage "${dir}"
  ensure_network

  # Projects created before a certificate existed get one on first start, and
  # so does one whose certificate or Traefik config went missing since.
  if [[ -n "${GOSITE_APP_DOMAIN:-}" ]]; then
    ensure_project_cert "${GOSITE_PROJECT}" >/dev/null 2>&1 || true
    # The certificate is only half of it: on Linux the browsers keep their own
    # trust store, so a valid certificate still warns until the CA is in there.
    install_mkcert_ca_nss >/dev/null 2>&1 || true
  fi

  container_running "${GOSITE_PROXY_HOST}" || warn "Proxy is not running; local domains will not resolve. Run 'gosite infra up'."
  container_running "${GOSITE_REDIS_HOST}" || warn "Redis is not running. Run 'gosite infra up' or the app will fail to boot."

  # Addons are baked into the CMS image, and Cockpit caches which addons exist
  # until its version changes. Clearing that cache as the container comes up is
  # what makes a newly installed addon actually appear in the panel.
  clear_cockpit_module_cache "${dir}"

  info "Starting '${GOSITE_PROJECT}' (air hot reload)"
  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" up -d --build

  _register_api_key "${dir}"

  if [[ -n "${GOSITE_APP_DOMAIN:-}" ]]; then
    ok "App -> https://${GOSITE_APP_DOMAIN}"
    ok "CMS -> https://${GOSITE_CMS_DOMAIN}"
    printf "${C_DIM}Also on http://localhost:%s and http://localhost:%s.${C_NC}\n" \
      "${GOSITE_APP_PORT}" "${GOSITE_CMS_PORT}"
  else
    ok "App -> http://localhost:${GOSITE_APP_PORT}"
    ok "CMS -> http://localhost:${GOSITE_CMS_PORT}"
  fi
  printf "${C_DIM}Edit any .go/.html file and air rebuilds automatically. Logs: gosite start --logs${C_NC}\n"

  if [[ "${follow}" -eq 1 ]]; then
    compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" logs -f --tail=50
  fi
}

# Nudges the CMS into registering COCKPIT_API_TOKEN as an admin API key.
#
# The registration itself lives in the Webapp addon, which does it on the first
# request to /api/*. All this has to do is make that first request, so the key
# exists before the application asks for content rather than after.
#
# It used to upsert into Mongo with mongosh instead, and that was the bug behind
# "the key is there but the CMS says 412": Cockpit's API gate does not read
# system/api_keys, it reads a registry cached in app memory - Redis here, so it
# survives every container rebuild - and an empty registry is stored as a value,
# not as a miss, so nothing ever expires it. Writing straight to Mongo left the
# two out of step with no path back. See src/knowledge/cockpit-api-key.md.
#
# Non-fatal either way: the addon repairs itself on any later API request, so a
# CMS that is slow to boot costs nothing.
_register_api_key() {
  local dir="$1"
  local tok cms_port base

  tok="$(grep -E '^COCKPIT_API_TOKEN=' "${dir}/.env" 2>/dev/null | cut -d= -f2-)"
  [[ -n "${tok}" ]] || return 0

  cms_port="${GOSITE_CMS_PORT}"
  base="https://${GOSITE_CMS_DOMAIN}"

  # Wait for the CMS API to actually serve requests - the root responds long
  # before FrankenPHP finishes wiring the REST routes on first boot. Prefer the
  # Traefik HTTPS host (works whether or not the host port is published); fall
  # back to the mapped localhost port. A 200 means the key registered; 401/412
  # mean the API is up but something else is wrong, which is worth reporting
  # rather than waiting out.
  # `|| code=000` on both, and it is load-bearing rather than defensive.
  #
  # main.sh runs under `set -e`, and an assignment takes the exit status of its
  # command substitution - so a curl that cannot resolve the host exits 6 and
  # kills `gosite start` outright. Every line of this function says it is
  # non-fatal, and it was the one thing that could fail the command.
  #
  # It fires whenever *.test does not resolve: CI always, and any machine where
  # `gosite setup` has not configured local DNS. The site itself is fine on its
  # published ports, so failing the start was wrong twice over.
  local _ code=000
  for _ in $(seq 1 45); do
    code="$(curl -sk --max-time 3 -o /dev/null -w '%{http_code}' -H "api-key: ${tok}" "${base}/api/models" 2>/dev/null)" || code=000
    case "${code}" in
      200|401|412) break ;;
    esac
    code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' -H "api-key: ${tok}" "http://localhost:${cms_port}/api/models" 2>/dev/null)" || code=000
    case "${code}" in
      200|401|412) base="http://localhost:${cms_port}"; break ;;
    esac
    sleep 2
  done

  case "${code}" in
    200) return 0 ;;
    000) warn "CMS API not reachable yet; the API key registers on the first request instead." ;;
    *)   warn "The CMS answered ${code} for the API key; check COCKPIT_API_TOKEN in ${dir}/.env." ;;
  esac

  return 0
}
