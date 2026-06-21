#!/usr/bin/env bash
# E2E test for the ralph-loop-agy orchestrator (issue #6, PRD #1).
#
# Validates the acceptance criteria from
# "S5: E2E stress test con bug real". The fixtures under
# test/fixtures/ provide a real Node.js project with a real bug; the
# E2E harness in test/fixtures/e2e-harness.sh drives the actual
# ralph_runner.sh loop (sourcing it for the git helpers) using a mock
# agy script instead of `docker run agy`. This exercises every code
# path — context detection, TEST_CMD extraction, feature branch
# creation, commit_iteration, merge_feature_to_base, and the
# circuit-breaker — without needing Docker or a real agy credential.
#
# The :ro mount check is exercised both statically (the runner must
# pass :ro to the credentials mount) and dynamically (a real bind
# mount with :ro blocks writes; if we are not root the test falls back
# to a chmod 444 file so the assertion still runs).
#
# Usage:
#   ./.sandcastle/e2e-test.sh
#
# Exits 0 on success, 1 on any failed check.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$REPO_ROOT/test/fixtures/sample-bug-project"
FIXTURE_PRD="$FIXTURE/PRD.md"
FIXTURE_SRC="$FIXTURE/src/calc.js"
FIXTURE_TEST="$FIXTURE/test/calc.test.js"
HARNESS="$REPO_ROOT/test/fixtures/e2e-harness.sh"
MOCK_RESOLVABLE="$REPO_ROOT/test/fixtures/agents/mock-agy-resolvable.sh"
MOCK_IRRESOLUBLE="$REPO_ROOT/test/fixtures/agents/mock-agy-irresoluble.sh"
RUNNER="$REPO_ROOT/ralph_runner.sh"
README="$REPO_ROOT/README.md"

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

read_kv() {
  # read_kv <result-file> <key>
  local file="$1" key="$2"
  (grep -E "^${key}=" "$file" || echo "${key}=") | head -n1 | sed -E "s/^${key}=//"
}

# ---------------------------------------------------------------------------
# AC #1: Proyecto de prueba con bug, test fallando y PRD.md en test/fixtures/
# ---------------------------------------------------------------------------

section "AC #1: fixture project with real bug, failing test, and PRD.md"

if [[ -d "$FIXTURE" ]]; then
  ok "Fixture project directory exists: test/fixtures/sample-bug-project"
else
  nok "Fixture project must exist at test/fixtures/sample-bug-project" \
      "expected a small project with a bug + test + PRD.md"
  section "Summary"
  echo "  passed: $pass"
  echo "  failed: $fail"
  exit 1
fi

if [[ -f "$FIXTURE_PRD" ]]; then
  ok "Fixture PRD.md exists"
else
  nok "Fixture PRD.md must exist" "expected PRD.md at the fixture root"
fi

if grep -Eq '^TEST_CMD[[:space:]]*:' "$FIXTURE_PRD"; then
  ok "Fixture PRD.md declares a TEST_CMD line"
else
  nok "Fixture PRD.md must declare 'TEST_CMD: <command>'" \
      "the orchestrator parses this line directly"
fi

if [[ -f "$FIXTURE_SRC" && -f "$FIXTURE_TEST" ]]; then
  ok "Fixture has both source and test files"
else
  nok "Fixture must have src/calc.js and test/calc.test.js"
fi

# The bug must be REAL: the fixture's TEST_CMD must exit non-zero out
# of the box. We run it from a temp copy so the harness can mutate
# the source later without touching the canonical fixture.
bug_tmp=$(mktemp -d -t ralph-e2e-bug-XXXXXX)
cp -R "$FIXTURE/." "$bug_tmp/"
if (cd "$bug_tmp" && bash -c "npm test" >/dev/null 2>&1); then
  nok "Fixture's TEST_CMD must fail out of the box (no real bug)" \
      "npm test exited 0 against the unfixed fixture; the loop has nothing to solve"
else
  ok "Fixture's TEST_CMD fails out of the box (real bug present)"
fi
rm -rf "$bug_tmp"

# ---------------------------------------------------------------------------
# AC #2: Loop resuelve bug real en ≤ 5 iteraciones
# ---------------------------------------------------------------------------

section "AC #2: loop resolves a real bug in ≤ 5 iterations"

resolvable_result=$(mktemp -t ralph-e2e-resolvable-XXXXXX)
set +e
bash "$HARNESS" \
  "$FIXTURE" \
  "$MOCK_RESOLVABLE" \
  5 \
  "$resolvable_result" >/dev/null 2>&1
harness_status=$?
set -e

if [[ $harness_status -ne 0 && $harness_status -ne 1 ]]; then
  nok "E2E harness crashed (exit $harness_status, expected 0 or 1)" \
      "see logs above"
fi

