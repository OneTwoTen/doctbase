#!/bin/sh
# Signed native bootstrap E2E (no host changes).
#
# Builds a fake release bundle from zig-out/bin, signs the manifest with a
# temporary Ed25519 key, then verifies that deploy/native/install.sh:
#   - accepts a valid manifest/artifact and reaches `doctbase install --dry-run`;
#   - rejects a tampered checksum;
#   - rejects a tampered manifest signature.
#
# Requires: tar, openssl, sha256sum, the built zig-out/bin binaries.
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/doctbase-bootstrap-test.XXXXXX")
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

fail() {
    printf '[bootstrap-e2e] FAIL: %s\n' "$*" >&2
    exit 1
}

[ -x "$REPO_ROOT/zig-out/bin/doctbase" ] || fail "build first: zig build"

case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
esac

mkdir -p "$WORK/bundle/bin" "$WORK/bundle/share"
cp "$REPO_ROOT"/zig-out/bin/* "$WORK/bundle/bin/"
cp -r "$REPO_ROOT/deploy" "$REPO_ROOT/infrastructure" "$WORK/bundle/share/"
tar -czf "$WORK/doctbase-test-linux-$ARCH.tar.gz" -C "$WORK/bundle" .
sha=$(sha256sum "$WORK/doctbase-test-linux-$ARCH.tar.gz" | awk '{print $1}')
cat > "$WORK/manifest.json" <<EOF
{"schema_version":1,"version":"test","artifacts":[{"name":"doctbase-test-linux-$ARCH.tar.gz","target":"linux-$ARCH","sha256":"$sha"}]}
EOF

openssl genpkey -algorithm ED25519 -out "$WORK/key.pem" 2>/dev/null
openssl pkey -in "$WORK/key.pem" -pubout -out "$WORK/pub.pem" 2>/dev/null
openssl pkeyutl -sign -inkey "$WORK/key.pem" -rawin -in "$WORK/manifest.json" -out "$WORK/sig.bin" 2>/dev/null
openssl base64 -A -in "$WORK/sig.bin" -out "$WORK/manifest.json.sig"

run_bootstrap() {
    sh "$REPO_ROOT/deploy/native/install.sh" \
        --manifest "$WORK/manifest.json" \
        --artifact "$WORK/doctbase-test-linux-$ARCH.tar.gz" \
        --pubkey "$WORK/pub.pem" \
        --dry-run
}

run_bootstrap >"$WORK/valid.log" 2>&1 || {
    cat "$WORK/valid.log" >&2
    fail "valid signed manifest was rejected"
}
grep -q "verified doctbase-test-linux-$ARCH.tar.gz" "$WORK/valid.log" \
    || fail "bootstrap did not report a verified artifact"
grep -Eq 'Plan \(|Doctbase .*installed|installed\.' "$WORK/valid.log" || {
    cat "$WORK/valid.log" >&2
    fail "bootstrap did not reach doctbase install --dry-run"
}

# A validly signed manifest with a wrong checksum must fail before extraction.
sed -i.bak 's/"sha256":"[0-9a-f]*"/"sha256":"0000000000000000000000000000000000000000000000000000000000000000"/' "$WORK/manifest.json"
openssl pkeyutl -sign -inkey "$WORK/key.pem" -rawin -in "$WORK/manifest.json" -out "$WORK/sig.bin" 2>/dev/null
openssl base64 -A -in "$WORK/sig.bin" -out "$WORK/manifest.json.sig"
if run_bootstrap >"$WORK/checksum.log" 2>&1; then
    fail "tampered checksum was accepted"
fi
grep -q 'checksum mismatch' "$WORK/checksum.log" || {
    cat "$WORK/checksum.log" >&2
    fail "missing checksum error"
}
mv "$WORK/manifest.json.bak" "$WORK/manifest.json"
openssl pkeyutl -sign -inkey "$WORK/key.pem" -rawin -in "$WORK/manifest.json" -out "$WORK/sig.bin" 2>/dev/null
openssl base64 -A -in "$WORK/sig.bin" -out "$WORK/manifest.json.sig"

# Tampered manifest must fail signature verification.
printf ' ' >> "$WORK/manifest.json"
if run_bootstrap >"$WORK/signature.log" 2>&1; then
    fail "tampered manifest signature was accepted"
fi
grep -q 'signature verification failed' "$WORK/signature.log" || fail "missing signature error"

printf '[bootstrap-e2e] PASS\n'
