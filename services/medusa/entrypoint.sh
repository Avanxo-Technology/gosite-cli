#!/usr/bin/env bash
#
# gosite-medusa entrypoint: migrate, idempotent seed, then serve.
#
# Runs from the compiled server root (.medusa/server copied to /app), so
# medusa-config.js and the compiled seed are plain JS: no ts-node in production.
# The seed runs on every start and only creates what is missing (design D5), so
# a restart is cheap and never rewrites the store owner's edits.
set -euo pipefail

# Medusa falls back to the secret "supersecret" when these are unset, which
# would let anyone forge admin tokens. Checked here and not in medusa-config,
# because the build loads the config without any secret.
missing=()
for var in JWT_SECRET COOKIE_SECRET DATABASE_URL; do
  value="${!var:-}"
  [[ -n "${value// /}" ]] || missing+=("${var}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "gosite-medusa: ${missing[*]} must be set; refusing to start" >&2
  exit 1
fi

cd /app

echo "gosite-medusa: applying database migrations"
medusa db:migrate

echo "gosite-medusa: seeding (idempotent)"
medusa exec ./src/scripts/seed.js

echo "gosite-medusa: starting server"
exec medusa start
