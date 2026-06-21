#!/usr/bin/env bash
# Smoke test for the Ralph Loop base Docker image.
#
# Validates the acceptance criteria from issue #2 ("S1: Docker sandbox + agy
# smoke test"). The static checks parse the Dockerfile itself. The dynamic
# checks (docker build / docker run) run only when docker is available; if not
# available, the static checks are still required to pass.
#
# Usage:
#   ./.sandcastle/smoke-test.sh
#
# Exits 0 on success, 1 on any failed check.

set -euo pipefail

DOCKERFILE="${DOCKERFILE:-.sandcastle/Dockerfile}"
IMAGE_NAME="${IMAGE_NAME:-ralph-loop-base}"
AGY_VERSION="${AGY_VERSION:-1.0.8}"
MAX_IMAGE_MB="${MAX_IMAGE_MB:-400}"

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
  if grep -Eq "$pattern" <<<"$dockerfile_content"; then
    ok "$ok_msg"
  else
    nok "$nok_msg" "$detail"
  fi
}

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "Dockerfile not found at: $DOCKERFILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Static checks: parse the Dockerfile content
# ---------------------------------------------------------------------------

section "Static checks ($DOCKERFILE)"

dockerfile_content=$(cat "$DOCKERFILE")

check_grep '^FROM[[:space:]]+node:22-alpine(\s|$)' \
  "Base image is node:22-alpine" \
  "Base image must be node:22-alpine" \
  "current FROM line: $(grep -E '^FROM' <<<"$dockerfile_content" | head -1)"

check_grep "npm[[:space:]]+install[[:space:]]+-g[[:space:]]+agy@${AGY_VERSION}" \
  "agy v${AGY_VERSION} installed globally via npm" \
  "agy v${AGY_VERSION} must be installed globally (npm install -g agy@${AGY_VERSION})"

check_grep '\bgh\b' "gh CLI installed" "gh CLI must be installed"
check_grep '\bgit\b' "git installed" "git must be installed"
check_grep '\bjq\b' "jq installed" "jq must be installed"

check_grep '^ARG[[:space:]]+AGENT_UID=' "ARG AGENT_UID declared" "ARG AGENT_UID must be declared"
check_grep '^ARG[[:space:]]+AGENT_GID=' "ARG AGENT_GID declared" "ARG AGENT_GID must be declared"

# USER agent (or dynamic ${AGENT_UID}:${AGENT_GID}) ensures UID/GID from build args
if grep -Eq '^USER[[:space:]]+agent' <<<"$dockerfile_content" \
   || grep -Eq '^USER[[:space:]]+(\$\{|")[a-zA-Z_]+(:\$\{[a-zA-Z_]+\})?' <<<"$dockerfile_content"; then
  ok "USER is agent (dynamic UID/GID via build args)"
else
  nok "USER must be set to agent user with dynamic UID/GID from build args"
fi

# ---------------------------------------------------------------------------
# Dynamic checks: only when docker is available
# ---------------------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
  section "Dynamic checks (docker)"

  build_log=$(mktemp)
  if docker build -q -t "$IMAGE_NAME" -f "$DOCKERFILE" . >"$build_log" 2>&1; then
    ok "docker build -t $IMAGE_NAME .sandcastle/Dockerfile succeeded"
  else
    nok "docker build failed" "$(tail -n 20 "$build_log")"
    rm -f "$build_log"
    section "Summary"
    echo "  passed: $pass"
    echo "  failed: $fail"
    exit 1
  fi
  rm -f "$build_log"

  version_output=$(docker run --rm "$IMAGE_NAME" agy --version 2>&1 || true)
  if grep -Eq "v?${AGY_VERSION}" <<<"$version_output"; then
    ok "agy --version reports v${AGY_VERSION} (got: $version_output)"
  else
    nok "agy --version must report v${AGY_VERSION}" "got: $version_output"
  fi

  creds_mount_ok=$(docker run --rm \
    -v "${HOME}/.config/antigravity-cli:/home/agent/.config/antigravity-cli:ro" \
    --user "$(id -u):$(id -g)" \
    "$IMAGE_NAME" \
    sh -c "test -d /home/agent/.config/antigravity-cli && echo OK || echo MISSING" 2>&1 || true)
  if grep -q OK <<<"$creds_mount_ok"; then
    ok "Host credentials mount path is accessible inside the container"
  else
    nok "Host credentials mount must be readable inside the container" "got: $creds_mount_ok"
  fi

  size_bytes=$(docker image inspect "$IMAGE_NAME" --format='{{.Size}}' 2>/dev/null || echo 0)
  size_mb=$((size_bytes / 1024 / 1024))
  if [[ "$size_mb" -le "$MAX_IMAGE_MB" ]]; then
    ok "Image size ${size_mb}MB <= ${MAX_IMAGE_MB}MB"
  else
    nok "Image size must be <= ${MAX_IMAGE_MB}MB" "got: ${size_mb}MB"
  fi

  docker rmi -f "$IMAGE_NAME" >/dev/null 2>&1 || true
else
  section "Dynamic checks skipped (docker not available)"
  echo "  Install Docker to run the full build/run smoke test."
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
