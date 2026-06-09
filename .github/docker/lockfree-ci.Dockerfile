# lockfree-ci — minimal CI runner image for the lockfree project.
#
# Built and published by .github/workflows/build-image.yml to:
#   ghcr.io/elijahr/lockfree-ci:nim-<version>-<sha>
#   ghcr.io/elijahr/lockfree-ci:latest
#
# Used by .actrc (local act runs) and ci.yml's container: directive
# (GHA matrix cells). Same image both places = bit-identical environment.
#
# Why a custom image rather than catthehacker/ubuntu:* variants:
#   - js-latest installs node via nvm; bare `docker exec cmd=[node ...]`
#     can't find it (no shell init). actions/cache@v4 crashes.
#   - full-latest is 70GB extracted; pull cost + disk cost prohibitive.
#   - Our needs are narrow: ubuntu base + Nim (pinned) + node + git + gh.
#     ~2-3GB image, fast pull, deterministic.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Base toolchain + GHA-action prerequisites.
# - build-essential: gcc/clang + linker for Nim's C output
# - nodejs: at /usr/bin/node so actions/cache@v4 + actions/checkout@v4 work under act
# - git + gh: for actions/checkout@v4 + any gh-based workflow steps
# - valgrind: cell 8/9 (Tier C; harmless extra in Tier A image)
# - ca-certificates + curl: for mise installer
# - libpcre3-dev: Nim regex backend (some test files)
# - clang: TSAN/ASAN cells use --cc:clang
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        curl \
        git \
        gh \
        libpcre3-dev \
        nodejs \
        valgrind \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install mise (binary download, no compile)
RUN curl -fsSL https://mise.run | sh && \
    install -m 0755 /root/.local/bin/mise /usr/local/bin/mise && \
    rm -rf /root/.local/bin

# Install Nim via mise to a system-wide location, then symlink into
# /usr/local/bin so the bare `docker exec` PATH finds it.
ENV MISE_DATA_DIR=/opt/mise
ENV MISE_CONFIG_DIR=/etc/mise
RUN mkdir -p /opt/mise /etc/mise && \
    mise install nim@2.2.10 && \
    ln -sf /opt/mise/installs/nim/2.2.10/bin/nim /usr/local/bin/nim && \
    ln -sf /opt/mise/installs/nim/2.2.10/bin/nimble /usr/local/bin/nimble

# Verify everything is reachable from a bare PATH lookup (no shell init).
RUN /usr/bin/node --version && \
    /usr/local/bin/nim --version | head -1 && \
    /usr/local/bin/nimble --version | head -1 && \
    /usr/bin/git --version && \
    /usr/bin/gh --version | head -1

WORKDIR /workspace
