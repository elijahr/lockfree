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
# Why vfox + vfox-nim + vfox-nodejs rather than mise or asdf:
#   - vfox-nim ships pre-compiled Nim binaries for linux/amd64,
#     linux/arm64, macos/amd64, macos/arm64 (via Nim's nightly
#     infrastructure when official binaries don't exist for the
#     platform). mise's nim plugin (and its aqua fallback
#     arrow2nd/nimotsu) is amd64-only, so mise-based builds require
#     qemu emulation on arm64 hosts.
#   - vfox is a single Go binary (~5MB) with no bash dependency; asdf
#     is a bash script + plugin tree that bloats the image and adds
#     shell-init footguns.
#   - vfox-nodejs (official version-fox plugin) handles node 20
#     installs the same way asdf-nodejs did.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Base toolchain + GHA-action prerequisites.
# - build-essential: gcc/clang + linker for Nim's C output
# - git + gh: for actions/checkout@v4 + any gh-based workflow steps
# - valgrind: cell 8/9 (Tier C; harmless extra in Tier A image)
# - ca-certificates + curl: for vfox plugin downloads + general HTTPS
# - libpcre3-dev: Nim regex backend (some test files)
# - clang: TSAN/ASAN cells use --cc:clang
# - bash: still useful for workflow `run:` steps
# - xz-utils: vfox-nim's binary tarballs are xz-compressed
# - unzip: vfox extracts plugin .zip archives
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
        unzip \
        valgrind \
        xz-utils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# vfox install. Pinned version + multi-arch dispatch. vfox ships .deb
# packages for linux_x86_64 and linux_aarch64, which we install via
# dpkg for a clean apt-style install (dropping /usr/bin/vfox plus
# completions).
ARG VFOX_VERSION=1.0.11

# vfox-nim v0.1.1 fix landed on main as commit ad7f3d3 (linux/arm64
# normalize_arch). Pinning to the SHA until the operator dispatches
# elijahr/vfox-nim's Release workflow to tag v0.1.1; this line flips
# back to v0.1.1 then (see lockfree v0.1.0 impl plan §5.2).
ARG VFOX_NIM_REF=ad7f3d3

# vfox-nodejs plugin: we install via vfox's official plugin registry
# (`vfox add nodejs`), so no ref pin here — vfox pulls the latest
# registry manifest at image-build time. Plugin version is captured
# in the build log for reproducibility.

# Nim + Node pins. Nim 2.2.10 = current Nim 2.2 LTS; Node 20.18.0 =
# Node 20 LTS (required by actions/cache@v4, actions/checkout@v4
# which declare `using: node20`).
ARG NIM_VERSION=2.2.10
ARG NODE_VERSION=20.18.0

# System-wide VFOX_HOME so the bare-exec PATH can resolve installs
# without sourcing /etc/profile. Plugins land under $VFOX_HOME/plugin,
# SDK installs under $VFOX_HOME/cache.
ENV VFOX_HOME=/opt/vfox

# Put nimble's binary install dir on PATH so workflow steps can call
# nimble-installed binaries (typestates, etc.) by bare name. vfox-nim
# does not set NIMBLE_DIR, so nimble defaults to $HOME/.nimble; act
# runs jobs as root (HOME=/root), so /root/.nimble/bin is the path.
# (The asdf-era image got this for free via /opt/asdf/shims, which
# contained an auto-generated `typestates` shim after `nimble install`.
# vfox is shim-free by design, so we add the bin dir directly.)
ENV PATH=/root/.nimble/bin:$PATH

RUN ARCH=$(dpkg --print-architecture) && \
    case "$ARCH" in \
      amd64) VFOX_ARCH=x86_64 ;; \
      arm64) VFOX_ARCH=aarch64 ;; \
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/vfox.deb \
      "https://github.com/version-fox/vfox/releases/download/v${VFOX_VERSION}/vfox_${VFOX_VERSION}_linux_${VFOX_ARCH}.deb" && \
    dpkg -i /tmp/vfox.deb && \
    rm /tmp/vfox.deb && \
    vfox --version

