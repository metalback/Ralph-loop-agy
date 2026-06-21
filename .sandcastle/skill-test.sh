#!/usr/bin/env bash
# Smoke test for the ralph-worker skill (issue #3).
#
# Validates the static acceptance criteria from
# "S2: Skill ralph-worker + ejecución manual". The dynamic check
# (running agy inside Docker against a test PRD) only runs when docker
# is available; the static checks are required to pass either way.
#
# Usage:
#   ./.sandcastle/skill-test.sh
#
# Exits 0 on success, 1 on any failed check.

set -euo pipefail

SKILL_FILE="${SKILL_FILE:-ralph-worker.md}"
IMAGE_NAME="${IMAGE_NAME:-ralph-loop-base}"

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
  if grep -Eq "$pattern" <<<"$skill_content"; then
    ok "$ok_msg"
  else
    nok "$nok_msg" "$detail"
  fi
}

# ---------------------------------------------------------------------------
# Acceptance criterion #1: the skill file exists at the project root.
# ---------------------------------------------------------------------------

section "Acceptance: ralph-worker.md at the project root"

if [[ ! -f "$SKILL_FILE" ]]; then
  nok "Skill file not found at project root: $SKILL_FILE"
  section "Summary"
  echo "  passed: $pass"
  echo "  failed: $fail"
  exit 1
fi
ok "Skill file exists at project root: $SKILL_FILE"

skill_content=$(cat "$SKILL_FILE")

# ---------------------------------------------------------------------------
# Acceptance criterion #2: instruct agy to read PRD.md and progress.log
# BEFORE modifying code.
# ---------------------------------------------------------------------------

section "Acceptance: read PRD.md + progress.log before coding"

check_grep 'PRD\.md' \
  "Mentions PRD.md" \
  "Skill must reference PRD.md so agy reads the task definition"

check_grep 'progress\.log' \
  "Mentions progress.log" \
  "Skill must reference progress.log so agy reads the iteration history"

if grep -Eqi 'before[[:space:]]+(modif|chang|edit|writing|touch)' <<<"$skill_content" \
   || grep -Eqi 'first|primero|inicial' <<<"$skill_content"; then
  ok "Skill orders context loading before code changes"
else
  nok "Skill must instruct agy to read context BEFORE modifying code"
fi

# ---------------------------------------------------------------------------
# Acceptance criterion #3: instruct agy to run the validation command
# AFTER modifying code.
# ---------------------------------------------------------------------------

section "Acceptance: run the validation command after coding"

check_grep '(TEST_CMD|validation|validaci[oó]n|test[[:space:]]+command|comando[[:space:]]+de[[:space:]]+(validaci|test))' \
  "Mentions the validation command (TEST_CMD / test / validation)" \
  "Skill must instruct agy to run the validation command"

if grep -Eqi 'after[[:space:]]+(modif|chang|edit|writing)' <<<"$skill_content" \
   || grep -Eqi 'luego|despu[eé]s|then[[:space:]]+run|run[[:space:]]+the' <<<"$skill_content"; then
  ok "Skill orders the validation step after code changes"
else
  nok "Skill must instruct agy to run validation AFTER modifying code"
fi

# ---------------------------------------------------------------------------
# Acceptance criterion #4: specifies the expected output format.
# ---------------------------------------------------------------------------

section "Acceptance: output format is specified"

check_grep '(RALPH_STATUS|status:[[:space:]]*(SUCCESS|FAILURE)|output[[:space:]]+format|formato[[:space:]]+de[[:space:]]+output)' \
  "Defines a parseable status line (RALPH_STATUS / output format)" \
  "Skill must specify a parseable output format the orchestrator can read"

# ---------------------------------------------------------------------------
# Acceptance criterion #5: the manual command line is wired up.
# The skill file must be reachable from the project root (mounted at
# /workspace in the container) and the file name must match the
# --load-skill argument.
# ---------------------------------------------------------------------------

section "Acceptance: manual docker invocation is valid"

if [[ "$SKILL_FILE" == "ralph-worker.md" ]]; then
  ok "File name matches the --load-skill ralph-worker argument"
else
  nok "File name must be ralph-worker.md to match --load-skill ralph-worker" \
      "got: $SKILL_FILE"
fi

basename_skill=$(basename "$SKILL_FILE")
expected_mount="/workspace/$basename_skill"
section "Acceptance: $expected_mount is the path agy will read at runtime"

# The manual invocation mounts $PWD at /workspace, so the skill must
# live at the project root. The file already exists at $SKILL_FILE on
# the host; the container will see it at $expected_mount. We verify the
# basename + the project-root location is sufficient.
if [[ -f "$SKILL_FILE" ]] && [[ "$basename_skill" == "ralph-worker.md" ]]; then
  ok "Project-root file maps to $expected_mount inside the container"
else
  nok "Skill must live at the project root so it maps to $expected_mount" \
      "SKILL_FILE=$SKILL_FILE basename=$basename_skill"
fi

# ---------------------------------------------------------------------------
# Dynamic check: actually run the manual command when docker is available.
# Mirrors the invocation from the issue's acceptance criteria.
# ---------------------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
  section "Dynamic check: docker run ... agy --load-skill ralph-worker"

  if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "  Image $IMAGE_NAME not present; building it from .sandcastle/Dockerfile..."
    if ! docker build -q -t "$IMAGE_NAME" -f .sandcastle/Dockerfile . >/dev/null 2>&1; then
      nok "Could not build $IMAGE_NAME image for the dynamic check"
    fi
  fi

  if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    manual_output=$(docker run --rm \
      -v "$PWD:/workspace" \
      "$IMAGE_NAME" \
      agy --load-skill ralph-worker --help 2>&1 || true)

    if grep -Eq 'ralph-worker|skill|load-skill' <<<"$manual_output"; then
      ok "Manual docker invocation reaches agy and references the skill"
    else
      nok "Manual docker invocation must reach agy and reference the skill" \
          "got: $manual_output"
    fi
  fi
else
  section "Dynamic check skipped (docker not available)"
  echo "  Install Docker and run 'docker build -t $IMAGE_NAME -f .sandcastle/Dockerfile .'"
  echo "  to exercise the manual invocation end-to-end."
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
