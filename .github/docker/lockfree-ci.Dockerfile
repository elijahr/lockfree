# lockfree-ci — minimal CI runner image for the lockfree project.
#
# Multi-arch: linux/amd64 (real GHA runners) + linux/arm64 (operator
# M-series Mac running act natively, no qemu emulation).
#
# Built and published by .github/workflows/build-image.yml to:
#   ghcr.io/elijahr/lockfree-ci:nim-<version>-<sha>
#   ghcr.io/elijahr/lockfree-ci:latest
#
# Why a custom image rather than catthehacker/ubuntu:* variants:
#   - js-latest installs node via nvm; bare `docker exec cmd=[node ...]`
#     can't find it (no shell init). actions/cache@v4 crashes.
#   - full-latest is 70GB extracted; pull cost + disk cost prohibitive.
#   - Our needs are narrow: ubuntu base + Nim (pinned) + node + git + gh.
#     ~2-3GB image, fast pull, deterministic.
#
# Why asdf-nim rather than mise:
#   - asdf-nim ships pre-compiled binaries for linux/amd64, linux/arm64,
#     macos/amd64, macos/arm64. mise's nim plugin (and its aqua fallback
#     arrow2nd/nimotsu) is amd64-only, so mise-based builds require qemu
#     emulation on arm64 hosts.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Base toolchain + GHA-action prerequisites.
# - build-essential: gcc/clang + linker for Nim's C output
# - nodejs: at /usr/bin/node so actions/cache@v4 + actions/checkout@v4
#   work under act (bare docker exec PATH = /usr/bin)
# - git + gh: for actions/checkout@v4 + any gh-based workflow steps
# - valgrind: cell 8/9 (Tier C; harmless extra in Tier A image)
# - ca-certificates + curl: for asdf installer + general HTTPS
# - libpcre3-dev: Nim regex backend (some test files)
# - clang: TSAN/ASAN cells use --cc:clang
# - bash: asdf is a bash script
# - xz-utils: asdf-nim's binary tarballs are xz-compressed
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        clang \
        curl \
        git \
        gh \
        libpcre3-dev \
        nodejs \
        valgrind \
        xz-utils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install asdf to a system-wide location so the bare-exec PATH can
# resolve it without sourcing /etc/profile.
ENV ASDF_DIR=/opt/asdf
ENV ASDF_DATA_DIR=/opt/asdf
ENV PATH=/opt/asdf/bin:/opt/asdf/shims:$PATH

# Pin asdf to a recent stable release rather than tracking master.
ARG ASDF_VERSION=v0.14.1

RUN git clone --depth 1 --branch ${ASDF_VERSION} https://github.com/asdf-vm/asdf.git /opt/asdf \
    && /opt/asdf/bin/asdf plugin add nim https://github.com/asdf-community/asdf-nim.git \
    && /opt/asdf/bin/asdf install nim 2.2.10 \
    && /opt/asdf/bin/asdf global nim 2.2.10

# asdf installs Nim into /opt/asdf/installs/nim/2.2.10/. The shim
# /opt/asdf/shims/nim is on PATH (set above) and works under bare
# docker exec. Also symlink nim/nimble into /usr/local/bin for
# belt-and-suspenders coverage when PATH is reset by an action.
RUN ln -sf /opt/asdf/shims/nim /usr/local/bin/nim \
    && ln -sf /opt/asdf/shims/nimble /usr/local/bin/nimble

# Verify everything is reachable from a bare PATH lookup (no shell init).
RUN /usr/bin/node --version \
    && /usr/local/bin/nim --version | head -1 \
    && /usr/local/bin/nimble --version | head -1 \
    && /usr/bin/git --version \
    && /usr/bin/gh --version | head -1

WORKDIR /workspace
