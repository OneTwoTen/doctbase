#!/bin/sh
# Doctbase native bootstrap installer (thin, signed).
#
# One-line:
#   curl -fsSL https://get.doctbase.dev | sudo sh -s -- --domain example.com --yes
#
# Audited two-step:
#   curl -fsSL https://get.doctbase.dev/install.sh -o install.sh
#   less install.sh
#   sudo sh install.sh --domain example.com --yes
#
# The script downloads a signed manifest, verifies its Ed25519 signature, selects
# the artifact for this architecture, verifies its SHA-256, extracts the bundle,
# installs the CLI and runs `doctbase install`. The release public key must be
# provided with --pubkey or DOCTBASE_RELEASE_PUBKEY_FILE.

set -eu

BASE_URL="${DOCTBASE_RELEASE_URL:-https://get.doctbase.dev/releases}"
VERSION="${DOCTBASE_VERSION:-latest}"
DOMAIN=""
EMAIL=""
YES=""
DRY_RUN=""
MANIFEST=""
ARTIFACT=""
PUBKEY="${DOCTBASE_RELEASE_PUBKEY_FILE:-}"
INSECURE=""

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Options:
  --domain HOST          Public dashboard domain (optional; local mode without it)
  --email ADDR           ACME account email (optional)
  --version VERSION      Release version (default: latest)
  --base-url URL         Release base URL
  --manifest FILE        Use a local signed manifest (audited/offline install)
  --artifact FILE        Use a local artifact instead of downloading it
  --pubkey FILE          Ed25519 release public key (PEM)
  --insecure-skip-signature
                         Development only: skip manifest signature verification
  --dry-run              Verify and print the plan; do not change the host
  --yes, -y              Non-interactive
  -h, --help             Show this help

Environment:
  DOCTBASE_RELEASE_URL, DOCTBASE_VERSION, DOCTBASE_RELEASE_PUBKEY_FILE
EOF
}

log() {
    printf '[doctbase-install] %s\n' "$*" >&2
}

die() {
    printf '[doctbase-install] ERROR: %s\n' "$*" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --base-url) BASE_URL="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --artifact) ARTIFACT="$2"; shift 2 ;;
        --pubkey) PUBKEY="$2"; shift 2 ;;
        --insecure-skip-signature) INSECURE=1; shift ;;
        --dry-run) DRY_RUN="--dry-run"; shift ;;
        --yes|-y) YES="--yes"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

if [ -z "$DRY_RUN" ] && [ "$(id -u)" -ne 0 ]; then
    die "must run as root (or use --dry-run)"
fi

case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/doctbase-bootstrap.XXXXXX")
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fetch() {
    url=$1
    output=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url"
    else
        die "curl or wget is required"
    fi
}

verify_signature() {
    manifest=$1
    signature_b64=$2
    if [ "$INSECURE" = "1" ]; then
        log "WARNING: manifest signature verification skipped (development only)"
        return 0
    fi
    [ -n "$PUBKEY" ] || die "release public key missing; pass --pubkey or set DOCTBASE_RELEASE_PUBKEY_FILE"
    [ -f "$PUBKEY" ] || die "public key not found: $PUBKEY"
    command -v openssl >/dev/null 2>&1 || die "openssl is required for signature verification"

    openssl base64 -d -A -in "$signature_b64" -out "$WORK/manifest.sig" 2>/dev/null \
        || die "manifest signature is not valid base64"
    openssl pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin \
        -in "$manifest" -sigfile "$WORK/manifest.sig" >/dev/null 2>&1 \
        || die "manifest signature verification failed"
}

if [ -n "$MANIFEST" ]; then
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
    manifest_path=$MANIFEST
    if [ "$INSECURE" != "1" ]; then
        sig_path="${MANIFEST}.sig"
        [ -f "$sig_path" ] || die "manifest signature not found: $sig_path"
        verify_signature "$manifest_path" "$sig_path"
    else
        verify_signature "$manifest_path" /dev/null
    fi
