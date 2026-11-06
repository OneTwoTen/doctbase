# Core Runtime + Service Manager

**Feature**: `001-doctbase-install-config`  
**Trạng thái**: Core Runtime + Service Manager Slice 3 đã implement (runtime, dev/status/restart/logs, `DevDriver`, `SystemdDriver`, `ComposeDriver`, health probe, `ServiceRuntimeAggregator`). Management HTTP endpoints (`/api/v1/services`), config render pipeline và control DB là các bước tiếp theo.

## 1. Thành phần

| Thành phần | Vai trò | Trạng thái |
|------------|---------|------------|
| `packages/runtime` | Shared service harness: bootstrap, config hash, UDS/TCP server, health/ready/info/metrics, internal auth, signal handling, graceful shutdown | Slice 1 |
| `packages/config` | TOML subset parser, schema/defaults, resolved config hash | Slice 1 |
| `packages/core` | Error code registry + HTTP status + docs URL | Slice 1 |
| `packages/service-protocol` | Readiness/info/problem response types | Slice 1 |
| `packages/service-lifecycle` | `LifecycleDriver`, registry, systemd/Compose/dev/fake drivers, health probe | Slice 3: registry + fake + dev + systemd + compose + probe |
| `apps/cli` | `doctbase dev/status/restart/logs` dùng lifecycle driver (native & Compose) | Slice 3 |
| `apps/management/src/services` | ServiceRuntime aggregator, cache, probe, restart operation | Slice 3: aggregator + operation lock + cache |

## 2. Chạy thử gateway

Yêu cầu: Zig `0.17.1` (xem `.zigversion`).

```bash
zig build
DOCTBASE_RUN_DIR=/tmp/doctbase-dev \
DOCTBASE_INTERNAL_TOKEN=dev-secret \
  ./zig-out/bin/doctbase-gateway
```

Hoặc chạy nhiều service bằng dev runner:

```bash
./zig-out/bin/doctbase dev \
  --run-dir /tmp/doctbase-dev \
  --bin-dir zig-out/bin \
  --token dev-secret
```

`doctbase dev` mặc định chạy `gateway` + `auth`, in bảng trạng thái, và dừng sạch bằng `Ctrl-C`/SIGTERM.

Service Manager qua systemd:

```bash
doctbase status
doctbase restart auth
```

Trên macOS không có systemd, dùng `--systemctl <path-to-fake-script>` để test.

Terminal khác:

```bash
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/healthz
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/readyz
curl --unix-socket /tmp/doctbase-dev/gateway.sock \
  -H 'Authorization: Bearer dev-secret' \
  http://localhost/internal/v1/info
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/metrics
```

Dừng bằng `SIGTERM`/`SIGINT`; runtime drain, đóng server và gỡ socket.

## 3. Cấu hình

Runtime đọc TOML tại `DOCTBASE_CONFIG` hoặc `/etc/doctbase/doctbase.toml`. Nếu file không tồn tại và `allow_missing_config = true`, runtime dùng default (dev mode). Trong Docker/Coolify mode, file này do `deploy/docker/entrypoint.sh` sinh từ biến môi trường.

Listener mặc định là Unix domain socket. Đặt `DOCTBASE_LISTEN=host:port` (IPv4) để chuyển sang TCP — dùng cho Docker/Coolify, nơi mỗi service là một container riêng:

```bash
DOCTBASE_MODE=docker \
DOCTBASE_LISTEN=0.0.0.0:8080 \
DOCTBASE_INTERNAL_TOKEN=dev-secret \
./zig-out/bin/doctbase-gateway
```

Ví dụ:

```toml
schema_version = 1

[instance]
name = "demo"
domain = "example.com"

[logging]
level = "debug"
format = "text"
```

`config_hash` trong `/readyz` và `/internal/v1/info` là SHA-256 của resolved config.

## 4. Endpoint hiện có

| Endpoint | Auth | Mục đích |
|----------|------|----------|
| `GET /healthz` | Không | Liveness; 200 nếu process sống |
| `GET /readyz` | Không | Readiness; 200 ready/degraded, 503 not_ready |
| `GET /metrics` | Không | Prometheus text |
| `GET /internal/v1/info` | Bearer token (hoặc dev mode) | Build/config/uptime info |
| Khác | — | RFC 9457 problem+json 404 |

## 5. Test

```bash
zig build test
```

Bao gồm:

- TOML parser + schema/defaults + config hash.
- Error registry + protocol serialization.
- Runtime UDS integration: health/ready/info, auth, SIGTERM cleanup.
- Runtime TCP integration (`tests/integration/runtime_tcp_test.zig`): health/ready/info qua TCP, UDS vẫn là default, graceful shutdown.
- Security: UDS mode `0660`, live socket không bị ghi đè, native mode từ chối internal request thiếu token; TCP mode từ chối token thiếu/sai (`tests/security/runtime_tcp_security_test.zig`).
- Service lifecycle: registry, `FakeDriver`, health probe, `DevDriver` start/stop/restart với gateway + auth thật.
- `SystemdDriver`: parse `systemctl show`, state mapping, restart policy, fake `systemctl` test.

## 6. Tiếp theo

1. Expose `/api/v1/services` và `/api/v1/services/{name}/restart` trên Management HTTP server.
2. Log redaction và output JSON/watch cho `doctbase logs`.
3. Hoàn thiện config render pipeline (`doctbase config render/diff/explain`).
4. Control DB schema & PostgreSQL connection pool (`packages/postgres`).
5. `sd_notify` + credential-file loading cho production.

Chi tiết quyết định: [research.md §14–§16](../specs/001-doctbase-install-config/research.md#14-core-runtime--shared-service-harness).
