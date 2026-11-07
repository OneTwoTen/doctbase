# Native service units

Systemd unit templates installed by the native installer. Files in this
directory are generated or installed by Doctbase and must not require manual
edits on the target host.

Current templates:

- `doctbase-app.service.tmpl` — generic application-service unit rendered once
  per registry entry (gateway, management, auth, storage, pg-meta, rest,
  realtime, image-proxy). Non-root, `ProtectSystem=strict`, internal token via
  `LoadCredential=`, socket path from the service registry (T048).
- `doctbase.target.tmpl` — aggregates infrastructure units plus enabled core
  application units; optional services are enabled individually (T048).
- `doctbase-pgbouncer.service.tmpl` — transaction-pooling PgBouncer over the
  `/run/doctbase` Unix socket (T046).
- `doctbase-caddy.service.tmpl` — Caddy edge on 80/443 with a Unix-socket admin
  API and no root privileges (T047).

The lifecycle allowlist lives in `deploy/native/polkit/50-doctbase.rules`.
