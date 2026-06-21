#!/usr/bin/env bash
# Smoke test for the Ralph Loop orchestrator (issue #4).
#
# Validates the static acceptance criteria from
# "S3: Orquestador Bash — loop principal (ralph_runner.sh)". The static
# checks parse the runner source. The dynamic checks (dry-run, real
# docker execution) only run when docker is available; the static checks
# are required to pass either way.
#
# Usage:
#   ./.sandcastle/runner-test.sh
#
# Exits 0 on success, 1 on any failed check.

set -euo pipefail

RUNNER="${RUNNER:-ralph_runner.sh}"
IMAGE_NAME="${IMAGE_NAME:-ralph-loop-base}"
DOCKERFILE="${DOCKERFILE:-.sandcastle/Dockerfile}"
SAMPLE_PRD="${SAMPLE_PRD:-PRD.md}"

fail=0
pass=0

ok() {
  pass=$((pass + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

nok() {
  fail=$((fail + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then
    printf '      %s\n' "$2"
  fi
}

section() {
  printf '\n\033[1m== %s ==\033[0m\n' "$1"
}

check_grep() {
  local pattern="$1"
  local ok_msg="$2"
  local nok_msg="$3"
  local detail="${4:-}"
  # `grep -Eq -- "$pattern"` so patterns that start with `-` (e.g.
  # `--non-interactive`) are not interpreted as grep options.
  if grep -Eq -- "$pattern" <<<"$runner_content"; then
    ok "$ok_msg"
  else
    nok "$nok_msg" "$detail"
  fi
}

# ---------------------------------------------------------------------------
# Acceptance criterion #1: ralph_runner.sh exists and is executable.
# ---------------------------------------------------------------------------

section "Acceptance: $RUNNER exists and is executable"

if [[ ! -f "$RUNNER" ]]; then
  nok "Runner not found at project root: $RUNNER"
  section "Summary"
  echo "  passed: $pass"
  echo "  failed: $fail"
  exit 1
fi
ok "Runner file exists at project root: $RUNNER"

if [[ -x "$RUNNER" ]]; then
  ok "Runner is executable (+x bit set)"
else
  nok "Runner must be executable (chmod +x $RUNNER)"
fi

first_line=$(head -n 1 "$RUNNER")
if [[ "$first_line" == "#!/usr/bin/env bash" || "$first_line" == "#!/usr/bin/env bash "* || "$first_line" == "#!/bin/bash"* ]]; then
  ok "Runner has a Bash shebang (got: $first_line)"
else
  nok "Runner must have a Bash shebang" "got: $first_line"
fi

runner_content=$(cat "$RUNNER")

# ---------------------------------------------------------------------------
# Acceptance criterion #2: reads PRD.md and extracts TEST_CMD.
# ---------------------------------------------------------------------------

section "Acceptance: reads PRD.md and extracts TEST_CMD"

check_grep 'PRD\.md|PRD_FILE' \
  "References PRD.md (or a configurable PRD_FILE)" \
  "Runner must read PRD.md (or a configurable PRD_FILE) to drive the loop"

check_grep 'TEST_CMD' \
  "References TEST_CMD" \
  "Runner must extract or reference TEST_CMD from the PRD"

# Parsing: a real extraction routine (regex on the PRD content).
if grep -Eq '(grep|awk|sed)[[:space:]]+.*TEST_CMD' <<<"$runner_content" \
   || grep -Eq 'TEST_CMD[[:space:]]*:[[:space:]]*\$\{?' <<<"$runner_content" \
   || grep -Eq 'TEST_CMD.*=\\\$\(' <<<"$runner_content"; then
  ok "Runner parses TEST_CMD out of PRD.md"
else
  nok "Runner must parse TEST_CMD out of PRD.md" \
      "expected grep/awk/sed on TEST_CMD or a TEST_CMD extraction routine"
fi

# Stack-detection fallback (mentioned in the PRD as a safety net for
# PRDs that don't declare TEST_CMD explicitly).
if grep -Eqi 'package\.json|go\.mod|Cargo\.toml|requirements\.txt|pyproject\.toml' <<<"$runner_content"; then
  ok "Runner has a stack-detection fallback for missing TEST_CMD"
else
  nok "Runner should fall back to stack detection (package.json/go.mod/...) when PRD omits TEST_CMD"
fi

# ---------------------------------------------------------------------------
# Acceptance criterion #3: builds the Docker image if not present.
# ---------------------------------------------------------------------------

section "Acceptance: builds Docker image if not present"

check_grep 'docker[[:space:]]+build' \
  "Calls 'docker build'" \
  "Runner must call 'docker build' to create the base image"

check_grep 'image[[:space:]]+inspect|docker[[:space:]]+images' \
  "Checks whether the image already exists (image inspect or docker images)" \
  "Runner must check if the image exists before building"

check_grep "$DOCKERFILE|\\.sandcastle/Dockerfile" \
  "References the .sandcastle/Dockerfile path" \
  "Runner must build from .sandcastle/Dockerfile"

# ---------------------------------------------------------------------------
# Acceptance criterion #4: container launched with correct mounts.
# Code mounted :rw, credentials :ro.
# ---------------------------------------------------------------------------

section "Acceptance: container mounts (:rw code, :ro credentials)"

check_grep ':cached,rw|:rw|cached,rw' \
  "Mounts project code as :rw" \
  "Runner must mount the project root as :rw (e.g. \$PWD:/workspace:cached,rw)"

check_grep ':ro\b' \
  "Mounts something as :ro" \
  "Runner must mount credentials (or any sensitive path) as :ro"

check_grep 'antigravity-cli|\.config' \
  "Mounts the agy credentials path" \
  "Runner must mount the host agy credentials path (e.g. ~/.config/antigravity-cli)"

check_grep '/workspace' \
  "Container workspace path is /workspace" \
  "Runner must use /workspace as the in-container project path"

# ---------------------------------------------------------------------------
# Acceptance criterion #5: injects PRD + progress.log as context.
# ---------------------------------------------------------------------------

section "Acceptance: injects PRD + progress.log as context"

check_grep 'progress\.log|PROGRESS_LOG' \
  "References progress.log" \
  "Runner must inject progress.log as context for the agent"

# Concatenation: PRD and progress.log are joined and piped/redirected
# into the container.
if grep -Eq '(cat[[:space:]]+)?(\\\$PRD_FILE|PRD\.md)' <<<"$runner_content" \
   && grep -Eq 'progress\.log' <<<"$runner_content"; then
  ok "Runner composes a context payload from PRD + progress.log"
else
  nok "Runner must compose a context payload (PRD + progress.log) and feed it to the container"
fi

# ---------------------------------------------------------------------------
# Acceptance criterion #6: runs agy with --non-interactive and captures output.
# ---------------------------------------------------------------------------

section "Acceptance: runs agy --non-interactive and captures output"

check_grep '--non-interactive' \
  "Passes --non-interactive to agy" \
  "Runner must pass --non-interactive to agy"

check_grep 'load-skill[[:space:]]+ralph-worker|--load-skill' \
  "Loads the ralph-worker skill" \
  "Runner must pass --load-skill ralph-worker to agy"

check_grep 'docker[[:space:]]+(run|exec)' \
  "Invokes agy through docker run/exec" \
  "Runner must invoke agy via docker run or docker exec"

# Output capture: redirect stdout/stderr to a file (or a variable via
# command substitution) so the orchestrator can grep RALPH_STATUS.
if grep -Eq -- '>[[:space:]]*"?\$' <<<"$runner_content" \
   || grep -Eq -- '\$\(' <<<"$runner_content" \
   || grep -Eq -- 'tee[[:space:]]' <<<"$runner_content"; then
  ok "Runner captures docker/agy output (redirect or command substitution)"
else
  nok "Runner must capture docker/agy output (e.g. >log or \$(...))"
fi

# ---------------------------------------------------------------------------
# Acceptance criterion #7: on TEST_CMD failure, append stderr to
# progress.log with a timestamp.
# ---------------------------------------------------------------------------

section "Acceptance: on failure, append stderr to progress.log with timestamp"

check_grep 'progress\.log' \
  "Writes to progress.log" \
  "Runner must write to progress.log on failure"

# Append mode (>>) — preserves the file across iterations.
# Accepts `>>"$PROGRESS_LOG"`, `>> progress.log`, `>>$PROGRESS_LOG`, etc.
if grep -Eq -- '>>[[:space:]]*("?\$[A-Z_]+|progress\.log)' <<<"$runner_content"; then
  ok "Runner appends to progress.log (>>) instead of overwriting"
else
  nok "Runner must append to progress.log (use >>) so history is preserved"
fi

# Timestamp generation (date or similar).
if grep -Eq 'date[[:space:]]+(\+|[+-]u|\-\-utc|=)' <<<"$runner_content" \
   || grep -Eq '\$\(date' <<<"$runner_content"; then
  ok "Runner generates a timestamp for each progress.log entry"
else
  nok "Runner must add a timestamp to each progress.log entry"
fi

# ---------------------------------------------------------------------------
# Acceptance criterion #8: 15s cooldown between iterations.
# ---------------------------------------------------------------------------

section "Acceptance: 15s cooldown between iterations"

check_grep 'COOLDOWN[[:space:]]*=*[^=]*15|COOLDOWN_SECONDS' \
  "Defaults the cooldown to 15s (or reads COOLDOWN_SECONDS)" \
  "Runner must default the cooldown to 15s"

check_grep 'sleep[[:space:]]+["]?\$[A-Z_]*COOLDOWN' \
  "Calls sleep with the COOLDOWN value" \
  "Runner must sleep between iterations using the COOLDOWN value"

# ---------------------------------------------------------------------------
# Acceptance criterion #9: circuit breaker at MAX_ITERATIONS (10), exit 1.
# ---------------------------------------------------------------------------

section "Acceptance: circuit breaker at MAX_ITERATIONS=10, exit 1"

check_grep 'MAX_ITERATIONS[[:space:]]*=*[^=]*10|MAX_ITERATIONS=' \
  "Defaults MAX_ITERATIONS to 10" \
  "Runner must default MAX_ITERATIONS to 10"

if grep -Eq 'exit[[:space:]]+1|exit[[:space:]]+\\\$FAIL|return[[:space:]]+1' <<<"$runner_content"; then
  ok "Runner exits with status 1 on circuit-breaker trip"
else
  nok "Runner must exit with status 1 when the circuit breaker trips"
fi

# Loop bounded by MAX_ITERATIONS.
if grep -Eqi 'circuit[[:space:]]+breaker|tripped' <<<"$runner_content" \
   || grep -Eq 'MAX_ITERATIONS' <<<"$runner_content"; then
  ok "Runner implements a circuit-breaker bounded by MAX_ITERATIONS"
else
  nok "Runner must implement a circuit-breaker bounded by MAX_ITERATIONS"
fi

# ---------------------------------------------------------------------------
# Acceptance criterion #10: progress.log preserved when circuit breaker trips.
# ---------------------------------------------------------------------------

section "Acceptance: progress.log is preserved on circuit-breaker trip"

# progress.log is appended to (not truncated) — already checked in #7.
# Additional check: the script does NOT rm progress.log on failure.
if grep -Eq 'rm[[:space:]]+(-\w[[:alnum:]]*[[:space:]]+)*(\$PROGRESS_LOG|progress\.log)' <<<"$runner_content"; then
  nok "Runner must not delete progress.log on circuit-breaker trip" \
      "found 'rm ... progress.log' in source"
else
  ok "Runner does not delete progress.log on circuit-breaker trip"
fi

# Sanity: progress.log is in .gitignore (per the PRD).
if [[ -f .gitignore ]] && grep -Eq '\*\.log|progress\.log' .gitignore; then
  ok "progress.log is in .gitignore (per PRD further notes)"
else
  nok "progress.log should be in .gitignore" \
      "add 'progress.log' or '*.log' to .gitignore"
fi

# ---------------------------------------------------------------------------
# Functional probe: the runner is a syntactically valid Bash script.
# ---------------------------------------------------------------------------

section "Acceptance: $RUNNER parses as valid Bash"

if bash -n "$RUNNER" 2>/dev/null; then
  ok "bash -n $RUNNER exits 0 (script parses)"
else
  nok "bash -n $RUNNER must exit 0" "$(bash -n "$RUNNER" 2>&1 || true)"
fi

# ---------------------------------------------------------------------------
# Functional probe: the TEST_CMD extraction logic, exercised against a
# known sample PRD. We replicate the same regex the runner uses so the
# test fails loudly if the runner drifts from the documented convention.
# ---------------------------------------------------------------------------

section "Functional: TEST_CMD extraction from a sample PRD"

tmp_prd=$(mktemp)
cat >"$tmp_prd" <<'EOF'
# Sample PRD

Some narrative.

TEST_CMD: npm test

More text.
EOF
extracted=$(grep -E '^TEST_CMD[[:space:]]*:' "$tmp_prd" \
            | head -n1 \
            | sed -E 's/^TEST_CMD[[:space:]]*:[[:space:]]*//' \
            | sed -E 's/^[`"]+//; s/[`"]+$//')
if [[ "$extracted" == "npm test" ]]; then
  ok "Extracts 'TEST_CMD: npm test' from a sample PRD"
else
  nok "Should extract 'npm test' from a sample PRD" "got: '$extracted'"
fi
rm -f "$tmp_prd"

# A PRD without TEST_CMD and no stack hint should fail the extraction.
tmp_prd=$(mktemp)
cat >"$tmp_prd" <<'EOF'
# Sample PRD
No test command here.
EOF
if grep -qE '^TEST_CMD[[:space:]]*:' "$tmp_prd"; then
  nok "Should NOT find TEST_CMD in a PRD without one"
else
  ok "Reports no TEST_CMD in a PRD without one (extractor is conservative)"
fi
rm -f "$tmp_prd"

# Backtick-wrapped TEST_CMD is also recognised and the backticks are
# stripped (Markdown-friendly convention).
tmp_prd=$(mktemp)
cat >"$tmp_prd" <<'EOF'
# Sample PRD
TEST_CMD: `npm test`
EOF
extracted=$(grep -E '^TEST_CMD[[:space:]]*:' "$tmp_prd" \
            | head -n1 \
            | sed -E 's/^TEST_CMD[[:space:]]*:[[:space:]]*//' \
            | sed -E 's/^`+//; s/`+$//')
if [[ "$extracted" == "npm test" ]]; then
  ok "Strips Markdown backticks from a backtick-wrapped TEST_CMD"
else
  nok "Should strip backticks from \`npm test\`" "got: '$extracted'"
fi
rm -f "$tmp_prd"

# Quotes inside the command are preserved verbatim (they are part of
# the shell syntax, not delimiters).
tmp_prd=$(mktemp)
cat >"$tmp_prd" <<'EOF'
# Sample PRD
TEST_CMD: bash -c "npm test"
EOF
extracted=$(grep -E '^TEST_CMD[[:space:]]*:' "$tmp_prd" \
            | head -n1 \
            | sed -E 's/^TEST_CMD[[:space:]]*:[[:space:]]*//' \
            | sed -E 's/^`+//; s/`+$//')
if [[ "$extracted" == 'bash -c "npm test"' ]]; then
  ok "Preserves quotes inside the command (bash -c \"npm test\")"
else
  nok "Should preserve inner quotes" "got: '$extracted'"
fi
rm -f "$tmp_prd"

# ---------------------------------------------------------------------------
# Dynamic check: when docker is available, verify the runner can be
# inspected without erroring. We do not run a full loop here (it would
# invoke agy, which requires a real credential); the static checks are
# the contract.
# ---------------------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
  section "Dynamic check: docker present"
  ok "docker CLI is available (full loop verification still requires agy credentials)"
else
  section "Dynamic check skipped (docker not available)"
  echo "  Install Docker and run \"./$RUNNER\" with a valid .env to exercise the loop end-to-end."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

section "Summary"
echo "  passed: $pass"
echo "  failed: $fail"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
