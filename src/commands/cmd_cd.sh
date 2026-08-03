#!/usr/bin/env bash
#
# gosite path <project>   Print a project's absolute path (machine readable)
# gosite cd   <project>   Jump into a project directory
# gosite shell-init       Emit the shell function that makes `cd` work
#
# A child process cannot change its parent shell's working directory, so
# `gosite cd` needs a shell function wrapper. `gosite path` is the primitive
# that wrapper (and any script) calls.
#

# Prints only the path, nothing else, so it is safe inside $(...).
cmd_path() {
  resolve_project_dir "${1:-}"
}

cmd_cd() {
  local dir; dir="$(resolve_project_dir "${1:-}")"

  # The shell function exports this before calling us; when it is set we just
  # print the path and let the wrapper do the actual cd.
  if [[ -n "${GOSITE_SHELL_INTEGRATION:-}" ]]; then
    printf '%s' "${dir}"
    return 0
  fi

  err "'gosite cd' needs shell integration: a subprocess cannot change your shell's directory."
  printf "\nAdd this to your %s and reload:\n\n" "$(_shell_profile)"
  printf "    %s\n\n" 'eval "$(gosite shell-init)"'
  printf "Or jump there right now with:\n\n"
  printf "    cd \"\$(gosite path %s)\"\n\n" "$(basename "${dir}")"
  printf "%s\n" "${dir}"
  return 1
}

_shell_profile() {
  case "${SHELL##*/}" in
    zsh)  echo "~/.zshrc" ;;
    bash) echo "~/.bashrc" ;;
    *)    echo "shell profile" ;;
  esac
}

# Emits a wrapper function that intercepts `cd` and delegates everything else
# to the real binary. Meant to be used as: eval "$(gosite shell-init)"
cmd_shell_init() {
  cat <<'EOF'
# gosite shell integration - added by: eval "$(gosite shell-init)"
gosite() {
  case "${1:-}" in
    cd)
      local __gosite_dir
      __gosite_dir="$(GOSITE_SHELL_INTEGRATION=1 command gosite cd "${2:-}")" || return $?
      [ -n "${__gosite_dir}" ] && cd "${__gosite_dir}" || return 1
      ;;
    *)
      command gosite "$@"
      ;;
  esac
}
EOF
}
