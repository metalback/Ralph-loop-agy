#!/usr/bin/env bash
# mock-agy-irresoluble.sh — fixture mock for the circuit-breaker E2E run.
#
# Stands in for an agy agent that cannot figure out the right fix. On
# each iteration it applies a different wrong "fix" to src/calc.js so
# the multiply tests keep failing. After MAX_ITERATIONS=10 attempts the
# harness should trip the circuit breaker and exit 1, with progress.log
# preserving all 10 attempts.
#
# Reads $1 (iteration) or falls back to the RALPH_ITERATION env var.

set -euo pipefail

iter="${1:-${RALPH_ITERATION:-1}}"
target="src/calc.js"

# Each iteration applies a different wrong body to `multiply`. The
# patterns are intentionally diverse so the progress.log entries look
# like genuinely different approaches (and so the test always fails).
declare -a wrong_bodies=(
  'return a - b;'
  'return a / b;'
  'return Math.max(a, b);'
  'return a ** 2;'
  'return Number(a + "" + b);'
  'return a << b;'
  'return Math.abs(a - b);'
  'return Math.min(a, b);'
  'return a * 0;'
  'return a + b * 0;'
)

idx=$((iter - 1))
if (( idx < 0 || idx >= ${#wrong_bodies[@]} )); then
  printf 'mock-agy-irresoluble: iter %s out of range\n' "$iter" >&2
  exit 1
fi
body="${wrong_bodies[$idx]}"

python3 - "$target" "$body" <<'PY'
import sys, re, pathlib
target, body = sys.argv[1], sys.argv[2]
p = pathlib.Path(target)
src = p.read_text()
new = re.sub(r'function multiply\(a, b\) \{\s*return [^;]+;\s*\}',
             f'function multiply(a, b) {{\n  {body}\n}}',
             src, count=1, flags=re.MULTILINE)
p.write_text(new)
PY

printf 'mock-agy-irresoluble: iter %s -> %s\n' "$iter" "$body" >&2
exit 0
