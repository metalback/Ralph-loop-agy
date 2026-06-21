#!/usr/bin/env bash
# ralph_runner.sh — Ralph Loop orchestrator (issue #4 / PRD #1, S4 #5).
#
# Drives the Ralph Loop end-to-end:
#   1. Reads PRD.md, extracts TEST_CMD (with a stack-detection fallback).
#   2. Detects the git context: the base branch (BASE_BRANCH) and the
#      issue id/slug from the current branch name (sandcastle/issue-N-slug).
#   3. Ensures the ralph-loop-base Docker image exists (builds it from
#      .sandcastle/Dockerfile if not).
#   4. Iteratively runs `agy --non-interactive --load-skill ralph-worker`
#      inside a sandboxed container that mounts the project :rw and the
#      host agy credentials :ro.
#   5. After each iteration, runs TEST_CMD. Exit 0 → auto-commit on a
#      feature branch `ralph/issue-N-slug` (created on first success).
#      Non-zero → append stderr to progress.log (with timestamp), cooldown,
#      retry.
#   6. After the loop succeeds, merges the feature branch into BASE_BRANCH
#      (with --no-ff for a merge commit). On conflict the merge is aborted
#      and the runner exits 1.
#   7. Trips a circuit breaker at MAX_ITERATIONS (default 10), preserving
#      progress.log and exiting 1.
#
# Configuration: every default can be overridden via environment variables
# or by exporting values from a local .env file in the project root.
#
# The script can be sourced by tests to access the git helpers (main() is
# guarded so it only runs when the file is executed, not sourced).

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-15}"
IMAGE_NAME="${IMAGE_NAME:-ralph-loop-base}"
DOCKERFILE="${DOCKERFILE:-.sandcastle/Dockerfile}"
PRD_FILE="${PRD_FILE:-PRD.md}"
PROGRESS_LOG="${PROGRESS_LOG:-progress.log}"
WORKDIR_IN_CONTAINER="${WORKDIR_IN_CONTAINER:-/workspace}"
AGY_CREDENTIALS_DIR="${AGY_CREDENTIALS_DIR:-$HOME/.config/antigravity-cli}"
AGY_CREDENTIALS_IN_CONTAINER="${AGY_CREDENTIALS_IN_CONTAINER:-/home/agent/.config/antigravity-cli}"
SKILL_NAME="${SKILL_NAME:-ralph-worker}"

# Issue / branch context. Overridable via env; otherwise auto-detected
# from the current branch name in detect_git_context().
ISSUE_ID="${ISSUE_ID:-}"
ISSUE_SLUG="${ISSUE_SLUG:-}"
BASE_BRANCH="${BASE_BRANCH:-}"
FEATURE_BRANCH="${FEATURE_BRANCH:-}"
BASELINE_COMMIT="${BASELINE_COMMIT:-}"

# Source .env (do not override already-set environment).
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PROJECT_ROOT="$(pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  printf '\033[1;36m[ralph]\033[0m %s\n' "$*" >&2
}

err() {
  printf '\033[1;31m[ralph]\033[0m %s\n' "$*" >&2
}

die() {
  err "$*"
  exit 1
}

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

# ---------------------------------------------------------------------------
# TEST_CMD extraction
# ---------------------------------------------------------------------------

detect_test_cmd_from_stack() {
  if [[ -f package.json ]] && command -v jq >/dev/null 2>&1; then
    local script
    script=$(jq -r '.scripts.test // empty' package.json 2>/dev/null || true)
    if [[ -n "$script" && "$script" != "null" ]]; then
      printf 'npm test\n'
      return 0
    fi
  fi
  if [[ -f go.mod ]]; then
    printf 'go test ./...\n'
    return 0
  fi
  if [[ -f Cargo.toml ]]; then
    printf 'cargo test\n'
    return 0
  fi
  if [[ -f pyproject.toml || -f requirements.txt ]]; then
    if command -v pytest >/dev/null 2>&1; then
      printf 'pytest\n'
      return 0
    fi
  fi
  if [[ -f Makefile ]] && grep -Eq '^test[[:space:]]*:' Makefile; then
    printf 'make test\n'
    return 0
  fi
  return 1
}

# Extract the TEST_CMD declared in the PRD. Recognises:
#   TEST_CMD: <command>
#   TEST_CMD: `<command>`
# Quotes inside the command (e.g. TEST_CMD: echo "ok") are preserved
# verbatim — only Markdown-style backticks are stripped.
extract_test_cmd_from_prd() {
  local prd="$1"
  if [[ ! -f "$prd" ]]; then
    return 1
  fi
  local cmd
  cmd=$(grep -E '^TEST_CMD[[:space:]]*:' "$prd" \
        | head -n1 \
        | sed -E 's/^TEST_CMD[[:space:]]*:[[:space:]]*//' \
        | sed -E 's/^`+//; s/`+$//' \
        || true)
  if [[ -n "$cmd" ]]; then
    printf '%s\n' "$cmd"
    return 0
  fi
  return 1
}

