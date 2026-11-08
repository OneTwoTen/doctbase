#!/bin/sh
# Fresh-host native install E2E for Doctbase.
#
# Run as root on a clean Ubuntu 24.04/26.04 or Debian 13 VM/container. The script
# installs Doctbase in local mode by default (no domain/TLS), validates the
# result, and never prints secret values.
#
# Required inputs (auto-detected when running from a repository checkout):
#   DOCTBASE_BIN_DIR   directory containing doctbase-* binaries
#   DOCTBASE_ASSETS    directory containing deploy/ and infrastructure/ templates
#
# Optional:
#   DOCTBASE_DOMAIN / DOCTBASE_ADMIN_EMAIL   enable Caddy automatic HTTPS
#   DOCTBASE_E2E_ALLOW_EXISTING=1            do not require a fresh host
#   DOCTBASE_E2E_IDEMPOTENT=1                run install twice
#   DOCTBASE_E2E_REPAIR=1                    run `doctbase repair --yes` afterwards
#   DOCTBASE_E2E_UNINSTALL=1                 exercise keep-data uninstall at the end
#   DOCTBASE_E2E_MAX_SECONDS=300             install time budget
#   DOCTBASE_E2E_SKIP_TIME=1                 do not enforce the budget
#
# Exit codes: 0 pass, 1 failure, 2 unsupported host/prerequisite, 78 skipped.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
DOMAIN=${DOCTBASE_DOMAIN:-}
EMAIL=${DOCTBASE_ADMIN_EMAIL:-}
MAX_SECONDS=${DOCTBASE_E2E_MAX_SECONDS:-300}

log() {
    printf '[e2e-install] %s\n' "$*"
}

fail() {
    printf '[e2e-install] FAIL: %s\n' "$*" >&2
    exit 1
}

skip() {
    printf '[e2e-install] SKIP: %s\n' "$*" >&2
    exit 78
}

trap 'printf "[e2e-install] aborted; inspect install.log and journalctl\n" >&2' EXIT

if [ "$(id -u)" -ne 0 ]; then
    printf '[e2e-install] must run as root\n' >&2
    exit 2
fi

if [ ! -r /etc/os-release ]; then
    printf '[e2e-install] /etc/os-release is missing\n' >&2
    exit 2
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:24.04|ubuntu:26.04|debian:13) ;;
    *)
        printf '[e2e-install] unsupported OS: %s %s\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
        exit 2
        ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *)
        printf '[e2e-install] unsupported architecture: %s\n' "$ARCH" >&2
        exit 2
        ;;
esac

if [ "${DOCTBASE_E2E_ALLOW_EXISTING:-0}" != "1" ]; then
    if [ -e /etc/doctbase ] || [ -e /var/lib/doctbase/state.json ]; then
        fail "host is not fresh (/etc/doctbase or /var/lib/doctbase/state.json exists)"
    fi
fi

BIN_DIR=${DOCTBASE_BIN_DIR:-}
if [ -z "$BIN_DIR" ]; then
    if [ -x "$REPO_ROOT/zig-out/bin/doctbase" ]; then
        BIN_DIR="$REPO_ROOT/zig-out/bin"
    elif command -v doctbase >/dev/null 2>&1; then
        BIN_DIR=$(dirname "$(command -v doctbase)")
    elif command -v zig >/dev/null 2>&1; then
        log "building release binaries with zig"
        (cd "$REPO_ROOT" && zig build) || fail "zig build failed"
        BIN_DIR="$REPO_ROOT/zig-out/bin"
    else
        printf '[e2e-install] doctbase binary not found; set DOCTBASE_BIN_DIR\n' >&2
        exit 2
    fi
fi
[ -x "$BIN_DIR/doctbase" ] || fail "missing $BIN_DIR/doctbase"

ASSETS=${DOCTBASE_ASSETS:-}
if [ -z "$ASSETS" ]; then
    if [ -f "$REPO_ROOT/deploy/native/units/doctbase-app.service.tmpl" ]; then
        ASSETS="$REPO_ROOT"
    else
        ASSETS="/usr/local/lib/doctbase/current/share"
    fi
fi
[ -f "$ASSETS/deploy/native/units/doctbase-app.service.tmpl" ] || fail "assets not found in $ASSETS"

DOCTBASE="$BIN_DIR/doctbase"

log "host: $ID $VERSION_ID $ARCH; binaries: $BIN_DIR; assets: $ASSETS"

set -- install --yes --assets "$ASSETS" --bin-dir "$BIN_DIR"
[ -n "$DOMAIN" ] && set -- "$@" --domain "$DOMAIN"
[ -n "$EMAIL" ] && set -- "$@" --email "$EMAIL"

log "running doctbase install"
INSTALL_STARTED_AT=$(date +%s)
"$DOCTBASE" "$@"
ELAPSED=$(( $(date +%s) - INSTALL_STARTED_AT ))
log "install finished in ${ELAPSED}s"

if [ "${DOCTBASE_E2E_SKIP_TIME:-0}" != "1" ] && [ "$ELAPSED" -gt "$MAX_SECONDS" ]; then
    fail "install took ${ELAPSED}s (budget ${MAX_SECONDS}s)"
