#!/usr/bin/env bats
# gosite versions: the pure parsing and classification helpers in
# src/lib/versions.sh. No network: versions_hub_tags is not exercised here.

setup() {
  load helpers
  _env_reset
  # shellcheck source=../src/lib/versions.sh
  source "${BATS_TEST_DIRNAME}/../src/lib/versions.sh"
}

# _classify <current> <candidates...> -> "status|target|patch-target"
_classify() {
  versions_classify "$@" | tr '\t' '|'
}

@test "split: a tag is taken from the reference" {
  run versions_split_ref "golang:1.26-alpine"
  [ "${output}" = "$(printf 'golang\t1.26-alpine')" ]
}

@test "split: a reference without a tag means latest" {
  run versions_split_ref "alpine"
  [ "${output}" = "$(printf 'alpine\tlatest')" ]
}

@test "split: a registry port is not mistaken for a tag" {
  run versions_split_ref "localhost:5000/app"
  [ "${output}" = "$(printf 'localhost:5000/app\tlatest')" ]
}

@test "parse: prefix, version and suffix are separated" {
  run versions_parse_tag "core-2.14.0"
  [ "${output}" = "core-|2.14.0|" ]
  run versions_parse_tag "8.0-windowsservercore-ltsc2025"
  [ "${output}" = "|8.0|-windowsservercore-ltsc2025" ]
}

@test "parse: a tag without a version prints nothing" {
  run versions_parse_tag "latest"
  [ -z "${output}" ]
}

@test "classify: a newer patch in the same line is a patch" {
  run _classify "1.26.1" "1.26.1" "1.26.10"
  [ "${output}" = "patch|1.26.10|1.26.10" ]
}

@test "classify: a newer minor beats a patch and keeps the patch target" {
  run _classify "1.26-alpine" 1.26-alpine 1.26.10-alpine 1.27-alpine 1.27.3-alpine
  [ "${output}" = "minor|1.27.3-alpine|1.26.10-alpine" ]
}

@test "classify: a one-part tag treats newer versions in its major as patches" {
  run _classify "16-alpine" 16-alpine 16.4-alpine
  [ "${output}" = "patch|16.4-alpine|16.4-alpine" ]
}

@test "classify: a major release is reported even when a patch exists in the current line" {
  run _classify "16-alpine" 16-alpine 16.4-alpine 18-alpine
  [ "${output}" = "major|18-alpine|16.4-alpine" ]
}

@test "classify: a newer major line is reported as major" {
  run _classify "3.24" 3.24 3.24.2 4.0.0
  [ "${output}" = "major|4.0.0|3.24.2" ]
}

@test "classify: variant suffixes do not count as newer tags" {
  run _classify "8.0" 8.0 8.0-windowsservercore-ltsc2025
  [ "${output}" = "current|8.0|" ]
}

@test "classify: a year-like tag is not read as a major version" {
  run _classify "3.24" 3.24 20260805
  [ "${output}" = "current|3.24|" ]
}

@test "classify: a floating tag is reported as floating" {
  run _classify "latest" 3.24.2
  [ "${output}" = "floating||" ]
}

@test "classify: no candidates with the same prefix means unknown" {
  run _classify "core-2.14.0" 2.14.1 core-latest
  [ "${output}" = "unknown||" ]
}

@test "classify: the current tag is current when nothing is newer" {
  run _classify "9.9" 9.9 9.8
  [ "${output}" = "current|9.9|" ]
}

@test "scan: finds Dockerfile FROM lines and skips stage aliases and variables" {
  local f="${BATS_TEST_TMPDIR}/Dockerfile"
  cat > "${f}" <<'EOF'
FROM golang:1.26-alpine AS builder
FROM --platform=linux/amd64 alpine:latest
FROM builder
FROM ${BASE}
FROM scratch
EOF
  run versions_scan_file "${f}"
  [ "${output}" = "$(printf '1\tgolang\t1.26-alpine\n2\talpine\tlatest')" ]
}

@test "scan: finds compose image lines and keeps a bare name as an image" {
  local f="${BATS_TEST_TMPDIR}/docker-compose.yml"
  cat > "${f}" <<'EOF'
services:
  db:
    image: postgres:16-alpine
  cache:
    image: "redis:7-alpine"
  minio:
    image: coollabsio/minio:latest
  bare:
    image: traefik
EOF
  run versions_scan_file "${f}"
  [ "${output}" = "$(printf '3\tpostgres\t16-alpine\n5\tredis\t7-alpine\n7\tcoollabsio/minio\tlatest\n9\ttraefik\tlatest')" ]
}
