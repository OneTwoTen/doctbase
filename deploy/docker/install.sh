#!/bin/sh
# Doctbase Docker one-line installer.
#
# Usage:
#   sh deploy/docker/install.sh --domain example.com --email admin@example.com --yes
#   curl -fsSL https://get.doctbase.dev/docker | sh -s -- --domain example.com
#
# The release server publishes this script; in a repository checkout use the
# path above. The script is a thin wrapper: file generation and secret handling
# stay in `doctbase init --profile docker`, and Compose remains the lifecycle
# owner through `doctbase up --profile docker`.
#
# Requirements: Docker Engine with Compose v2, and a `doctbase` binary from the
# release bundle (or set DOCTBASE_BIN). Images must be published under
# DOCTBASE_IMAGE_PREFIX; use DOCTBASE_VERSION to pin a release.

set -eu

directory="${DOCTBASE_DIR:-/opt/doctbase}"
domain=""
email=""
database="external"
assets="${DOCTBASE_ASSETS:-}"
dry_run=""

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --domain HOST              Public dashboard domain (optional; local mode without it)
  --email ADDR               ACME account email (optional)
  --dir DIR                  Deployment directory (default /opt/doctbase)
  --database external|bundled
                             Use an external PostgreSQL or the bundled profile
  --assets DIR               Directory containing deploy/docker/compose.yml.tmpl
  --version VERSION          Image tag (default latest)
  --image-prefix PREFIX      Image repository prefix (default doctbase)
  --dry-run                  Print the plan without writing or starting anything
  --yes                      Non-interactive (accepted for one-line compatibility)
  -h, --help                 Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --domain) domain="$2"; shift 2 ;;
        --email) email="$2"; shift 2 ;;
        --dir) directory="$2"; shift 2 ;;
        --database) database="$2"; shift 2 ;;
        --assets) assets="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --image-prefix) image_prefix="$2"; shift 2 ;;
        --dry-run) dry_run="--dry-run"; shift ;;
        --yes|-y) shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[docker-install] unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$assets" ]; then
    if [ -f ./deploy/docker/compose.yml.tmpl ]; then
        assets="."
    else
        assets="/usr/local/lib/doctbase/current/share"
    fi
fi

bin="${DOCTBASE_BIN:-}"
if [ -z "$bin" ]; then
    if command -v doctbase >/dev/null 2>&1; then
        bin="doctbase"
    elif [ -x ./zig-out/bin/doctbase ]; then
        bin="./zig-out/bin/doctbase"
    fi
fi
if [ -z "$bin" ]; then
    echo "[docker-install] doctbase binary not found." >&2
    echo "[docker-install] Set DOCTBASE_BIN or install the release bundle first." >&2
    exit 1
fi
if ! command -v "$bin" >/dev/null 2>&1 && [ ! -x "$bin" ]; then
    echo "[docker-install] doctbase binary is not executable: $bin" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "[docker-install] docker is required for the Docker profile." >&2
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "[docker-install] Docker Compose v2 is required." >&2
    exit 1
fi

case "$database" in
    external|bundled) ;;
    *) echo "[docker-install] --database must be external or bundled." >&2; exit 2 ;;
esac

set -- init --profile docker --dir "$directory" --database "$database" --assets "$assets" --yes
[ -n "$domain" ] && set -- "$@" --domain "$domain"
[ -n "$email" ] && set -- "$@" --email "$email"
[ -n "${version:-}" ] && set -- "$@" --version "$version"
[ -n "${image_prefix:-}" ] && set -- "$@" --image-prefix "$image_prefix"
[ -n "$dry_run" ] && set -- "$@" --dry-run

"$bin" "$@"

if [ -n "$dry_run" ]; then
    "$bin" up --profile docker --dir "$directory" --dry-run
else
    "$bin" up --profile docker --dir "$directory"
fi

echo "[docker-install] Doctbase Docker deployment is starting in $directory"
echo "[docker-install] Check: docker compose -f $directory/compose.yml ps"
