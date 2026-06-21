#!/usr/bin/env bash
# ralph_runner.sh — Ralph Loop orchestrator (issue #4 / PRD #1).
#
# Drives the Ralph Loop end-to-end:
#   1. Reads PRD.md, extracts TEST_CMD (with a stack-detection fallback).
#   2. Ensures the ralph-loop-base Docker image exists (builds it from
#      .sandcastle/Dockerfile if not).
#   3. Iteratively runs `agy --non-interactive --load-skill ralph-worker`
#      inside a sandboxed container that mounts the project :rw and the
#      host agy credentials :ro.
#   4. After each iteration, runs TEST_CMD. Exit 0 → auto-commit. Non-zero
#      → append stderr to progress.log (with timestamp), cooldown, retry.
#   5. Trips a circuit breaker at MAX_ITERATIONS (default 10), preserving
#      progress.log and exiting 1.
#
# Configuration: every default can be overridden via environment variables
# or by exporting values from a local .env file in the project root.

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

has_uncommitted_changes() {
  ! git diff --quiet HEAD 2>/dev/null \
    || ! git diff --cached --quiet 2>/dev/null \
    || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null || true)" ]]
}

# Stage everything except the progress.log so it never lands in a commit.
stage_changes() {
  git add -A -- ':!progress.log' || true
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
  log "committing: $msg"
  git commit -m "$msg"
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
    exit 0
  fi

  err "circuit breaker tripped after ${MAX_ITERATIONS} iterations"
  err "progress.log preserved at: ${PROJECT_ROOT}/${PROGRESS_LOG}"
  exit 1
}

main "$@"
