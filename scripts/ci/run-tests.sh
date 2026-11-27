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
# hspec's `--fail-on=empty` ("fail if all spec items have been filtered") fails the run when every
# spec item was filtered out, which is the whole point of a selector: without it, a `-m` pattern that
# matches nothing exits 0. On this fork the `reduced` output of maybe-release is true for every branch
# push, and the short-circuit this replaces printed "No tests selected" and exited 0 — so master was
# green while hspec ran zero examples.
#
# The option was added in hspec-core 2.9. The GHC 8.10.7 leg resolves 2.7.10, whose only `fail-on`
# entry is the argument-less `--fail-on-focused`; GetOpt prefix-matches `--fail-on` onto it and aborts
# the run before executing anything ("option `--fail-on' doesn't allow an argument", seen on the first
# full dispatch of this leg). Ask the binary instead of pinning a version, and let the example count
# below carry the guard where the option is unavailable.
if "$@" --fail-on=empty --help > /dev/null 2>&1; then
  args+=(--fail-on=empty)
  empty_guard=hspec
else
  empty_guard=examples
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT

i=1
attempts=${ATTEMPTS:-1}
while [ "$i" -le "$attempts" ]; do
  set +e
  "$@" ${args[@]+"${args[@]}"} 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e
  # Every hspec formatter ends with `pluralize total "example"`, so "<n> example" is the executed
  # count on 2.7 and 2.11 alike. No such line means the binary never got as far as an example.
  executed=$(awk 'match($0, /[0-9]+ example/) {n = substr($0, RSTART, RLENGTH - 8)} END {print n + 0}' "$log")
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 124 ]; then
      echo "Attempt $i timed out."
    elif [ "$executed" -eq 0 ]; then
      echo "hspec executed $executed examples ($empty_guard guard) and exited $status."
    fi
  elif [ "$executed" -gt 0 ]; then
    break
  else
    echo "hspec executed $executed examples ($empty_guard guard); the selection matched nothing."
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
