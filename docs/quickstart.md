# Quickstart

## Cài native

Luồng cài production native (Debian 13 / Ubuntu 24.04/26.04) đã có
`doctbase install`. Xem [Install](install.md) để biết điều kiện, `--dry-run`,
cách chạy, rollback và giới hạn của slice hiện tại.

```sh
sudo doctbase install --domain example.com --email admin@example.com --dry-run
sudo doctbase install --domain example.com --email admin@example.com --yes
```

## Current development workflow

The production native installer is still under implementation. To build and
run the services locally, install the Zig version in `.zigversion` and follow
[Development](development.md).

```sh
zig build
./zig-out/bin/doctbase dev --run-dir /tmp/doctbase-dev --bin-dir zig-out/bin --token dev-secret
```

In another terminal, check the gateway over its Unix socket:

```sh
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/healthz
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/readyz
```

The native one-command installation flow will replace this development-only
quickstart when its end-to-end install task is complete.
