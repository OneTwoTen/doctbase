#!/bin/sh
# Native install E2E matrix driver.
#
# Cells: Ubuntu 24.04 x86_64, Debian 13 x86_64, Ubuntu 24.04 arm64.
#
# Backends:
#   local   run tests/e2e/install-ubuntu.sh when the current host is the cell
#   docker  build a small systemd image and run the script in a privileged
#           container (Docker Desktop/Linux CI). arm64 needs binfmt/QEMU.
#
# Usage:
#   sh tests/e2e/matrix-install.sh --list
#   sh tests/e2e/matrix-install.sh --dry-run
#   sudo sh tests/e2e/matrix-install.sh --backend local
#   sh tests/e2e/matrix-install.sh --backend docker --targets ubuntu-24.04-x86_64
#
# Environment:
#   DOCTBASE_E2E_BIN_DIR        prebuilt x86_64 binaries (default: zig-out/bin or zig build)
#   DOCTBASE_E2E_ARM64_BIN_DIR  prebuilt arm64 binaries (default: zig build cross)
#   DOCTBASE_E2E_ASSETS         template root visible to this shell
#   DOCTBASE_E2E_HOST_REPO      repository path visible to the Docker daemon
#   DOCTBASE_E2E_HOST_ASSETS    assets path visible to the Docker daemon
#   DOCTBASE_DOMAIN / DOCTBASE_ADMIN_EMAIL
#   DOCTBASE_E2E_MAX_SECONDS    install budget passed to the cell (default 300)
#   DOCTBASE_E2E_REPAIR=1       run repair after install
#   DOCTBASE_E2E_IDEMPOTENT=1   run install twice
#   DOCTBASE_E2E_UNINSTALL=1    exercise keep-data uninstall
#   DOCTBASE_E2E_STRICT=1       fail when a cell cannot run instead of skipping
#
# Exit codes: 0 all selected cells passed (or skipped leniently), 1 failure,
# 2 usage/prerequisite, 78 no cell could run.

set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
# Docker bind mounts are resolved by the *daemon*, not by this shell. When the
# matrix driver itself runs inside a container with a mounted Docker socket,
# set DOCTBASE_E2E_HOST_REPO/ASSETS/BIN_* to host-visible paths.
HOST_REPO=${DOCTBASE_E2E_HOST_REPO:-$REPO_ROOT}
CELLS="ubuntu-24.04-x86_64 debian-13-x86_64 ubuntu-24.04-aarch64"
BACKEND=auto
TARGETS=""
DRY_RUN=0
LIST=0
KEEP=0
STRICT=${DOCTBASE_E2E_STRICT:-0}

log() {
    printf '[e2e-matrix] %s\n' "$*" >&2
}

die() {
    printf '[e2e-matrix] %s\n' "$*" >&2
    exit 2
}

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --backend) BACKEND="$2"; shift 2 ;;
        --backend=*) BACKEND="${1#*=}"; shift ;;
        --targets) TARGETS="$2"; shift 2 ;;
        --targets=*) TARGETS="${1#*=}"; shift ;;
        --keep) KEEP=1; shift ;;
        --strict) STRICT=1; shift ;;
        -h|--help) usage ;;
        *) die "unknown option: $1" ;;
    esac
done

case "$BACKEND" in
    auto|local|docker) ;;
    *) die "--backend must be auto, local or docker" ;;
esac

host_cell() {
    if [ ! -r /etc/os-release ]; then
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *) return 1 ;;
    esac
    printf '%s-%s-%s\n' "${ID:-}" "${VERSION_ID:-}" "$arch"
}

cell_base_image() {
    case "$1" in
        ubuntu-24.04-*) printf 'ubuntu:24.04\n' ;;
        debian-13-*) printf 'debian:13\n' ;;
        *) return 1 ;;
    esac
}

cell_platform() {
    case "$1" in
        *-aarch64) printf 'linux/arm64\n' ;;
        *) printf 'linux/amd64\n' ;;
    esac
}

cell_arch() {
    case "$1" in
        *-aarch64) printf 'aarch64\n' ;;
        *) printf 'x86_64\n' ;;
    esac
}

selected() {
    if [ -z "$TARGETS" ]; then
        return 0
    fi
    for target in $(printf '%s' "$TARGETS" | tr ',' ' '); do
        [ "$target" = "$1" ] && return 0
    done
    return 1
}

HOST_CELL=$(host_cell || true)

if [ "$LIST" = "1" ]; then
    printf 'host: %s\n' "${HOST_CELL:-unsupported}"
    for cell in $CELLS; do
        selected "$cell" || continue
        printf '%s\t%s\t%s\n' "$cell" "$(cell_base_image "$cell")" "$(cell_platform "$cell")"
    done
    exit 0
fi

need_docker() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

