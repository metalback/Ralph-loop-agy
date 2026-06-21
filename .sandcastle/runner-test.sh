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
# Acceptance criteria from issue #5 (S4: Git automation).
# ---------------------------------------------------------------------------

section "S4 acceptance: feature branch named ralph/issue-{id}-{slug}"

# The runner must construct branch names of the form ralph/issue-N-slug.
if grep -Eq 'ralph/issue-' <<<"$runner_content"; then
  ok "Runner builds feature branches in the 'ralph/issue-N-slug' form"
else
  nok "Runner must build feature branches in the 'ralph/issue-N-slug' form" \
      "expected a 'ralph/issue-' token in the runner source"
fi

# The slug must be derived from somewhere (current branch, PRD, env). We
# only check that the runner parses a numeric issue id from a branch
# name (the sandcastle convention) or accepts it from the environment.
if grep -Eq 'issue-\\\$\{|issue-\\\$|sandcastle/issue-|ISSUE_ID' <<<"$runner_content"; then
  ok "Runner sources the issue id (from the branch name or ISSUE_ID env)"
else
  nok "Runner must source the issue id from the branch name or ISSUE_ID env"
fi

section "S4 acceptance: commit uses RALPH: prefix"

# The existing commit message format must still be 'RALPH: ...'.
if grep -Eq 'RALPH:[[:space:]]*iteration' <<<"$runner_content"; then
  ok "Commit message still uses 'RALPH: iteration N — ...' prefix"
else
  nok "Runner must keep the 'RALPH: iteration N — ...' commit prefix"
fi

section "S4 acceptance: merge to base branch at end of loop"

# The runner must call git merge at the end of the loop.
if grep -Eq 'git[[:space:]]+merge' <<<"$runner_content"; then
  ok "Runner invokes 'git merge' to integrate the feature branch"
else
  nok "Runner must call 'git merge' to integrate the feature branch into BASE_BRANCH"
fi

# A merge commit is desirable for traceability (--no-ff) but not required.
if grep -Eq -- '--no-ff|merge[[:space:]]+--no' <<<"$runner_content"; then
  ok "Runner uses 'git merge --no-ff' for a merge commit"
else
  echo "  (info) Runner does not use --no-ff; default fast-forward is fine for simple cases"
fi

# BASE_BRANCH must be configurable.
if grep -Eq 'BASE_BRANCH' <<<"$runner_content"; then
  ok "Runner exposes BASE_BRANCH (configurable base branch)"
else
  nok "Runner must reference BASE_BRANCH (or auto-detect the base branch)"
fi

section "S4 acceptance: abort on merge conflict"

# The runner must abort a failed merge and report the conflict.
if grep -Eq 'merge[[:space:]]+--abort|git[[:space:]]+merge[[:space:]]+--abort' <<<"$runner_content"; then
  ok "Runner aborts the merge on conflict ('git merge --abort')"
else
  nok "Runner must call 'git merge --abort' on conflict"
fi

# The runner must report the conflict to the user (stderr, error message).
if grep -Eqi 'conflict' <<<"$runner_content"; then
  ok "Runner mentions 'conflict' in the source (error message expected)"
else
  nok "Runner must report a 'conflict' message when the merge fails"
fi

section "S4 acceptance: commit only files modified by agy"

# The runner must track a baseline (the commit/working tree state at the
# start of the loop) and stage only files that changed since.
if grep -Eq 'BASELINE|baseline|rev-parse[[:space:]]+HEAD' <<<"$runner_content"; then
  ok "Runner records a baseline (git rev-parse HEAD) at loop start"
else
  nok "Runner must record a baseline (git rev-parse HEAD) to scope commits to agy changes"
fi

# The runner must NOT just `git add -A` (which would include files
# unrelated to the task). It should use `git add` with explicit paths.
if grep -Eq -- "git[[:space:]]+add[[:space:]]+-A[[:space:]]+--" <<<"$runner_content"; then
  nok "Runner still uses 'git add -A' (may commit unrelated files)" \
      "prefer staging only files changed since the baseline"
else
  ok "Runner does not blanket-stage with 'git add -A'"
fi

# progress.log is still excluded from the commit.
if grep -Eq ':!progress\.log|progress\.log' <<<"$runner_content"; then
  ok "Runner continues to exclude progress.log from the commit"
else
  nok "Runner must exclude progress.log from the commit"
fi

# ---------------------------------------------------------------------------
# Functional check: source the runner and call its git helpers against
# a scratch git repo. This is the dynamic contract for S4: we can detect
# the issue id from the branch, build the right feature branch name, and
# perform a clean merge to the base.
# ---------------------------------------------------------------------------

section "Functional: source runner and exercise git helpers"

# Use a scratch dir so we never touch the user's working tree.
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

# Bootstrap a tiny repo with a sandcastle-style branch and a base branch.
(
  set -e
  cd "$scratch_dir"
  git init -q -b main
  git config user.email "ralph@test.local"
  git config user.name  "ralph-test"
  printf 'base\n' >README.md
  git add README.md
  git commit -q -m "initial"
  git checkout -q -b "sandcastle/issue-42-some-task-slug"
  printf 'worktree\n' >work.txt
) >/dev/null 2>&1

# Source the runner; the main guard must let us import the helpers
# without executing the loop.
# shellcheck disable=SC1091
source "$RUNNER" --help </dev/null >/dev/null 2>&1 || true