resolve_test_cmd() {
  local prd="$1"
  if cmd=$(extract_test_cmd_from_prd "$prd") && [[ -n "$cmd" ]]; then
    printf '%s\n' "$cmd"
    return 0
  fi
  if cmd=$(detect_test_cmd_from_stack) && [[ -n "$cmd" ]]; then
    log "TEST_CMD not declared in $prd; using stack detection: $cmd"
    printf '%s\n' "$cmd"
    return 0
  fi
  die "could not determine TEST_CMD (declare it in $prd as 'TEST_CMD: <command>' or add a package.json/Makefile/etc. with a test script)"
}

# ---------------------------------------------------------------------------
# Docker image management
# ---------------------------------------------------------------------------

ensure_docker_image() {
  require_cmd docker
  if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    log "docker image $IMAGE_NAME already present"
    return 0
  fi
  log "docker image $IMAGE_NAME not found, building from $DOCKERFILE"
  docker build -t "$IMAGE_NAME" -f "$DOCKERFILE" "$PROJECT_ROOT"
}

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

# Returns the current branch name (or 'HEAD' if detached).
current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD"
}

# Parse the issue id and slug from a sandcastle-style branch name:
#   sandcastle/issue-42-some-task-slug  ->  ISSUE_ID=42, ISSUE_SLUG=some-task-slug
# Returns 0 on a successful parse, 1 otherwise. Mutates ISSUE_ID and
# ISSUE_SLUG in the caller's environment.
parse_issue_from_branch() {
  local branch="$1"
  if [[ "$branch" =~ ^sandcastle/issue-([0-9]+)-(.+)$ ]]; then
    ISSUE_ID="${BASH_REMATCH[1]}"
    ISSUE_SLUG="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Build the feature branch name from ISSUE_ID and ISSUE_SLUG. The result
# is echoed; callers should capture it (e.g. into FEATURE_BRANCH).
build_feature_branch() {
  if [[ -n "${ISSUE_ID:-}" && -n "${ISSUE_SLUG:-}" ]]; then
    printf 'ralph/issue-%s-%s\n' "$ISSUE_ID" "$ISSUE_SLUG"
  elif [[ -n "${ISSUE_ID:-}" ]]; then
    printf 'ralph/issue-%s\n' "$ISSUE_ID"
  else
    printf 'ralph/auto\n'
  fi
}

# Detect BASE_BRANCH, ISSUE_ID, ISSUE_SLUG and FEATURE_BRANCH from the
# current branch. Called once at the start of the loop.
detect_git_context() {
  require_cmd git
  local branch
  branch=$(current_branch)
  if [[ -z "${BASE_BRANCH:-}" ]]; then
    BASE_BRANCH="$branch"
  fi
  if [[ -z "${ISSUE_ID:-}" || -z "${ISSUE_SLUG:-}" ]]; then
    parse_issue_from_branch "$branch" || true
  fi
  FEATURE_BRANCH=""
  log "git context: BASE_BRANCH=${BASE_BRANCH} ISSUE_ID=${ISSUE_ID:-?} slug=${ISSUE_SLUG:-?}"
}

# Record the current HEAD as the baseline. Any tracked/untracked changes
# observed at commit time are by definition agy-produced.
record_baseline() {
  if ! BASELINE_COMMIT=$(git rev-parse HEAD 2>/dev/null); then
    die "no git commit found; please commit current state before running the loop"
  fi
  log "baseline commit recorded: $BASELINE_COMMIT"
}

has_uncommitted_changes() {
  ! git diff --quiet HEAD 2>/dev/null \
    || ! git diff --cached --quiet 2>/dev/null \
    || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null || true)" ]]
}

# Stage only files that have changed since BASELINE_COMMIT, excluding
# progress.log. This implements the S4 acceptance bullet "only commit
# files modified by agy": the baseline is the working tree state at the
# start of the loop, so anything that differs is by definition agent work.
stage_changes() {
  if [[ -z "${BASELINE_COMMIT:-}" ]]; then
    record_baseline
  fi
  # Modified/added/renamed/copied tracked files since the baseline.
  local tracked
  tracked=$(git diff --name-only --diff-filter=ACMRT "$BASELINE_COMMIT" 2>/dev/null || true)
  # New (untracked) files that respect .gitignore.
  local untracked
  untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)
  local added=0
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == "progress.log" ]] && continue
    if [[ -e "$f" ]]; then
      git add -- "$f" 2>/dev/null && added=$((added + 1))
    fi
  done <<<"${tracked}
