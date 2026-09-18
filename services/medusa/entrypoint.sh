#!/usr/bin/env bash
#
# gosite-medusa entrypoint: migrate, idempotent seed, then serve.
#
# Runs from the compiled server root (.medusa/server copied to /app), so
# medusa-config.js and the compiled seed are plain JS: no ts-node in production.
# The seed runs on every start and only creates what is missing (design D5), so
# a restart is cheap and never rewrites the store owner's edits.
set -euo pipefail

cd /app

echo "gosite-medusa: applying database migrations"
medusa db:migrate

echo "gosite-medusa: seeding (idempotent)"
medusa exec ./src/scripts/seed.js

echo "gosite-medusa: starting server"
exec medusa start