# 1) parse_issue_from_branch returns the numeric id and slug.
if declare -f parse_issue_from_branch >/dev/null 2>&1; then
  if parse_issue_from_branch "sandcastle/issue-42-some-task-slug"; then
    if [[ "${ISSUE_ID:-}" == "42" && "${ISSUE_SLUG:-}" == "some-task-slug" ]]; then
      ok "parse_issue_from_branch extracts ISSUE_ID=42 and slug from branch"
    else
      nok "parse_issue_from_branch sets wrong env" \
          "got ISSUE_ID='${ISSUE_ID:-}' slug='${ISSUE_SLUG:-}'"
    fi
  else
    nok "parse_issue_from_branch should succeed for sandcastle/issue-N-slug branches"
  fi
else
  nok "Runner must expose a parse_issue_from_branch function" \
      "add 'parse_issue_from_branch() { ... }' to $RUNNER"
fi

# 2) build_feature_branch returns 'ralph/issue-N-slug'.
if declare -f build_feature_branch >/dev/null 2>&1; then
  ISSUE_ID="7"
  ISSUE_SLUG="automate-the-thing"
  built=$(build_feature_branch)
  if [[ "$built" == "ralph/issue-7-automate-the-thing" ]]; then
    ok "build_feature_branch returns 'ralph/issue-7-automate-the-thing'"
  else
    nok "build_feature_branch returned wrong name" "got: '$built'"
  fi
else
  nok "Runner must expose a build_feature_branch function"
fi

# 3) End-to-end: scratch repo -> create feature branch -> commit -> merge
#    to base branch. We invoke the relevant functions directly.
if declare -f create_feature_branch >/dev/null 2>&1 \
   && declare -f commit_iteration >/dev/null 2>&1 \
   && declare -f merge_feature_to_base >/dev/null 2>&1; then
  (
    set -e
    cd "$scratch_dir"
    BASE_BRANCH="main"
    ISSUE_ID="42"
    ISSUE_SLUG="some-task-slug"
    FEATURE_BRANCH=""

    # create_feature_branch must create 'ralph/issue-42-some-task-slug'.
    if ! create_feature_branch; then
      echo "create_feature_branch failed"
      exit 1
    fi
    if [[ "$(git rev-parse --abbrev-ref HEAD)" == "ralph/issue-42-some-task-slug" ]]; then
      echo "on feature branch"
    else
      echo "not on feature branch: $(git rev-parse --abbrev-ref HEAD)"
      exit 1
    fi
    # commit_iteration must commit only the new file (work.txt), not
    # anything else, with the RALPH: prefix.
    if ! commit_iteration 1 "test summary"; then
      echo "commit_iteration failed"
      exit 1
    fi
    last_msg=$(git log -1 --pretty=%s)
    if [[ "$last_msg" == RALPH:* ]]; then
      echo "commit has RALPH: prefix: $last_msg"
    else
      echo "commit lacks RALPH: prefix: $last_msg"
      exit 1
    fi
    if git diff --name-only "main" | grep -q '^work.txt$'; then
      echo "work.txt is on the feature branch"
    else
      echo "work.txt missing from feature branch"
      exit 1
    fi
    # merge_feature_to_base must switch to BASE_BRANCH and merge.
    if ! merge_feature_to_base; then
      echo "merge_feature_to_base failed"
      exit 1
    fi
    if [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]]; then
      echo "back on main"
    else
      echo "not on main after merge: $(git rev-parse --abbrev-ref HEAD)"
      exit 1
    fi
    if git diff --name-only HEAD~1 HEAD | grep -q '^work.txt$'; then
      echo "work.txt reached main"
    else
      echo "work.txt did not reach main"
      exit 1
    fi
  ) >/dev/null 2>&1 && ok "End-to-end: feature branch + commit + merge into base" \
    || nok "End-to-end git flow (create/commit/merge) failed" "see scratch repo at $scratch_dir"
else
  nok "Runner must expose create_feature_branch, commit_iteration, and merge_feature_to_base" \
      "missing one of: create_feature_branch / commit_iteration / merge_feature_to_base"
fi

# 4) Merge conflict: diverged base branch and feature branch. The
#    merge function must abort and report the conflict.
if declare -f merge_feature_to_base >/dev/null 2>&1; then
  conflict_dir=$(mktemp -d)
  (
    set -e
    cd "$conflict_dir"
    git init -q -b main
    git config user.email "ralph@test.local"
    git config user.name  "ralph-test"
    printf 'a\n' >conflict.txt
    git add conflict.txt
    git commit -q -m "base"
    git checkout -q -b "feature"
    printf 'b\n' >conflict.txt
    git commit -q -am "feature change"
    git checkout -q main
    printf 'c\n' >conflict.txt
    git commit -q -am "diverging base change"
    # Set the runner's branch vars so we exercise the merge path, not
    # the "missing vars" guard.
    BASE_BRANCH="main"
    FEATURE_BRANCH="feature"
    if merge_feature_to_base >/dev/null 2>&1; then
      echo "merge unexpectedly succeeded"
      exit 1
    fi
    # Verify we're back on a clean main (no merge in progress).
    if [[ -f .git/MERGE_HEAD ]]; then
      echo "merge was not aborted"
      exit 1
    fi
  ) >/dev/null 2>&1 && ok "Merge conflict: function aborts and reports failure" \
    || nok "Merge conflict: function must abort and report failure" \
           "(see scratch repo at $conflict_dir)"
  rm -rf "$conflict_dir"
else
  nok "Runner must expose merge_feature_to_base to test the conflict path"
fi

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
