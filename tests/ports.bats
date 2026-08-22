#!/usr/bin/env bats
# Port allocation: pick-and-reserve must be one indivisible critical section
# (task 4.7), reserved ports must never collide, and failures must not leak
# reservations. Docker-independent: docker ps failing is tolerated.

setup() {
  load helpers
  _env_reset
  # Keep every test's scan inside a high, almost certainly free range.
  export GOSITE_PORT_MIN=24000
  export GOSITE_PORT_MAX=24999
}

@test "allocate_ports reserves two distinct ports and records them" {
  # No `run` here: the ports land in a global the subshell would swallow.
  allocate_ports demo 24000
  local app cms
  read -r app cms <<< "${GOSITE_ALLOCATED_PORTS}"
  [ -n "${app}" ] && [ -n "${cms}" ]
  [ "${app}" != "${cms}" ]
  grep -q "^demo	${app}	${cms}$" "${GOSITE_PORTS_FILE}"
}

@test "a second allocation for the same project replaces, not duplicates" {
  allocate_ports demo 24000 >/dev/null
  allocate_ports demo 24000 >/dev/null
  [ "$(wc -l < "${GOSITE_PORTS_FILE}" | tr -d ' ')" -eq 1 ]
}

@test "sequential allocations never hand out reserved ports" {
  allocate_ports one 24000 >/dev/null
  read -r p1a p1b <<< "${GOSITE_ALLOCATED_PORTS}"

  allocate_ports two 24000 >/dev/null
  read -r p2a p2b <<< "${GOSITE_ALLOCATED_PORTS}"

  [ "${p2a}" != "${p1a}" ] && [ "${p2a}" != "${p1b}" ]
  [ "${p2b}" != "${p1a}" ] && [ "${p2b}" != "${p1b}" ]
}

@test "release_ports frees the project's ports for the next allocation" {
  allocate_ports demo 24000 >/dev/null
  read -r p1 p2 <<< "${GOSITE_ALLOCATED_PORTS}"

  run release_ports demo
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${GOSITE_PORTS_FILE}" | tr -d ' ')" -eq 0 ]

  allocate_ports other 24000 >/dev/null
  read -r q1 q2 <<< "${GOSITE_ALLOCATED_PORTS}"
  [ "${q1}" == "${p1}" ]
  [ "${q2}" == "${p2}" ]
}

@test "concurrent allocations never pick the same port" {
  local i out dups
  for i in 1 2 3 4 5 6 7 8; do
    ( allocate_ports "conc${i}" 24100 >/dev/null 2>&1 ) &
  done
  wait

  out="$(awk '{print $2"\n"$3}' "${GOSITE_PORTS_FILE}" | sort)"
  dups="$(echo "${out}" | uniq -d)"
  [ -z "${dups}" ]
  [ "$(wc -l < "${GOSITE_PORTS_FILE}" | tr -d ' ')" -eq 8 ]
}

@test "an exhausted range fails with an error naming the range" {
  # Two projects pin the only two ports of a tiny range.
  allocate_ports first 24990 >/dev/null   # 24990, 24991
  allocate_ports second 24992 >/dev/null  # 24992, 24993
  # 24994/24995 are still free, so shrink the ceiling to exhaust instead.
  export GOSITE_PORT_MAX=24993
  run allocate_ports third 24990
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "24990-24993"
  # The failed allocation must not have left a reservation behind.
  ! grep -q "^third	" "${GOSITE_PORTS_FILE}"
}

@test "listening ports are skipped by the scan" {
  # Occupy a port with a real listener. python3's http.server binds and
  # listens without needing a connection; output goes to /dev/null so the
  # background job never holds bats' pipes (the suite would hang otherwise).
  command -v python3 >/dev/null 2>&1 || skip "python3 not available"
  local held=24080
  python3 -m http.server "${held}" --bind 127.0.0.1 >/dev/null 2>&1 &
  local listener=$!
  sleep 1

  allocate_ports demo "${held}" >/dev/null
  read -r app _ <<< "${GOSITE_ALLOCATED_PORTS}"
  kill "${listener}" 2>/dev/null || true
  wait "${listener}" 2>/dev/null || true
  [ "${app}" -gt "${held}" ]
}
