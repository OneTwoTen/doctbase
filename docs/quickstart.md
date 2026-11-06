# Quickstart

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
