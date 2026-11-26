#!/bin/bash

set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <test command>" >&2
  exit 1
fi

if [ -n "${PR_BODY:-}" ]; then
  TESTS=$(printf '%s\n' "$PR_BODY" | tr -d '\r' | awk '/^```ci-tests[ \t]*$/ {f = 1; next} /^```[ \t]*$/ {f = 0} f')
fi
args=()
while read -r p; do
  if [ -n "$p" ]; then args+=(-m "$p"); fi
done <<< "${TESTS:-}"
# hspec's `--fail-on=empty` fails the run when every spec item was filtered out, which is the whole
# point of a selector: without it, a `-m` pattern that matches nothing exits 0. On this fork
# `REDUCED` (build.yml:103) is true for every branch push, and the short-circuit this replaces
# printed "No tests selected" and exited 0 — so master was green while hspec ran zero examples.
args+=(--fail-on=empty)

i=1
attempts=${ATTEMPTS:-1}
while [ "$i" -le "$attempts" ]; do
  if "$@" "${args[@]}"; then
    break
  elif [ "$?" -eq 124 ]; then
    echo "Attempt $i timed out."
  fi
  if [ "$i" -lt "$attempts" ]; then
    echo "Attempt $i failed, retrying..."
    sleep 1
  fi
  i=$((i + 1))
done
if [ "$i" -gt "$attempts" ]; then
  echo "Attempt $attempts failed."
  exit 1
fi
