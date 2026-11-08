# syntax=docker/dockerfile:1
#
# Development/test toolchain for Doctbase.
#
# Build context is the repository root so the image is built with the same
# .zigversion pin used by native installs:
#   docker build -f deploy/dev/Dockerfile -t doctbase/dev-toolchain .
#
# The source tree is mounted at /src by deploy/dev/compose.yml; this image only
# provides Zig plus the tools needed by `zig build`.
FROM debian:13-slim

ARG ZIG_VERSION=0.17.1
ARG TARGETARCH

ENV ZIG_GLOBAL_CACHE_DIR=/src/.zig-global-cache \
    ZIG_LOCAL_CACHE_DIR=/src/.zig-cache

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git passwd xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) zig_arch=x86_64 ;; \
      arm64) zig_arch=aarch64 ;; \
      *) echo "unsupported container architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    zig_version="${ZIG_VERSION:-0.17.1}"; \
    zig_version="${zig_version#v}"; \
    curl -fsSL "https://ziglang.org/download/${zig_version}/zig-${zig_arch}-linux-${zig_version}.tar.xz" -o /tmp/zig.tar.xz; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    ln -sf "/opt/zig-${zig_arch}-linux-${zig_version}/zig" /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz; \
    zig version

RUN useradd --create-home --uid 1000 --shell /bin/bash dev
USER dev
WORKDIR /src

CMD ["zig", "version"]
