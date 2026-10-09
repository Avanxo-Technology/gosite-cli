#!/usr/bin/env bash
# usage: run.sh <label> <site-src-dir> ; runs 2 tasks x 3 tools in a fresh copy of the site
set -u
LABEL=$1; SRC=$2; BENCH=$(cd "$(dirname "$0")" && pwd)
SITE=$(basename "$SRC"); OUT=$BENCH/$LABEL; mkdir -p "$OUT"
MODEL_OC=opencode-go/deepseek-v4.1-flash
# BENCH_PATH: optional directory put first on PATH (e.g. a `gosite` shim for an unreleased CLI).
[[ -n "${BENCH_PATH:-}" ]] && export PATH="${BENCH_PATH}:${PATH}"
TA="Do not edit or create any file. In this project, explain how a Forms submission from the website reaches Cockpit CMS and how it gets e-mailed. Name the files and settings involved. Answer in under 300 words."
TB="Do not edit or create any file. In this project, explain how you would add a new field to a Medusa store product and show it on the shop page. Name the files, APIs and commands involved. Answer in under 300 words."
for tool in claude opencode omp; do for t in A B; do
  W=$BENCH/work/$LABEL-$SITE-$tool-$t; rm -rf "$W"; mkdir -p "$(dirname "$W")"; rsync -a --exclude tmp "$SRC/" "$W/"
  P=$TA; [[ $t == B ]] && P=$TB
  f=$OUT/$SITE-$tool-$t
  ( cd "$W" && case $tool in
    claude)   claude -p --model haiku --permission-mode plan --no-session-persistence --output-format json "$P" ;;
    opencode) opencode run --format json --agent plan -m $MODEL_OC "$P" ;;
    omp)      omp -p --mode json --no-session "$P" ;;
  esac ) > "$f.json" 2> "$f.err" &
done; done; wait