else
    manifest_url="${BASE_URL%/}/${VERSION}/manifest.json"
    log "downloading $manifest_url"
    fetch "$manifest_url" "$WORK/manifest.json"
    fetch "${manifest_url}.sig" "$WORK/manifest.json.sig"
    verify_signature "$WORK/manifest.json" "$WORK/manifest.json.sig"
    manifest_path="$WORK/manifest.json"
fi

# The release manifest is generated as an array of flat objects. Split objects,
# then read name/sha256 for the matching target without requiring jq/python.
compact=$(tr -d '\r\n' < "$manifest_path")
artifact_json=$(printf '%s' "$compact" | sed 's/},{/}\n{/g' \
    | grep "\"target\"[[:space:]]*:[[:space:]]*\"linux-${ARCH}\"" | head -n 1)
[ -n "$artifact_json" ] || die "no artifact for linux-${ARCH} in the manifest"

artifact_name=$(printf '%s' "$artifact_json" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
artifact_sha=$(printf '%s' "$artifact_json" | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$artifact_name" ] || die "artifact name missing from manifest"
[ -n "$artifact_sha" ] || die "artifact checksum missing from manifest"

if [ -n "$ARTIFACT" ]; then
    [ -f "$ARTIFACT" ] || die "artifact not found: $ARTIFACT"
    artifact_path=$ARTIFACT
else
    artifact_path="$WORK/$artifact_name"
    artifact_url="${BASE_URL%/}/${VERSION}/${artifact_name}"
    log "downloading $artifact_url"
    fetch "$artifact_url" "$artifact_path"
fi

if command -v sha256sum >/dev/null 2>&1; then
    actual_sha=$(sha256sum "$artifact_path" | awk '{print $1}')
else
    actual_sha=$(openssl dgst -sha256 -r "$artifact_path" | awk '{print $1}')
fi
[ "$actual_sha" = "$artifact_sha" ] || die "artifact checksum mismatch (expected $artifact_sha, got $actual_sha)"

mkdir -p "$WORK/bundle"
tar -xzf "$artifact_path" -C "$WORK/bundle"
BUNDLE="$WORK/bundle"

if [ ! -x "$BUNDLE/bin/doctbase" ]; then
    # Accept archives whose top-level directory is the versioned bundle.
    nested=$(find "$BUNDLE" -maxdepth 3 -type f -name doctbase -perm -u+x | head -n 1)
    [ -n "$nested" ] || die "bundle does not contain bin/doctbase"
    BUNDLE=$(dirname "$(dirname "$nested")")
fi
[ -d "$BUNDLE/share" ] || die "bundle does not contain share/ templates"

log "verified $artifact_name for linux-${ARCH}"


set -- install --assets "$BUNDLE/share" --bin-dir "$BUNDLE/bin"
[ -n "$DOMAIN" ] && set -- "$@" --domain "$DOMAIN"
[ -n "$EMAIL" ] && set -- "$@" --email "$EMAIL"
[ -n "$YES" ] && set -- "$@" --yes

if [ -n "$DRY_RUN" ]; then
    log "would install CLI to /usr/local/lib/doctbase/current/bin/doctbase"
    log "would run: doctbase $*"
    "$BUNDLE/bin/doctbase" "$@" --dry-run
    exit 0
fi

# Install the CLI before running the service installer so `doctbase` is usable
# afterwards. Service binaries are copied by `doctbase install`.
install -d -m 0755 /usr/local/lib/doctbase/current/bin
install -m 0755 "$BUNDLE/bin/doctbase" /usr/local/lib/doctbase/current/bin/doctbase
ln -sf /usr/local/lib/doctbase/current/bin/doctbase /usr/local/bin/doctbase

log "running doctbase install"
/usr/local/bin/doctbase "$@"

log "Doctbase installed; check: sudo doctbase status"