${untracked}"
  log "staged ${added} file(s) for commit (baseline=${BASELINE_COMMIT:0:7}, excluded: progress.log)"
}

commit_iteration() {
  local iter="$1"
  local summary="$2"
  stage_changes
  if ! has_uncommitted_changes; then
    log "no staged changes after stage_changes(); nothing to commit"
    return 1
  fi
  local msg="RALPH: iteration ${iter} — ${summary}"
  log "committing on ${FEATURE_BRANCH:-$(current_branch)}: $msg"
  git commit -m "$msg"
}

# Create the feature branch ralph/issue-N-slug from the current commit
# and switch to it. No-op if FEATURE_BRANCH already exists and is checked
# out (idempotent across multiple invocations of the same loop).
create_feature_branch() {
  if [[ -z "${FEATURE_BRANCH:-}" ]]; then
    FEATURE_BRANCH=$(build_feature_branch)
  fi
  if [[ "$(current_branch)" == "$FEATURE_BRANCH" ]]; then
    log "already on feature branch $FEATURE_BRANCH"
    return 0
  fi
  if git show-ref --verify --quiet "refs/heads/${FEATURE_BRANCH}"; then
    log "feature branch $FEATURE_BRANCH already exists, switching to it"
    git checkout "$FEATURE_BRANCH"
    return 0
  fi
  log "creating feature branch $FEATURE_BRANCH from $(current_branch)"
  git checkout -b "$FEATURE_BRANCH"
}