fi

[ -s /var/lib/doctbase/state.json ] || fail "missing install state"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"' /var/lib/doctbase/state.json \
    || fail "install state is not healthy"

for socket in gateway management pgbouncer; do
    [ -S "/run/doctbase/$socket.sock" ] || fail "missing /run/doctbase/$socket.sock"
done

STATUS=$("$DOCTBASE" status 2>&1) || fail "doctbase status failed"
printf '%s\n' "$STATUS"
for service in gateway management; do
    printf '%s\n' "$STATUS" | grep -Eq "^${service}[[:space:]].*ready" \
        || fail "$service is not ready in doctbase status"
done

for secret in postgres_admin pgbouncer_auth internal_token admin_setup_token; do
    path="/etc/doctbase/secrets/$secret"
    [ -f "$path" ] || fail "missing secret file $path"
    meta=$(stat -c '%a %U %G' "$path")
    [ "$meta" = "600 root doctbase" ] || fail "$path has unexpected owner/mode: $meta"
done

# Public surface: only Caddy may listen on TCP. PostgreSQL, PgBouncer and the
# Caddy admin API must stay on Unix sockets.
if command -v ss >/dev/null 2>&1; then
    listeners=$(ss -H -ltn || true)
    for port in 5432 5433 6432 2019; do
        if printf '%s\n' "$listeners" | grep -Eq ":${port}([[:space:]]|$)"; then
            fail "internal port $port is listening on TCP"
        fi
    done
fi

[ -S /run/doctbase/caddy-admin.sock ] || fail "missing Caddy admin socket"

# T050: one-time admin setup over the management socket. curl is present in the
# E2E systemd image; on a minimal host without curl this block is skipped so the
# install checks still run.
if command -v curl >/dev/null 2>&1; then
    management_url="http://localhost"
    setup_status=$(curl -fsS --unix-socket /run/doctbase/management.sock "$management_url/setup/status") \
        || fail "setup status request failed"
    printf '%s' "$setup_status" | grep -q '"required":true' \
        || fail "setup status did not report required=true"

    setup_token=$(cat /etc/doctbase/secrets/admin_setup_token)
    setup_code=$(printf '{"setup_token":"%s","email":"admin@example.com","password":"correct-horse-battery"}' "$setup_token" \
        | curl -sS -o /dev/null -w '%{http_code}' \
            --unix-socket /run/doctbase/management.sock \
            -H 'Content-Type: application/json' \
            --data-binary @- "$management_url/setup")
    [ "$setup_code" = "201" ] || fail "admin setup returned HTTP $setup_code"

    setup_status=$(curl -fsS --unix-socket /run/doctbase/management.sock "$management_url/setup/status") \
        || fail "setup status request after setup failed"
    printf '%s' "$setup_status" | grep -q '"required":false' \
        || fail "setup status still required after completion"

    login_code=$(printf '{"email":"admin@example.com","password":"correct-horse-battery"}' \
        | curl -sS -o /dev/null -w '%{http_code}' \
            --unix-socket /run/doctbase/management.sock \
            -H 'Content-Type: application/json' \
            --data-binary @- "$management_url/auth/login")
    [ "$login_code" = "200" ] || fail "admin login returned HTTP $login_code"
    [ -f /var/lib/doctbase/control/admin.json ] || fail "admin store was not persisted"
fi

if [ "${DOCTBASE_E2E_REPAIR:-0}" = "1" ]; then
    log "running repair"
    "$DOCTBASE" repair --yes --assets "$ASSETS" --bin-dir "$BIN_DIR"
    grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"' /var/lib/doctbase/state.json \
        || fail "repair did not restore a healthy state"
fi

if [ "${DOCTBASE_E2E_IDEMPOTENT:-0}" = "1" ]; then
    log "re-running install to check idempotency"
    "$DOCTBASE" "$@" >/dev/null
    grep -Eq '"status"[[:space:]]*:[[:space:]]*"healthy"' /var/lib/doctbase/state.json \
        || fail "second install did not leave a healthy state"
    [ -f /etc/doctbase/secrets/admin_setup_token ] || fail "setup token was removed by re-install"
    [ -f /var/lib/doctbase/control/admin.json ] || fail "admin record was removed by re-install"
    if command -v curl >/dev/null 2>&1; then
        status=$(curl -fsS --unix-socket /run/doctbase/management.sock http://localhost/setup/status) \
            || fail "setup status after re-install failed"
        printf '%s' "$status" | grep -q '"required":false' \
            || fail "setup was reopened by re-install"
    fi
fi

if [ "${DOCTBASE_E2E_UNINSTALL:-0}" = "1" ]; then
    log "running keep-data uninstall"
    "$DOCTBASE" uninstall --yes
    [ ! -S /run/doctbase/gateway.sock ] || fail "gateway socket still exists after uninstall"
    [ -d /etc/doctbase ] || fail "keep-data uninstall removed configuration"
    [ -d /var/lib/doctbase ] || fail "keep-data uninstall removed data"
fi

trap - EXIT
log "PASS: $ID $VERSION_ID $ARCH"
