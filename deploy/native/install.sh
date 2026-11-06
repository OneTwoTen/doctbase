#!/bin/sh
set -eu

case "${1:-}" in
	-h|--help)
		cat <<'EOF'
Doctbase native bootstrap installer

The native bootstrap flow is not implemented yet. This placeholder does not
install packages, change system configuration, or write files.
EOF
		exit 0
		;;
esac

printf '%s\n' 'Native installation is not available in this build.' >&2
printf '%s\n' 'See docs/development.md for the supported development workflow.' >&2
exit 78