# Merge the feature branch into BASE_BRANCH. Returns 0 on success, 1 on
# conflict. On conflict the merge is aborted (via 'git merge --abort') so
# BASE_BRANCH stays clean and the runner exits 1.
merge_feature_to_base() {
  if [[ -z "${FEATURE_BRANCH:-}" || -z "${BASE_BRANCH:-}" ]]; then
    err "merge_feature_to_base: FEATURE_BRANCH and BASE_BRANCH must be set"
    return 1
  fi
  log "merging ${FEATURE_BRANCH} into ${BASE_BRANCH}"

  # Stash any uncommitted work in the working tree so the checkout is clean.
  local stashed=0
  if has_uncommitted_changes; then
    log "stashing uncommitted changes before merge"
    git stash push -u -m "ralph pre-merge $(now_utc)" || {
      err "failed to stash uncommitted changes before merge"
      return 1
    }
    stashed=1
  fi

  # Switch to the base branch.
  if ! git checkout "$BASE_BRANCH" 2>/dev/null; then
    err "failed to checkout base branch $BASE_BRANCH"
    [[ $stashed -eq 1 ]] && git stash pop >/dev/null 2>&1 || true
    return 1
  fi

  # Attempt the merge. --no-ff keeps a merge commit so the history shows
  # the integration step (even when fast-forward would be possible).
  local merge_log
  merge_log=$(mktemp)
  if git merge --no-ff "$FEATURE_BRANCH" \
        -m "RALPH: merge ${FEATURE_BRANCH} into ${BASE_BRANCH}" \
        >"$merge_log" 2>&1; then
    log "merge ${FEATURE_BRANCH} -> ${BASE_BRANCH} successful"
    rm -f "$merge_log"
    return 0
  fi

  # Conflict path.
  err "merge conflict: ${FEATURE_BRANCH} -> ${BASE_BRANCH}"
  err "merge output (truncated):"
  tail -n 20 "$merge_log" | sed 's/^/  /' >&2 || true
  err "aborting merge to keep ${BASE_BRANCH} clean"
  git merge --abort >/dev/null 2>&1 || true
  rm -f "$merge_log"

  # Try to restore the user's stashed work, but never fail the loop
  # because of it — they can re-apply manually.
  if [[ $stashed -eq 1 ]]; then
    err "restoring stashed changes onto ${BASE_BRANCH}"
    if ! git stash pop >/dev/null 2>&1; then
      err "warning: failed to restore stash; manual intervention needed"
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# agy invocation
# ---------------------------------------------------------------------------

run_agy_iteration() {
  local iter="$1"
  local agy_log
  agy_log=$(mktemp)
  local status
  set +e
  docker run --rm \
    -v "${PROJECT_ROOT}:${WORKDIR_IN_CONTAINER}:cached,rw" \
    -v "${AGY_CREDENTIALS_DIR}:${AGY_CREDENTIALS_IN_CONTAINER}:ro" \
    -e "MODEL=${MODEL:-}" \
    -e "MAX_ITERATIONS=${MAX_ITERATIONS}" \
    -e "COOLDOWN_SECONDS=${COOLDOWN_SECONDS}" \
    -e "RALPH_ITERATION=${iter}" \
    "$IMAGE_NAME" \
    agy --non-interactive --load-skill "$SKILL_NAME" \
      >"$agy_log" 2>&1
  status=$?
  set -e
  log "agy exited with status ${status} (output: ${agy_log})"
  printf '%s\n' "$agy_log"
  return "$status"
}

# Run the validation command and return its exit code. Stdout and stderr
# are captured into a single temp file; the path is echoed so the caller
# can grep the file for the error summary.
run_test_cmd() {
  local test_cmd="$1"
  local test_log
  test_log=$(mktemp)
  local status
  set +e
  bash -c "$test_cmd" >"$test_log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$test_log"
  return "$status"
}

# ---------------------------------------------------------------------------
# progress.log writer
# ---------------------------------------------------------------------------

append_progress() {
  local iter="$1"
  local test_cmd="$2"
  local status="$3"
  local source_log="${4:-}"
  local ts
  ts=$(now_utc)
  {
    printf '[%s] Iteration %d | TEST_CMD: %s | exit %d\n' \
      "$ts" "$iter" "$test_cmd" "$status"
    if [[ -n "$source_log" && -f "$source_log" ]]; then
      printf '--- last 30 lines of output ---\n'
      tail -n 30 "$source_log" || true
      printf '--- end ---\n'
    fi
    printf '\n'
  } >>"$PROGRESS_LOG"
}

append_no_progress() {
  local iter="$1"
  local ts
  ts=$(now_utc)
  {
    printf '[%s] Iteration %d | agy produced no code changes\n' "$ts" "$iter"
    printf '\n'
  } >>"$PROGRESS_LOG"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

main() {
  cd "$PROJECT_ROOT"

  log "Ralph Loop starting (MAX_ITERATIONS=${MAX_ITERATIONS}, COOLDOWN=${COOLDOWN_SECONDS}s)"
  log "PRD file: $PRD_FILE"
  log "Progress log: $PROGRESS_LOG"

  [[ -f "$PRD_FILE" ]] || die "PRD file not found: $PRD_FILE"

  detect_git_context
  record_baseline

  local test_cmd
  test_cmd=$(resolve_test_cmd "$PRD_FILE")
  log "TEST_CMD resolved to: $test_cmd"

  ensure_docker_image

  # Make sure progress.log exists (the agent reads it in §1 of the skill).
  : >"$PROGRESS_LOG"

  local iter
  local success=0
  for ((iter = 1; iter <= MAX_ITERATIONS; iter++)); do
    log "=== Iteration ${iter}/${MAX_ITERATIONS} ==="

    local agy_log agy_status
    set +e
    agy_log=$(run_agy_iteration "$iter")
    agy_status=$?
    set -e

    if has_uncommitted_changes; then
      log "code changes detected, running TEST_CMD: $test_cmd"
      local test_log test_status
      set +e
      test_log=$(run_test_cmd "$test_cmd")
      test_status=$?
      set -e

      if [[ $test_status -eq 0 ]]; then
        log "TEST_CMD passed (exit 0)"
        # First success: create the feature branch so all subsequent
        # iteration commits land on ralph/issue-N-slug.
        if [[ -z "${FEATURE_BRANCH:-}" ]]; then
          create_feature_branch || die "failed to create feature branch"
        fi
        if commit_iteration "$iter" "agent solved task (TEST_CMD exit 0)"; then
          success=1
        fi
        rm -f "$agy_log" "$test_log"
        break
      fi

      log "TEST_CMD failed (exit ${test_status}); appending to progress.log"
      append_progress "$iter" "$test_cmd" "$test_status" "$test_log"
      rm -f "$test_log"
    else
      log "agy produced no code changes; appending to progress.log"
      append_no_progress "$iter"
    fi

    rm -f "$agy_log"

    if [[ $iter -lt MAX_ITERATIONS ]]; then
      log "cooldown ${COOLDOWN_SECONDS}s before next iteration"
      sleep "$COOLDOWN_SECONDS"
    fi
  done

  if [[ $success -eq 1 ]]; then
    log "Ralph Loop completed successfully in ${iter} iteration(s)"
    # Integrate the feature branch into BASE_BRANCH. A merge conflict
    # aborts the merge and exits 1, so a failed merge never leaves the
    # base branch in a half-merged state.
    if ! merge_feature_to_base; then
      err "merge into ${BASE_BRANCH} failed; feature branch ${FEATURE_BRANCH} preserved"
      exit 1
    fi
    log "feature branch ${FEATURE_BRANCH} merged into ${BASE_BRANCH}"
    exit 0
  fi

  err "circuit breaker tripped after ${MAX_ITERATIONS} iterations"
  err "progress.log preserved at: ${PROJECT_ROOT}/${PROGRESS_LOG}"
  exit 1
}

# Only run main() when the file is executed, not when sourced for tests.
# This lets the test suite import the git helpers (parse_issue_from_branch,
# build_feature_branch, create_feature_branch, commit_iteration,
# merge_feature_to_base, ...) without triggering the full loop.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