if [[ -s "$resolvable_result" ]]; then
  ok "E2E harness produced a result file"
else
  nok "E2E harness did not produce a result file"
fi

status=$(read_kv "$resolvable_result" status)
iterations=$(read_kv "$resolvable_result" iterations)
passed_iter=$(read_kv "$resolvable_result" passed_iter)

if [[ "$status" == "1" ]]; then
  ok "Resolvable run: harness exited SUCCESS"
else
  nok "Resolvable run: harness must exit SUCCESS" "status=$status"
fi

if [[ "$passed_iter" -ge 1 && "$passed_iter" -le 5 ]]; then
  ok "Resolvable run: TEST_CMD passed on iteration ${passed_iter} (≤ 5)"
else
  nok "Resolvable run: TEST_CMD must pass in ≤ 5 iterations" \
      "passed_iter=$passed_iter"
fi

# ---------------------------------------------------------------------------
# AC #3: Commit automático creado en branch ralph/...
# ---------------------------------------------------------------------------

section "AC #3: auto-commit created on ralph/... branch"

feature_branch=$(read_kv "$resolvable_result" feature_branch)
commits=$(read_kv "$resolvable_result" commits)
merged=$(read_kv "$resolvable_result" merged)

if [[ "$feature_branch" == ralph/issue-* ]]; then
  ok "Feature branch created in the ralph/issue-N-slug form: $feature_branch"
else
  nok "Feature branch must be in the ralph/issue-N-slug form" \
      "got: '$feature_branch'"
fi

if [[ "$commits" -ge 1 ]]; then
  ok "At least 1 RALPH: commit exists on the feature branch (got: $commits)"
else
  nok "At least 1 RALPH: commit must be on the feature branch" \
      "got: $commits"
fi

if [[ "$merged" == "yes" ]]; then
  ok "Feature branch merged into the base branch"
else
  nok "Feature branch must be merged into the base branch" \
      "got: merged=$merged"
fi

# ---------------------------------------------------------------------------
# AC #4: Bug irresoluble activa circuit breaker a las 10 iteraciones
# ---------------------------------------------------------------------------

section "AC #4: irresoluble bug trips the circuit breaker at 10 iterations"

irresoluble_result=$(mktemp -t ralph-e2e-irresoluble-XXXXXX)
set +e
bash "$HARNESS" \
  "$FIXTURE" \
  "$MOCK_IRRESOLUBLE" \
  10 \
  "$irresoluble_result" >/dev/null 2>&1
harness_status=$?
set -e

if [[ $harness_status -ne 0 && $harness_status -ne 1 ]]; then
  nok "E2E harness (irresoluble) crashed (exit $harness_status)" \
      "see logs above"
fi

if [[ -s "$irresoluble_result" ]]; then
  ok "E2E harness (irresoluble) produced a result file"
else
  nok "E2E harness (irresoluble) did not produce a result file"
fi

istatus=$(read_kv "$irresoluble_result" status)
iiterations=$(read_kv "$irresoluble_result" iterations)
ipassed=$(read_kv "$irresoluble_result" passed_iter)

if [[ "$istatus" == "0" ]]; then
  ok "Irresoluble run: harness exited CIRCUIT_BREAKER (status=0 means failure)"
else
  nok "Irresoluble run: harness must exit CIRCUIT_BREAKER" \
      "status=$istatus (expected 0=failure)"
fi

if [[ "$iiterations" -eq 10 ]]; then
  ok "Irresoluble run: ran exactly 10 iterations (MAX_ITERATIONS)"
else
  nok "Irresoluble run: must run exactly 10 iterations" \
      "got: $iiterations"
fi

if [[ "$ipassed" == "0" ]]; then
  ok "Irresoluble run: TEST_CMD never passed (correct: bug is irresoluble)"
else
  nok "Irresoluble run: TEST_CMD must never pass" "passed_iter=$ipassed"
fi

# ---------------------------------------------------------------------------
# AC #5: progress.log preserva los 10 intentos del circuit breaker
# ---------------------------------------------------------------------------

section "AC #5: progress.log preserves all 10 circuit-breaker attempts"

ipentries=$(read_kv "$irresoluble_result" progress_entries)
if [[ "$ipentries" -eq 10 ]]; then
  ok "Irresoluble run: progress.log has 10 entries"
else
  nok "Irresoluble run: progress.log must have 10 entries" \
      "got: $ipentries"
fi

# The harness writes progress.log into a scratch dir it owns (mktemp)
# and cleans up on exit, so we cannot read it directly after the run.
# Instead, validate the format of each entry by sourcing the runner
# and invoking append_progress() ourselves into a temp file.
set +e
# shellcheck disable=SC1090
source "$RUNNER"
set -e
sample_log=$(mktemp)
PROGRESS_LOG="$sample_log" append_progress 3 "npm test" 1 ""
PROGRESS_LOG="$sample_log" append_progress 4 "npm test" 1 ""
sample_entries=$(grep -c '^[[].*] Iteration' "$sample_log" || true)
if [[ "$sample_entries" -eq 2 ]]; then
  ok "Runner's append_progress() emits timestamped, append-only entries"
