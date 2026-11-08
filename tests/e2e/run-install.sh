#!/bin/sh
# Compatibility entrypoint for the original E2E scaffold.
# The real fresh-install check lives in install-ubuntu.sh; the multi-cell runner
# is matrix-install.sh.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec sh "$SCRIPT_DIR/install-ubuntu.sh" "$@"
