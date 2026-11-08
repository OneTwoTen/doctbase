# Minimal systemd base for native-install E2E tests.
#
# Used by tests/e2e/matrix-install.sh with --privileged, a host cgroup mount and
# a tmpfs /run so systemd can be PID 1 on Ubuntu/Debian containers.
ARG BASE=ubuntu:24.04
FROM ${BASE}

ENV container=docker
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        systemd \
        systemd-sysv \
        dbus \
        ca-certificates \
        curl \
        gnupg \
        iproute2 \
        procps \
        tzdata \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/*

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
