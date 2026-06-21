#!/usr/bin/env bash
# mock-agy-resolvable.sh — fixture mock for the resolvable-bug E2E run.
#
# Stands in for the real `agy` binary that ralph_runner.sh would launch
# inside the Docker sandbox. Reads $1 (the iteration number, matching
# the RALPH_ITERATION env var the runner exports) and applies the
# correct fix to src/calc.js on the first call. Subsequent calls are
# no-ops, but the harness will see the code change from iteration 1
# and short-circuit on the first successful TEST_CMD.
#
# This intentionally does NOT run the tests itself — the harness runs
# TEST_CMD (as the real ralph_runner.sh would) to keep the contract
# honest.

set -euo pipefail

iter="${1:-${RALPH_ITERATION:-1}}"
target="src/calc.js"

case "$iter" in
  1)
    # Correct fix: replace `a + b` with `a * b` inside the multiply body.
    sed -i 's|^function multiply(a, b) {$|function multiply(a, b) {|' "$target"
    sed -i '0,/return a + b;/{s|return a + b;|return a * b;|}' "$target"
    printf 'mock-agy-resolvable: applied correct fix on iter %s\n' "$iter" >&2
    ;;
  *)
    # No-op after iteration 1.
    printf 'mock-agy-resolvable: no-op on iter %s (fix already in place)\n' "$iter" >&2
    ;;
esac

exit 0