build_binaries() {
    arch=$1
    if [ "$arch" = "x86_64" ] && [ -n "${DOCTBASE_E2E_BIN_DIR:-}" ]; then
        printf '%s\n' "$DOCTBASE_E2E_BIN_DIR"
        return 0
    fi
    if [ "$arch" = "aarch64" ] && [ -n "${DOCTBASE_E2E_ARM64_BIN_DIR:-}" ]; then
        printf '%s\n' "$DOCTBASE_E2E_ARM64_BIN_DIR"
        return 0
    fi
    if [ "$arch" = "x86_64" ] && [ -x "$REPO_ROOT/zig-out/bin/doctbase" ]; then
        printf '%s\n' "$REPO_ROOT/zig-out/bin"
        return 0
    fi
    command -v zig >/dev/null 2>&1 || return 1

    prefix="$WORK/bin-$arch"
    log "building $arch binaries into $prefix"
    case "$arch" in
        x86_64) (cd "$REPO_ROOT" && zig build --prefix "$prefix") ;;
        aarch64) (cd "$REPO_ROOT" && zig build -Dtarget=aarch64-linux-gnu --prefix "$prefix") ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$prefix/bin"
}

ensure_assets() {
    if [ -n "${DOCTBASE_E2E_ASSETS:-}" ]; then
        printf '%s\n' "$DOCTBASE_E2E_ASSETS"
    else
        printf '%s\n' "$REPO_ROOT"
    fi
}

ensure_host_assets() {
    if [ -n "${DOCTBASE_E2E_HOST_ASSETS:-}" ]; then
        printf '%s\n' "$DOCTBASE_E2E_HOST_ASSETS"
    else
        ensure_assets
    fi
}

systemd_image() {
    base=$1
    platform=$2
    tag="doctbase-e2e-systemd:$(printf '%s' "$base-$platform" | tr ':/.' '---')"
    if docker image inspect "$tag" >/dev/null 2>&1; then
        printf '%s\n' "$tag"
        return 0
    fi
    log "building systemd E2E image for $base ($platform)"
    # Build context is read by the *client*, so use the path visible to this
    # shell. Bind mounts below use HOST_REPO because the daemon resolves them.
    docker build -q \
        --platform "$platform" \
        -f "$REPO_ROOT/tests/e2e/systemd.Dockerfile" \
        --build-arg "BASE=$base" \
        -t "$tag" \
        "$REPO_ROOT/tests/e2e" >/dev/null || return 1
    printf '%s\n' "$tag"
}

WAIT_SYSTEMD=90

# qemu-user (used for linux/arm64 on an amd64 Docker host) does not implement
# every syscall systemd needs for `LoadCredential=`. Probe the capability so an
# emulated host is reported as skipped instead of as an installer regression.
credentials_supported() {
    name=$1
    docker exec "$name" sh -c '
        umask 077
        printf ok >/run/doctbase-e2e-credential
        printf "%s\n" \
            "[Unit]" \
            "Description=Doctbase E2E credential capability probe" \
            "" \
            "[Service]" \
            "User=nobody" \
            "Group=nogroup" \
            "LoadCredential=e2e:/run/doctbase-e2e-credential" \
            "ExecStart=/bin/true" \
            >/etc/systemd/system/doctbase-e2e-credential.service
        systemctl daemon-reload
        systemctl start doctbase-e2e-credential.service || exit 1
        ! systemctl is-failed --quiet doctbase-e2e-credential.service
    ' >/dev/null 2>&1
}

wait_for_systemd() {
    name=$1
    i=0
    while [ "$i" -lt "$WAIT_SYSTEMD" ]; do
        state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
        case "$state" in
            running|degraded) return 0 ;;
        esac
        i=$((i + 1))
        sleep 1
    done
    docker logs "$name" 2>&1 | tail -50 >&2 || true
    return 1
}

run_local() {
    cell=$1
    log "local cell $cell"
    if [ "$DRY_RUN" = "1" ]; then
        log "would run: sh tests/e2e/install-ubuntu.sh"
        return 0
    fi
    if [ "$HOST_CELL" != "$cell" ]; then
        log "SKIP $cell: current host is ${HOST_CELL:-unsupported}"
        return 78
    fi
    (cd "$REPO_ROOT" && sh tests/e2e/install-ubuntu.sh)
}