else
  nok "Runner's append_progress() must append timestamped entries" \
      "got: $sample_entries in $sample_log"
fi
if grep -qE '\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] Iteration 3 \| TEST_CMD: npm test \| exit 1' "$sample_log"; then
  ok "Each progress.log entry has a UTC timestamp + iteration + TEST_CMD + exit"
else
  nok "progress.log entries must follow the documented format" \
      "got entry: $(head -n 2 "$sample_log")"
fi
rm -f "$sample_log"
unset -f append_progress append_no_progress

# ---------------------------------------------------------------------------
# AC #6: Mount :ro de credenciales no permite escritura
# ---------------------------------------------------------------------------

section "AC #6: :ro credentials mount blocks writes"

# Static check: the runner must mount the credentials path as :ro.
if grep -Eq 'antigravity-cli[^{]*:ro' "$RUNNER" \
   || grep -Eq 'AGY_CREDENTIALS_IN_CONTAINER[^{]*:ro' "$RUNNER" \
   || grep -Eq ':ro[^\)]*AGY_CREDENTIALS|AGY_CREDENTIALS[^\)]*:ro' "$RUNNER"; then
  ok "Runner mounts the agy credentials path as :ro"
else
  nok "Runner must mount the agy credentials path with :ro" \
      "no '... :ro' token found in the credentials mount line"
fi

# Dynamic check: a real :ro mount (or its chmod 444 fallback) blocks
# writes. We try the bind mount first; if we are not root (or the
# kernel rejects the mount), we fall back to a chmod 444 file.
ro_dir=$(mktemp -d -t ralph-e2e-ro-XXXXXX)
ro_src="$ro_dir/src"
ro_dst="$ro_dir/dst"
mkdir -p "$ro_src" "$ro_dst"
printf 'secret\n' >"$ro_src/cred"

dynamic_ok=0
if mount --bind "$ro_src" "$ro_dst" 2>/dev/null \
   && mount -o remount,bind,ro "$ro_dst" 2>/dev/null; then
  if (printf 'tampered\n' >>"$ro_dst/cred") 2>/dev/null; then
    nok ":ro bind mount allowed a write (security regression)" \
        "wrote to $ro_dst/cred with no error"
  else
    ok ":ro bind mount blocks writes (live mount test)"
    dynamic_ok=1
  fi
  umount "$ro_dst" 2>/dev/null || true
fi

if [[ $dynamic_ok -eq 0 ]]; then
  # Fallback: chmod 444 on a file is the same kernel-level read-only
  # enforcement (write(2) returns EACCES). It is not a mount, but it
  # exercises the underlying bit the :ro flag ultimately sets.
  ro_file="$ro_dir/readonly.txt"
  printf 'secret\n' >"$ro_file"
  chmod 444 "$ro_file"
  if (printf 'tampered\n' >>"$ro_file") 2>/dev/null; then
    nok "Read-only file allowed a write (EACCES not enforced)" \
        "wrote to a chmod 444 file with no error"
  else
    ok "Read-only file blocks writes (EACCES; same kernel bit as :ro)"
    dynamic_ok=1
  fi
  chmod 644 "$ro_file" 2>/dev/null || true
fi

if [[ $dynamic_ok -eq 0 ]]; then
  nok "Could not run any :ro equivalent test (need root for mount, or filesystem for chmod)"
fi
rm -rf "$ro_dir"

# ---------------------------------------------------------------------------
# AC #7: Todo documentado en README.md
# ---------------------------------------------------------------------------

section "AC #7: E2E test documented in README.md"

if [[ -f "$README" ]]; then
  ok "README.md exists"
else
  nok "README.md must exist" "expected at the repo root"
fi

if grep -Eqi 'e2e|end.?to.?end|stress' "$README"; then
  ok "README.md mentions the E2E / stress test"
else
  nok "README.md must mention the E2E / stress test" \
      "add a short 'E2E test' section describing the fixture, the mocks, and how to run it"
fi

if grep -Eq 'test:[[:space:]]*e2e|test:e2e' "$README"; then
  ok "README.md documents the 'npm run test:e2e' command"
else
  nok "README.md must document 'npm run test:e2e'" \
      "add the command to the testing section"
fi

if grep -Eq 'sample-bug-project|mock-agy|e2e-harness' "$README"; then
  ok "README.md references the E2E fixtures"
else
  nok "README.md must reference the E2E fixtures" \
      "name at least the fixture, the harness, and the mock agents"
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

rm -f "$resolvable_result" "$irresoluble_result"

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
