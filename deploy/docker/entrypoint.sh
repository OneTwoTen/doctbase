#!/bin/sh
# Generates /etc/doctbase/doctbase.toml from environment variables so container
# platforms (Coolify, plain Compose) only need to manage env vars.
#
# The file is a generated artifact: set DOCTBASE_CONFIG_MANAGED=0 to mount and
# keep your own configuration instead.
set -eu

config_path="${DOCTBASE_CONFIG:-/etc/doctbase/doctbase.toml}"
managed="${DOCTBASE_CONFIG_MANAGED:-1}"

if [ "$managed" = "1" ]; then
    mkdir -p "$(dirname "$config_path")"
    tmp="${config_path}.tmp"
    umask 077
    cat > "$tmp" <<EOF
schema_version = 1

[instance]
name = "${DOCTBASE_INSTANCE_NAME:-doctbase}"
domain = "${DOCTBASE_DOMAIN:-}"
admin_email = "${DOCTBASE_ADMIN_EMAIL:-}"

[database]
mode = "${DOCTBASE_DATABASE_MODE:-external}"

[pooler]
enabled = ${DOCTBASE_POOLER_ENABLED:-false}

[proxy]
mode = "${DOCTBASE_PROXY_MODE:-external}"
tls = "off"

[services]
auth = ${DOCTBASE_SERVICE_AUTH:-true}
storage = ${DOCTBASE_SERVICE_STORAGE:-true}
pg_meta = ${DOCTBASE_SERVICE_PG_META:-true}
rest = ${DOCTBASE_SERVICE_REST:-false}
realtime = ${DOCTBASE_SERVICE_REALTIME:-false}
image_proxy = ${DOCTBASE_SERVICE_IMAGE_PROXY:-false}

[logging]
level = "${DOCTBASE_LOG_LEVEL:-info}"
format = "json"
EOF
    mv "$tmp" "$config_path"
fi

exec "$@"
