#!/bin/sh
# Container healthcheck: asks the local service for /healthz.
# DOCTBASE_HTTP_PORT is set per service in deploy/docker/compose.yml.
set -eu

port="${DOCTBASE_HTTP_PORT:-8080}"
exec curl -fsS --max-time 3 "http://127.0.0.1:${port}/healthz" >/dev/null
