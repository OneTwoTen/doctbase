# syntax=docker/dockerfile:1.7
#
# Production image for a single Doctbase service (gateway, management, ...).
#
# Build one service per image so each container carries only its own binary:
#   docker build -f deploy/docker/Dockerfile --build-arg SERVICE=gateway -t doctbase/gateway .
#   docker build -f deploy/docker/Dockerfile --build-arg SERVICE=management --target management -t doctbase/management .
#
# deploy/docker/compose.yml does this per service.
ARG ZIG_VERSION=0.17.1

FROM node:22-bookworm-slim AS dashboard-build
WORKDIR /src/dashboard
COPY dashboard/package.json dashboard/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY dashboard/ ./
RUN npm run check && npm run build

FROM debian:13-slim AS build
ARG ZIG_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) zig_arch=x86_64 ;; \
      arm64) zig_arch=aarch64 ;; \
      *) echo "unsupported build architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    zig_version="${ZIG_VERSION:-0.17.1}"; \
    zig_version="${zig_version#v}"; \
    curl -fsSL "https://ziglang.org/download/${zig_version}/zig-${zig_arch}-linux-${zig_version}.tar.xz" -o /tmp/zig.tar.xz; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    ln -sf "/opt/zig-${zig_arch}-linux-${zig_version}/zig" /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz; \
    zig version

WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/root/.cache/zig \
    mkdir -p /root/.cache/zig/p && \
    if [ -d "/src/zig-pkg" ]; then cp -rn /src/zig-pkg/* /root/.cache/zig/p/ 2>/dev/null || true; fi && \
    zig build -Doptimize=ReleaseSafe

FROM debian:13-slim AS runtime
ARG SERVICE=gateway

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --create-home --uid 10001 --shell /usr/sbin/nologin doctbase \
 && mkdir -p /var/lib/doctbase /etc/doctbase /run/doctbase \
 && chown -R doctbase:doctbase /var/lib/doctbase /etc/doctbase /run/doctbase

COPY --from=build "/src/zig-out/bin/doctbase-${SERVICE}" /usr/local/bin/doctbase-service
COPY --chmod=0755 deploy/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 deploy/docker/healthcheck.sh /usr/local/bin/healthcheck.sh

ENV DOCTBASE_MODE=docker \
    DOCTBASE_CONFIG=/etc/doctbase/doctbase.toml

USER doctbase
WORKDIR /var/lib/doctbase

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/local/bin/doctbase-service"]

FROM runtime AS management
COPY --from=dashboard-build /src/dashboard/build/ /opt/doctbase/dashboard/

FROM runtime AS release
