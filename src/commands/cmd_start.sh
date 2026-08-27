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

  # Projects created before a certificate existed get one on first start.
  [[ -n "${GOSITE_APP_DOMAIN:-}" ]] && ensure_project_cert "${GOSITE_PROJECT}" >/dev/null 2>&1 || true

  container_running "${GOSITE_PROXY_HOST}" || warn "Proxy is not running; local domains will not resolve. Run 'gosite infra up'."
  container_running "${GOSITE_REDIS_HOST}" || warn "Redis is not running. Run 'gosite infra up' or the app will fail to boot."

  # Addons are baked into the CMS image, and Cockpit caches which addons exist
  # until its version changes. Clearing that cache as the container comes up is
  # what makes a newly installed addon actually appear in the panel.
  clear_cockpit_module_cache "${dir}"

  info "Starting '${GOSITE_PROJECT}' (air hot reload)"
  compose -p "${GOSITE_PROJECT}" -f "${dir}/docker-compose.yml" --project-directory "${dir}" up -d --build

  _seed_home_model "${dir}"

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

# Best-effort starter content: registers COCKPIT_API_TOKEN as an admin API key
# (idempotent) and creates a "home" singleton via the ModelManager addon, so a
# fresh project has a model to edit instead of a blank admin. Failures are
# non-fatal - the site works without it, and the seed re-runs on the next start.
_seed_home_model() {
  local dir="$1"
  local tok cms_port db base
  tok="$(grep -E '^COCKPIT_API_TOKEN=' "${dir}/.env" 2>/dev/null | cut -d= -f2-)"
  [[ -n "${tok}" ]] || return 0

  cms_port="${GOSITE_CMS_PORT}"
  db="${GOSITE_PROJECT}"
  base="https://${GOSITE_CMS_DOMAIN}"

  # Wait for the CMS API to actually serve requests - the root responds long
  # before FrankenPHP finishes wiring the REST routes on first boot. Prefer the
  # Traefik HTTPS host (works whether or not the host port is published); fall
  # back to the mapped localhost port. 200/401/412 mean the API is up.
  local _ code=000
  for _ in $(seq 1 45); do
    code="$(curl -sk --max-time 3 -o /dev/null -w '%{http_code}' -H "api-key: ${tok}" "${base}/api/models" 2>/dev/null)"
    case "${code}" in
      200|401|412) break ;;
    esac
    code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' -H "api-key: ${tok}" "http://localhost:${cms_port}/api/models" 2>/dev/null)"
    case "${code}" in
      200|401|412) base="http://localhost:${cms_port}"; break ;;
    esac
    sleep 2
  done
  [[ "${code}" == "000" ]] && { warn "CMS API not reachable yet; starter content not seeded."; return 0; }

  # Make sure the token is a registered admin API key (ModelManager ACLs on
  # /api/models/save require it). Upsert never touches an existing key.
  docker exec "${GOSITE_MONGO_HOST}" mongosh "mongodb://127.0.0.1:27017/${db}" \
    --quiet --eval "db.system_api_keys.updateOne({key:'${tok}'},{\$setOnInsert:{name:'gosite-seed',key:'${tok}',role:'admin',active:true}},{upsert:true})" \
    >/dev/null 2>&1 || { warn "Could not register the API key; starter content not seeded."; return 0; }

  if curl -sk --max-time 5 -H "api-key: ${tok}" "${base}/api/models" 2>/dev/null \
      | grep -q '"name":"home"'; then
    return 0  # already seeded
  fi

  # The CMS can answer HTTP before it has fully wired its modules, so the
  # first save can fail silently. Retry until the model shows up in the API.
  local attempt=0
  while [[ "${attempt}" -lt 5 ]]; do
    attempt=$(( attempt + 1 ))
    curl -sk --max-time 5 -X POST -H "api-key: ${tok}" -H 'Content-Type: application/json' \
      -d '{"model":{"name":"home","type":"singleton","fields":[{"name":"headline","type":"text"},{"name":"intro","type":"textarea"}]}}' \
      "${base}/api/models/save" >/dev/null 2>&1
    if curl -sk --max-time 5 -H "api-key: ${tok}" "${base}/api/models" 2>/dev/null \
        | grep -q '"name":"home"'; then
      ok "Created starter 'home' singleton (headline + intro). Edit it in the CMS."
      return 0
    fi
    sleep 3
  done
  warn "Could not create the starter 'home' singleton; create it in the CMS admin."
}
