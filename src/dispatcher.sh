#!/usr/bin/env bash
#
# Command router. Lazily sources the module that owns each verb so the CLI
# startup cost stays flat as commands are added.
#

load_command() {
  local file="${GOSITE_ROOT}/commands/cmd_$1.sh"
  [[ -f "${file}" ]] || fatal "Command module not found: ${file}"
  # shellcheck source=/dev/null
  source "${file}"
}

usage() {
  cat <<EOF
$(printf "${C_BOLD}gosite${C_NC}") ${GOSITE_VERSION} - Go + Cockpit CMS dev environments, Coolify-ready.

$(printf "${C_BOLD}USAGE${C_NC}")
  gosite [global flags] <command> [args]

$(printf "${C_BOLD}PROJECT COMMANDS${C_NC}")
  create <name>      Scaffold a new Go + Cockpit project in ./<name>
  start  [name]      Start a project stack (air hot reload + Cockpit)
  stop   [name]      Stop a project stack
  remove <name>      Tear down a project stack (containers, volumes, network links)
  list               List gosite projects and their container status

$(printf "${C_BOLD}INFRASTRUCTURE${C_NC}")
  infra up           Create '${GOSITE_NETWORK}' and start shared Postgres + Redis
  infra down         Stop the shared infrastructure
  infra status       Show shared infrastructure health
  infra logs [svc]   Tail shared infrastructure logs

$(printf "${C_BOLD}OTHER${C_NC}")
  doctor             Verify local dependencies (go, templ, air, docker, ...)
  help               Show this help
  version            Print the version

$(printf "${C_BOLD}GLOBAL FLAGS${C_NC}")
  -v, --verbose      Verbose output
  -y, --yes          Assume yes on confirmations
      --no-color     Disable colored output
  -V, --version      Print version and exit
  -h, --help         Show this help

$(printf "${C_DIM}Shared network: ${GOSITE_NETWORK}   Infra home: ${GOSITE_HOME}${C_NC}")
EOF
}

dispatch() {
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift || true

  case "${cmd}" in
    create)          load_command create; cmd_create "$@" ;;
    infra)           load_command infra;  cmd_infra  "$@" ;;
    list|ls)         load_command list;   cmd_list   "$@" ;;
    start|up)        load_command start;  cmd_start  "$@" ;;
    stop|down)       load_command stop;   cmd_stop   "$@" ;;
    remove|rm)       load_command remove; cmd_remove "$@" ;;
    doctor)          require_dependencies --report ;;
    version)         printf "gosite %s\n" "${GOSITE_VERSION}" ;;
    help|"")         usage ;;
    *)
      err "Unknown command: ${cmd}"
      printf "Run %s'gosite help'%s to see the available commands.\n" "${C_CYAN}" "${C_NC}" >&2
      return 127
      ;;
  esac
}