run_docker() {
    cell=$1
    base=$(cell_base_image "$cell") || return 1
    platform=$(cell_platform "$cell")
    arch=$(cell_arch "$cell")

    if [ "$DRY_RUN" = "1" ]; then
        log "would run $cell in docker ($base, $platform)"
        log "would build image via tests/e2e/systemd.Dockerfile and run install-ubuntu.sh"
        return 0
    fi

    if ! need_docker; then
        log "SKIP $cell: docker is unavailable"
        return 78
    fi

    bin_dir=$(build_binaries "$arch") || {
        log "SKIP $cell: no $arch binaries (set DOCTBASE_E2E_BIN_DIR/DOCTBASE_E2E_ARM64_BIN_DIR)"
        return 78
    }
    host_assets=$(ensure_host_assets)
    image=$(systemd_image "$base" "$platform") || {
        log "SKIP $cell: cannot build/run systemd image for $platform (install binfmt/qemu?)"
        return 78
    }
    name="doctbase-e2e-$(printf '%s' "$cell" | tr '.' '-')"

    docker rm -f "$name" >/dev/null 2>&1 || true
    log "starting $cell container ($name)"
    if ! docker run -d --name "$name" \
        --privileged --cgroupns=host --platform "$platform" \
        -v "$HOST_REPO":/src \
        -v "$bin_dir":/artifacts/bin:ro \
        -v "$host_assets":/artifacts/share:ro \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock \
        "$image" >/dev/null; then
        docker rm -f "$name" >/dev/null 2>&1 || true
        log "SKIP $cell: cannot start privileged systemd container (platform $platform)"
        return 78
    fi

    if ! wait_for_systemd "$name"; then
        if docker logs "$name" 2>&1 | grep -qi 'exec format error'; then
            log "SKIP $cell: $platform emulation is unavailable on this Docker host"
            [ "$KEEP" = "1" ] || docker rm -f "$name" >/dev/null 2>&1 || true
            return 78
        fi
        log "FAIL $cell: systemd did not become ready"
        [ "$KEEP" = "1" ] || docker rm -f "$name" >/dev/null 2>&1 || true
        return 1
    fi
    if ! credentials_supported "$name"; then
        log "SKIP $cell: systemd LoadCredential is unsupported on this host (qemu-user emulation?)"
        [ "$KEEP" = "1" ] || docker rm -f "$name" >/dev/null 2>&1 || true
        return 78
    fi

    log "running install E2E in $cell"
    set +e
    docker exec \
        -e "DOCTBASE_BIN_DIR=/artifacts/bin" \
        -e "DOCTBASE_ASSETS=/artifacts/share" \
        -e "DOCTBASE_DOMAIN=${DOCTBASE_DOMAIN:-}" \
        -e "DOCTBASE_ADMIN_EMAIL=${DOCTBASE_ADMIN_EMAIL:-}" \
        -e "DOCTBASE_E2E_MAX_SECONDS=${DOCTBASE_E2E_MAX_SECONDS:-300}" \
        -e "DOCTBASE_E2E_IDEMPOTENT=${DOCTBASE_E2E_IDEMPOTENT:-0}" \
        -e "DOCTBASE_E2E_REPAIR=${DOCTBASE_E2E_REPAIR:-0}" \
        -e "DOCTBASE_E2E_UNINSTALL=${DOCTBASE_E2E_UNINSTALL:-0}" \
        -e "DOCTBASE_E2E_SKIP_TIME=${DOCTBASE_E2E_SKIP_TIME:-0}" \
        "$name" sh -c 'cd /src && sh tests/e2e/install-ubuntu.sh'
    status=$?
    set -e

    [ "$KEEP" = "1" ] || docker rm -f "$name" >/dev/null 2>&1 || true
    if [ "$status" -eq 78 ]; then
        log "SKIP $cell"
        return 78
    fi
    return "$status"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/doctbase-e2e-matrix.XXXXXX")
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

passed=0
failed=0
skipped=0

for cell in $CELLS; do
    selected "$cell" || continue

    if [ "$BACKEND" = "auto" ]; then
        if [ "$HOST_CELL" = "$cell" ]; then
            backend=local
        elif need_docker; then
            backend=docker
        else
            log "SKIP $cell: host is ${HOST_CELL:-unsupported} and docker is unavailable"
            skipped=$((skipped + 1))
            continue
        fi
    else
        backend=$BACKEND
    fi

    set +e
    case "$backend" in
        local) run_local "$cell" ;;
        docker) run_docker "$cell" ;;
    esac
    status=$?
    set -e

    case "$status" in
        0) [ "$DRY_RUN" = "1" ] || passed=$((passed + 1)) ;;
        78) [ "$DRY_RUN" = "1" ] || skipped=$((skipped + 1)) ;;
        *)
            failed=$((failed + 1))
            log "FAIL $cell (exit $status)"
            ;;
    esac
done

if [ "$DRY_RUN" = "1" ]; then
    log "dry run complete; no changes were made"
    exit 0
fi

printf '\n[e2e-matrix] summary: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"

if [ "$failed" -ne 0 ]; then
    exit 1
fi
if [ "$STRICT" = "1" ] && [ "$skipped" -ne 0 ]; then
    log "strict mode: skipped cells are failures"
    exit 1
fi
if [ "$passed" -eq 0 ]; then
    exit 78
fi
exit 0
