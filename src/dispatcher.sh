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
  create <name>      Scaffold a new project in ${GOSITE_WORKSPACE}
                     flags: --here (cwd), --no-tailwind / --tailwind
                            --addons "A B" (specific), --no-addons (skip prompt)
  start  [name]      Start a project stack (air hot reload + Cockpit)
  stop   [name]      Stop a project stack
  restart[name]      Recreate containers (--build to rebuild the image)
  logs   [name]      Tail a project's logs ([app|cms] [-n N] [--no-follow])
  cd     <name>      Jump into a project directory (needs shell-init)
  path   <name>      Print a project's absolute path
  remove <name>      Delete a project entirely (--keep-source keeps the code)
  sync   [name]      Re-apply gosite's templates (compose, addons, .env)
  list               List gosite projects and their container status

$(printf "${C_BOLD}INFRASTRUCTURE${C_NC}")
  infra up           Create '${GOSITE_NETWORK}' and start shared Traefik + Redis
  infra down         Stop the shared infrastructure
  infra restart      Restart shared infrastructure
  infra status       Show shared infrastructure health
  infra logs [svc]   Tail shared infrastructure logs
  infra repair       Regenerate configs and recreate proxy (fix stale Traefik)
  dns                Check that *.${GOSITE_TLD} resolves to 127.0.0.1

$(printf "${C_BOLD}OTHER${C_NC}")
  open   <name>         Open a project directory in Finder
  doctor             Verify local dependencies (go, air, docker, compose)
  update             Update gosite to the latest version from GitHub
  shell-init         Emit shell integration; eval "\$(gosite shell-init)"
  help               Show this help
  version            Print the version

$(printf "${C_BOLD}GLOBAL FLAGS${C_NC}")
  -v, --verbose      Verbose output
  -y, --yes          Assume yes on confirmations
      --no-color     Disable colored output
  -V, --version      Print version and exit
  -h, --help         Show this help

$(printf "${C_DIM}Workspace: ${GOSITE_WORKSPACE}   Network: ${GOSITE_NETWORK}   Infra: ${GOSITE_HOME}${C_NC}")
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
    restart)         load_command restart; cmd_restart "$@" ;;
    logs)            load_command logs;   cmd_logs   "$@" ;;
    cd)              load_command cd;     cmd_cd     "$@" ;;
    open)            load_command open;   cmd_open   "$@" ;;
    path)            load_command cd;     cmd_path   "$@" ;;
    shell-init)      load_command cd;     cmd_shell_init ;;
    remove|rm)       load_command remove; cmd_remove "$@" ;;
    sync)            load_command sync;   cmd_sync   "$@" ;;
    update)          load_command update; cmd_update "$@" ;;
    doctor)          require_dependencies --report ;;
    dns)             load_command dns; cmd_dns ;;
    version)         printf "gosite %s\n" "${GOSITE_VERSION}" ;;
    help|"")         usage ;;
    *)
      err "Unknown command: ${cmd}"
      printf "Run %s'gosite help'%s to see the available commands.\n" "${C_CYAN}" "${C_NC}" >&2
      return 127
      ;;
  esac
}
