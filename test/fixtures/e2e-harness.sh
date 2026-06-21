#!/usr/bin/env bash
# e2e-harness.sh — fixture E2E driver for the ralph-loop-agy loop.
#
# Mirrors the loop body of ralph_runner.sh:main() but uses a mock agy
# script (passed as $2) instead of `docker run agy ...`. This lets us
# exercise the full ralph_runner.sh code path — git context detection,
# feature branch creation, commit iteration, merge into base, and
# progress.log accumulation — without needing Docker or a real agy
# credential. The harness is the contract for issue #6 acceptance
# criteria #2-#5 (loop solves a real bug in ≤5 iters; circuit breaker
# trips at 10 iters; progress.log is preserved).
#
# Usage:
#   ./e2e-harness.sh <fixture-project> <mock-agy> <max-iterations> <result-file>
#
# Arguments:
#   <fixture-project>  Path to a directory containing package.json, PRD.md,
#                      src/calc.js, test/*.test.js. Will be copied to a
#                      scratch dir, NOT modified in place.
#   <mock-agy>         Path to a script that takes $1 = iteration number
#                      and modifies code in the project root (cwd).
#                      Must exit 0.
#   <max-iterations>   Max loop iterations (e.g. 10 to exercise the
#                      circuit breaker, 5 to bound the happy path).
#   <result-file>      Path the harness writes key=value results to:
#                        status        = SUCCESS | CIRCUIT_BREAKER
#                        iterations    = N (iterations actually run)
#                        passed_iter   = N (first iter where TEST_CMD
#                                          passed; 0 if never)
#                        feature_branch= ralph/... (or empty)
#                        base_branch   = the BASE_BRANCH that was used
#                        commits       = N (commits on the feature
#                                          branch)
#                        progress_entries = N
#                        merged        = yes | no
#
# Exit code: 0 on SUCCESS, 1 on CIRCUIT_BREAKER (or any harness error).

set -uo pipefail

# Don't propagate -e blindly; we want to handle iteration failures.
# `set -u` is enough to catch typos in variable names.

FIXTURE_SRC="${1:-}"
MOCK_AGY="${2:-}"
MAX_ITERATIONS="${3:-10}"
RESULT_FILE="${4:-/tmp/ralph-e2e-result}"

if [[ -z "$FIXTURE_SRC" || -z "$MOCK_AGY" ]]; then
  printf 'usage: %s <fixture-project> <mock-agy> <max-iterations> <result-file>\n' "$0" >&2
  exit 2
fi
if [[ ! -d "$FIXTURE_SRC" ]]; then
  printf 'fixture not found: %s\n' "$FIXTURE_SRC" >&2
  exit 2
fi
if [[ ! -x "$MOCK_AGY" ]]; then
  printf 'mock-agy not executable: %s\n' "$MOCK_AGY" >&2
  exit 2
fi

# Locate the ralph_runner.sh relative to this script so the harness
# works regardless of cwd.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/ralph_runner.sh"
if [[ ! -f "$RUNNER" ]]; then
  printf 'ralph_runner.sh not found at %s\n' "$RUNNER" >&2
  exit 2
fi

# Scratch copy of the fixture so we never touch the source tree.
SCRATCH="$(mktemp -d -t ralph-e2e-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
cp -R "$FIXTURE_SRC/." "$SCRATCH/"
cd "$SCRATCH"

# Bootstrap a fresh git repo with a sandcastle-style branch. The
# runner's detect_git_context() will read the current branch and
# derive ISSUE_ID + ISSUE_SLUG from the name.
git init -q -b main
git config user.email  "ralph-e2e@test.local"
git config user.name   "ralph-e2e"
git config commit.gpgsign false
git add -A
git commit -q -m "fixture: initial commit with bug"
git checkout -q -b "sandcastle/issue-6-s5-e2e-stress-test-con-bug-real"

# Clear any inherited ralph vars so detect_git_context() runs from
# scratch.
unset BASE_BRANCH ISSUE_ID ISSUE_SLUG FEATURE_BRANCH BASELINE_COMMIT
export MAX_ITERATIONS COOLDOWN_SECONDS=0
export IMAGE_NAME="unused-e2e"
export AGY_CREDENTIALS_DIR="$HOME/.config/antigravity-cli"
export AGY_CREDENTIALS_IN_CONTAINER="/home/agent/.config/antigravity-cli"

# Source the runner. The main() guard prevents main() from running.
# shellcheck disable=SC1090
source "$RUNNER"

detect_git_context
record_baseline

TEST_CMD=$(resolve_test_cmd PRD.md)
printf '[harness] TEST_CMD=%s\n' "$TEST_CMD" >&2
printf '[harness] BASE_BRANCH=%s ISSUE_ID=%s slug=%s\n' \
  "$BASE_BRANCH" "${ISSUE_ID:-?}" "${ISSUE_SLUG:-?}" >&2

: >progress.log

success=0
passed_iter=0
for ((iter = 1; iter <= MAX_ITERATIONS; iter++)); do
  printf '[harness] === iteration %d/%d ===\n' "$iter" "$MAX_ITERATIONS" >&2

  # Run the mock agy (this is the "docker run ... agy" stand-in).
  RALPH_ITERATION="$iter" bash "$MOCK_AGY" "$iter" >/dev/null 2>&1

  if has_uncommitted_changes; then
    set +e
    bash -c "$TEST_CMD" >/dev/null 2>&1
    test_status=$?
    set -e

    if [[ $test_status -eq 0 ]]; then
      passed_iter=$iter
      printf '[harness] TEST_CMD passed on iter %d\n' "$iter" >&2
      if [[ -z "${FEATURE_BRANCH:-}" ]]; then
        create_feature_branch || {
          printf '[harness] failed to create feature branch\n' >&2
          break
        }
      fi
      commit_iteration "$iter" "agent solved task (TEST_CMD exit 0)" \
        || printf '[harness] commit_iteration returned non-zero (no-op)\n' >&2
      success=1
      break
    fi

    printf '[harness] TEST_CMD failed on iter %d (exit=%d)\n' \
      "$iter" "$test_status" >&2
    append_progress "$iter" "$TEST_CMD" "$test_status" ""
  else
    printf '[harness] mock produced no changes on iter %d\n' "$iter" >&2
    append_no_progress "$iter"
  fi
done

progress_entries=$(grep -c '^[[].*] Iteration' progress.log || true)

merged="no"
if [[ $success -eq 1 ]]; then
  if merge_feature_to_base; then
    merged="yes"
  else
    printf '[harness] merge_feature_to_base failed\n' >&2
  fi
fi

# Count RALPH: commits on the feature branch's history. After the merge
# the base and feature point to the same merge commit, so a plain
# BASE..FEATURE rev-list would always be 0. Counting RALPH: commits on
# the feature branch's full history is what the AC actually asks for:
# "Commit automático creado en branch ralph/...".
commits=0
if [[ -n "${FEATURE_BRANCH:-}" ]] && git show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}"; then
  commits=$(git log --grep='^RALPH:' --oneline "$FEATURE_BRANCH" 2>/dev/null | wc -l | tr -d ' ')
fi

cat >"$RESULT_FILE" <<EOF
status=${success}
iterations=$(( iter > MAX_ITERATIONS ? MAX_ITERATIONS : iter ))
passed_iter=$passed_iter
feature_branch=${FEATURE_BRANCH}
base_branch=${BASE_BRANCH}
commits=$commits
progress_entries=$progress_entries
merged=$merged
EOF

if [[ $success -eq 1 ]]; then
  exit 0
fi
exit 1
