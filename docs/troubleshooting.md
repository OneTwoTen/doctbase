# Troubleshooting

## Development runtime

- Check `/healthz` for process liveness and `/readyz` for readiness.
- `doctbase dev` writes service sockets under `/tmp/doctbase-dev` by default.
- The internal `/internal/v1/info` endpoint requires the bearer token passed to
  `doctbase dev --token`.
- Review [Runtime and Service Manager](runtime-service-manager.md) for the
  current CLI and service lifecycle behavior.

## Coolify deployment

See [Coolify deployment](coolify.md) for compose profiles, health checks, and
common proxy or database configuration issues.

For a management-domain 404, verify that the domain targets `management` on
port 8081 at `/`, then redeploy an image built from the dashboard-serving
commit. A missing API route under `/api/v1` should remain a JSON 404; if it
returns dashboard HTML, roll back and inspect the management route boundary.

Native installation diagnostics will be added when the installer and `doctor`
commands are implemented.

## Preflight

The preflight policy blocks unsupported operating systems or architectures,
hosts below 2 GiB RAM or 20 GiB free disk, and conflicts on ports 80 or 443.
An unresolved optional domain is reported as a warning so local installation
can continue. On Linux, the collector reads `/etc/os-release`, `/proc/meminfo`,
and `/proc/net/tcp*`, checks the filesystem containing the data path with `df`
(using the nearest existing parent when the path is new), and optionally checks
the domain with `getent`. Collection failures are reported as blockers
with the unavailable probe named; the preflight does not change host state.
These findings will be exposed by the install command when its orchestration
task is implemented.
