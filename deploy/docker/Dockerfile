# syntax=docker/dockerfile:1.7
#
# Production image for a single Doctbase service (gateway, management, ...).
#
# Build one service per image so each container carries only its own binary:
#   docker build -f deploy/docker/Dockerfile --build-arg SERVICE=gateway -t doctbase/gateway .
#
# deploy/docker/compose.yml does this per service.
ARG ZIG_VERSION=0.17.1

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
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    ln -sf "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    rm /tmp/zig.tar.xz; \
    zig version

WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/root/.cache/zig \
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
