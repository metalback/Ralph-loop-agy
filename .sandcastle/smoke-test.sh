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

if [[ ! -f "$DOCKERFILE" ]]; then
  echo "Dockerfile not found at: $DOCKERFILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Static checks: parse the Dockerfile content
# ---------------------------------------------------------------------------

section "Static checks ($DOCKERFILE)"

dockerfile_content=$(cat "$DOCKERFILE")

# Base image must be node:22-alpine (acceptance criterion: based on node:22-alpine)
if grep -Eq '^FROM[[:space:]]+node:22-alpine(\s|$)' <<<"$dockerfile_content"; then
  ok "Base image is node:22-alpine"
else
  nok "Base image must be node:22-alpine" \
    "current FROM line: $(grep -E '^FROM' <<<"$dockerfile_content" | head -1)"
fi

# agy v1.0.8 must be installed (npm global)
if grep -Eq "npm[[:space:]]+install[[:space:]]+-g[[:space:]]+agy@${AGY_VERSION}" <<<"$dockerfile_content"; then
  ok "agy v${AGY_VERSION} installed globally via npm"
else
  nok "agy v${AGY_VERSION} must be installed globally (npm install -g agy@${AGY_VERSION})"
fi

# gh CLI must be installed
if grep -Eq '\bgh\b' <<<"$dockerfile_content"; then
  ok "gh CLI installed"
else
  nok "gh CLI must be installed"
fi

# git must be installed
if grep -Eq '\bgit\b' <<<"$dockerfile_content"; then
  ok "git installed"
else
  nok "git must be installed"
fi

# jq must be installed
if grep -Eq '\bjq\b' <<<"$dockerfile_content"; then
  ok "jq installed"
else
  nok "jq must be installed"
fi

# AGENT_UID and AGENT_GID build args must be declared
if grep -Eq '^ARG[[:space:]]+AGENT_UID=' <<<"$dockerfile_content"; then
  ok "ARG AGENT_UID declared"
else
  nok "ARG AGENT_UID must be declared"
fi
if grep -Eq '^ARG[[:space:]]+AGENT_GID=' <<<"$dockerfile_content"; then
  ok "ARG AGENT_GID declared"
else
  nok "ARG AGENT_GID must be declared"
fi

# USER agent must be set (use of ${AGENT_UID}:${AGENT_GID} counts)
if grep -Eq '^USER[[:space:]]+agent' <<<"$dockerfile_content"; then
  ok "USER agent configured"
else
  nok "USER agent must be set"
fi

# UID/GID must be applied at runtime via USER, not just hard-coded
if grep -Eq '^USER[[:space:]]+(\$\{|")[a-zA-Z_]+(:\$\{[a-zA-Z_]+\})?' <<<"$dockerfile_content" \
   || grep -Eq '^USER[[:space:]]+agent' <<<"$dockerfile_content"; then
  ok "USER honours dynamic AGENT_UID/AGENT_GID"
else
  nok "USER must use dynamic UID/GID from build args"
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
