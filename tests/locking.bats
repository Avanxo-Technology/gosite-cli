#!/usr/bin/env bats
# with_lock: mkdir-based mutual exclusion (tasks 4.1/4.2) - bounded wait,
# trap-driven release even on failure, and orphan reclamation by pid + age.

setup() {
  load helpers
  _env_reset
  export GOSITE_LOCK_TIMEOUT=2
}

_test_target() { printf '%s\n' "${GOSITE_TEST_HOME}/state.tsv"; }

_hold_and_count() {
  # Increments a counter while holding the lock; used for mutual exclusion.
  local target="$1" n="$2"
  with_lock "${target}" _bump "${target}" "${n}"
}

_bump() {
  local target="$1" n="$2" current=0
  [[ -f "${target}" ]] && current="$(cat "${target}")"
  # The critical section must be the only writer: read-modify-write.
  sleep 0.1
  printf '%s\n' "$(( current + n ))" > "${target}"
}

@test "runs the wrapped function and releases the lock" {
  local target; target="$(_test_target)"
  run with_lock "${target}" _bump "${target}" 5
  [ "$status" -eq 0 ]
  [ "$(cat "${target}")" == "5" ]
  [ ! -e "${target}.lock" ]
}

@test "the wrapped function's failure still releases the lock" {
  local target; target="$(_test_target)"
  _fail() { return 3; }
  run with_lock "${target}" _fail
  [ "$status" -eq 3 ]
  [ ! -e "${target}.lock" ]
}

@test "serialize concurrent critical sections: no lost update" {
  local target; target="$(_test_target)"
  : > "${target}"
  local i
  for i in 1 2 3 4; do
    _hold_and_count "${target}" 10 &
  done
  wait
  # Four serialized +10 increments must not lose a single update.
  [ "$(cat "${target}")" == "40" ]
  [ ! -e "${target}.lock" ]
}

@test "times out with a clear error when the lock stays held" {
  local target; target="$(_test_target)"
  mkdir -p "${target}.lock"
  printf '%s\n' $$ > "${target}.lock/pid"   # a live pid: this shell

  run with_lock "${target}" _bump "${target}" 1
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Timed out"
  [ -e "${target}.lock" ]    # holder keeps its lock
  rm -rf "${target}.lock"
}

@test "reclaims an orphaned lock whose pid is gone" {
  local target; target="$(_test_target)"
  mkdir -p "${target}.lock"
  printf '999999\n' > "${target}.lock/pid"   # no such process
  # Age it past GOSITE_LOCK_STALE_SECONDS so reclaim is allowed.
  touch -t 202001010000 "${target}.lock"

  run with_lock "${target}" _bump "${target}" 7
  [ "$status" -eq 0 ]
  [ "$(cat "${target}")" == "7" ]
  [ ! -e "${target}.lock" ]
}

@test "a fresh orphan (dead pid, young lock) is not reclaimed" {
  local target; target="$(_test_target)"
  mkdir -p "${target}.lock"
  printf '999999\n' > "${target}.lock/pid"

  run with_lock "${target}" _bump "${target}" 7
  [ "$status" -ne 0 ]
  [ -e "${target}.lock" ]
  rm -rf "${target}.lock"
}

@test "contention between two processes resolves without leftovers" {
  local target; target="$(_test_target)"
  : > "${target}"
  # One slow holder and one waiter: the waiter must eventually acquire.
  _slow() { sleep 0.5; printf 'slow\n' > "${target}"; }
  with_lock "${target}" _slow &
  local holder=$!
  sleep 0.1
  # The waiter runs after the holder: it reads "slow" (arithmetic treats the
  # unquoted word as 0) and writes 0 - proof both critical sections ran in
  # order, serialized by the lock.
  run with_lock "${target}" _bump "${target}" 0
  wait "${holder}"
  [ "$status" -eq 0 ]
  [ "$(cat "${target}")" == "0" ]
  [ ! -e "${target}.lock" ]
}

@test "publish_atomic replaces content fully or not at all" {
  local target; target="$(_test_target)"
  printf 'old\n' > "${target}"
  printf 'new-contents\n' | publish_atomic "${target}"
  [ "$(cat "${target}")" == "new-contents" ]
  # No stray temp files beside the destination.
  [ "$(ls -A "${GOSITE_TEST_HOME}" | grep -c '^\.gosite\.' || true)" -eq 0 ]
}