# Add the elijahr/vfox-nim plugin from a pinned ref. vfox's `add
# --source` rejects URLs that don't end in `.zip` (its type-detection
# splits on the trailing dot), so we pre-download the zipball through
# the GitHub codeload API to a local `.zip` file and feed THAT to
# vfox. Plugin alias is `nim` so `vfox install nim@<version>` resolves.
#
# The vfox-nodejs plugin is pulled from vfox's official plugin
# registry (no source URL needed).
RUN mkdir -p $VFOX_HOME && \
    curl -fsSL -o /tmp/vfox-nim.zip \
      "https://api.github.com/repos/elijahr/vfox-nim/zipball/${VFOX_NIM_REF}" && \
    vfox add --source /tmp/vfox-nim.zip --alias nim && \
    rm /tmp/vfox-nim.zip && \
    vfox add nodejs

# Install pinned Nim + Node toolchains. --yes skips interactive
# prompts (which would hang in a non-TTY Docker build).
#
# Path layout produced by vfox + vfox-nim / vfox-nodejs:
#   $VFOX_HOME/cache/<plugin>/v-<version>/<plugin>-<version>/bin/<binary>
# The double-version nesting is because the upstream tarball's top-
# level directory is preserved (`nim-2.2.10/`, `node-v20.18.0/`-like)
# and vfox itself wraps that under `v-<version>/`. The post-install
# hooks check for this layout and leave it intact when files are
# already in place.
RUN vfox install --yes nim@${NIM_VERSION} && \
    vfox install --yes nodejs@${NODE_VERSION}

# Symlink directly to the vfox-installed binaries (NOT to any vfox
# shim or shell-activated PATH). vfox manages active versions through
# a shell hook (`vfox activate`), which our bare `docker exec` steps
# don't run. Direct symlinks to the real binaries have zero env
# dependency — same rationale as the asdf-shim issue we avoided
# previously.
#
# Symlink in both /usr/bin AND /usr/local/bin: act's `run:` workflow
# steps exec under `sh -e` with a stripped PATH; some contexts
# (notably actions/cache@v4's pre/post restore steps) include
# /usr/bin but not /usr/local/bin, and other contexts the inverse.
# Linking in both is cheap and makes resolution context-independent.
RUN NIM_INSTALL=${VFOX_HOME}/cache/nim/v-${NIM_VERSION}/nim-${NIM_VERSION} && \
    NODE_INSTALL=${VFOX_HOME}/cache/nodejs/v-${NODE_VERSION}/nodejs-${NODE_VERSION} && \
    for d in /usr/bin /usr/local/bin; do \
      ln -sf ${NIM_INSTALL}/bin/nim    ${d}/nim && \
      ln -sf ${NIM_INSTALL}/bin/nimble ${d}/nimble && \
      ln -sf ${NODE_INSTALL}/bin/node  ${d}/node && \
      ln -sf ${NODE_INSTALL}/bin/npm   ${d}/npm && \
      ln -sf ${NODE_INSTALL}/bin/npx   ${d}/npx ; \
    done

# Verify everything is reachable from BOTH /usr/bin and /usr/local/bin
# so a stripped-PATH `sh -e` exec context (which is what act passes for
# `run:` workflow steps) finds the tooling. Same verification matrix as
# the asdf-era image.
RUN /usr/bin/node --version | grep -q '^v20\.' && echo "Node 20 verified" \
    && /usr/local/bin/node --version \
    && /usr/bin/nim --version | head -1 \
    && /usr/bin/nimble --version | head -1 \
    && /usr/local/bin/nim --version | head -1 \
    && /usr/local/bin/nimble --version | head -1 \
    && /usr/bin/git --version \
    && /usr/bin/gh --version | head -1

WORKDIR /workspace
