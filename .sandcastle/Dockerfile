# Ralph Loop base image.
#
# Minimal sandbox for the antigravity-cli (agy) agent that the Ralph Loop
# orchestrator drives from the host. Sized for ~350MB (vs ~2.4GB for the
# previous bookworm + opencode-ai image).
#
# Build:
#   docker build -t ralph-loop-base .sandcastle/Dockerfile
#   # or via sandcastle:
#   sandcastle docker build-image
#
# The image ships with: agy v1.0.8, gh CLI, git, jq, curl, bash.
# Host credentials for agy must be mounted read-only at runtime:
#   -v ~/.config/antigravity-cli:/home/agent/.config/antigravity-cli:ro
# See .sandcastle/smoke-test.sh for the full acceptance-criteria check.

FROM node:22-alpine

ARG AGENT_UID=1000
ARG AGENT_GID=1000

# System packages. github-cli comes from the Alpine community repo, so we
# append it to the repositories list before running apk.
RUN set -eux \
  && echo "https://dl-cdn.alpinelinux.org/alpine/v$(cat /etc/alpine-release | cut -d. -f1-2)/community" >> /etc/apk/repositories \
  && apk add --no-cache \
       bash \
       curl \
       git \
       github-cli \
       jq \
  && rm -rf /var/cache/apk/*

# agy v1.0.8 — the agent engine for the Ralph Loop.
RUN npm install -g agy@1.0.8 \
  && npm cache clean --force

# Rename the base image's "node" user/group to "agent" and align UID/GID
# with the host user that drives the loop. Renaming avoids clashing with
# any future host user named "node" and gives the credential-mount path a
# stable owner.
RUN set -eux \
  && groupmod -g "$AGENT_GID" -n agent node \
  && usermod  -u "$AGENT_UID" -g "$AGENT_GID" -d /home/agent -m -l agent node

USER agent
WORKDIR /home/agent

# Force English git output so future shell tooling can rely on it.
ENV LC_ALL=C

# Smoke entrypoint: keep the container alive so docker exec works against it.
ENTRYPOINT ["sleep", "infinity"]
