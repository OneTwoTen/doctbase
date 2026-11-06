# Contract: Internal Service Protocol

**Feature**: `001-doctbase-install-config`  
**Version**: `internal/v1`  
**Status**: Design contract; implementation must conform.

## 1. Transport

| Mode | Transport | Discovery |
|------|-----------|-----------|
| Native | Unix domain socket (`/run/doctbase/<service>.sock`) | Fixed paths, group `doctbase`, mode `0660` |
| Docker | TCP private network | Compose service DNS (`gateway:8080`, `auth:8080`, ...) |

- HTTP/1.1, JSON UTF-8.
- WebSocket cho realtime; Caddy route trực tiếp tới realtime ở native.
- Không dùng gRPC, message bus, service mesh trong V1.
- Mọi service MUST bind UDS/TCP nội bộ; không bind public interface (trừ Caddy).

## 2. Common endpoints

Mọi service Zig MUST cung cấp:

| Endpoint | Method | Mục đích |
|----------|--------|----------|
| `/healthz` | GET | Liveness; 200 nếu process còn sống |
| `/readyz` | GET | Readiness; 200 nếu dependencies sẵn sàng, 503 nếu chưa |
| `/metrics` | GET | Prometheus text format |
| `/internal/v1/info` | GET | Build version, commit, config hash, uptime |

Response `/readyz`:

```json
{
  "status": "ready",
  "checks": [
    {"name": "postgres", "status": "ok"},
    {"name": "config", "status": "ok"}
  ],
  "version": "1.0.0",
  "config_hash": "sha256:..."
}
```

- `status`: `ready` | `degraded` | `not_ready`.
- HTTP 200 cho ready/degraded; 503 cho not_ready.
- Không trả secret/DSN/password.

## 3. Headers

### Request headers

| Header | Producer | Ý nghĩa |
|--------|----------|---------|
| `X-Request-Id` | Caddy/gateway/CLI | Correlation ID; propagate |
| `X-Doctbase-Project` | Gateway | Project slug/id sau khi resolve |
| `X-Doctbase-User` | Gateway | User id sau auth |
| `X-Doctbase-Role` | Gateway | `anon`/`authenticated`/`service` |
| `Authorization: Bearer <internal_token>` | Caller | Internal auth |
| `X-Doctbase-Config-Hash` | Caller (optional) | Detect config drift |

### Rules

- Gateway MUST strip mọi header `X-Doctbase-*` từ request bên ngoài.
- Service nội bộ MUST chỉ tin identity headers khi request đến từ UDS/private network + internal token.
- Không dùng identity headers cho public request nếu chưa qua gateway.
- `X-Request-Id` MUST được giữ nguyên nếu hợp lệ; nếu thiếu, service tự sinh ULID.

## 4. Error contract

Dùng RFC 9457 `application/problem+json`:

```json
{
  "type": "https://doctbase.dev/errors/DB_CONN_REFUSED",
  "title": "Database connection refused",
  "status": 503,
  "detail": "Cannot connect to PostgreSQL through /run/doctbase/pgbouncer.sock",
  "instance": "/internal/v1/info",
  "code": "DB_CONN_REFUSED",
  "request_id": "01J...",
  "docs_url": "https://doctbase.dev/errors/DB_CONN_REFUSED"
}
```

- `code` stable, UPPER_SNAKE_CASE.
- `status` HTTP status.
- Không trả stack trace, SQL, secret, hostname nội bộ chi tiết cho public; internal có thể log chi tiết.
- Public API dùng cùng format; gateway map lỗi nội bộ thành 502/503 phù hợp.

## 5. Timeouts, retries, limits

| Setting | Default | Ghi chú |
|---------|---------|---------|
| Gateway request timeout | 30s | Upload có timeout riêng |
| Upload timeout | 10m | Streaming |
| Internal request timeout | 5s | Health/auth/metadata |
| Realtime ping interval | 30s | Server ping |
| Realtime idle timeout | 90s | Đóng connection |
| Max request body | 1 MB (JSON) | Upload đi qua storage route |
| Max upload | 50 MB default | Cấu hình theo project |
| Retry | Idempotent only | Exponential backoff + jitter |
| Circuit breaker | Không V1 | Dashboard hiển thị health |

- Gateway MUST trả 503 + `Retry-After` khi upstream not ready.
- Service MUST graceful shutdown: ngừng nhận request, hoàn tất request đang chạy, đóng DB pool, xóa UDS.

## 6. Service-specific internal endpoints

### 6.1. Auth

| Endpoint | Method | Mục đích |
|----------|--------|----------|
| `/internal/v1/projects/{project_id}/keys` | POST | Tạo signing key; trả public key/JWKS |
| `/internal/v1/projects/{project_id}/keys/{key_id}/rotate` | POST | Rotate signing key |
| `/internal/v1/projects/{project_id}/keys/{key_id}` | DELETE | Retire/delete key |
| `/internal/v1/verify` | POST | Verify JWT/API key (cache-friendly) |
| `/.well-known/jwks.json` | GET | Public JWKS (qua gateway/Caddy) |

- Private key chỉ auth service đọc/ghi.
- Management gọi endpoint tạo key; không đọc private key.
- Auth service MUST chịu trách nhiệm publish JWKS trong `projects.json`.

### 6.2. Realtime

| Endpoint | Method | Mục đích |
|----------|--------|----------|
| `/internal/v1/broadcast` | POST | Broadcast message tới channel/project |
| `/internal/v1/presence` | GET | Snapshot presence (debug) |
| `/realtime/v1/websocket` | GET (Upgrade) | Public WebSocket |

- Realtime kết nối trực tiếp PostgreSQL cho `LISTEN/NOTIFY`.
- Private channel yêu cầu JWT; kiểm tra project + role + origin.
- Backpressure: drop slow clients; ping/pong; max message size.

### 6.3. PG Meta

| Endpoint | Method | Mục đích |
|----------|--------|----------|
| `/internal/v1/projects/{project_id}/schema` | GET | Introspect schema |
| `/internal/v1/projects/{project_id}/query` | POST | Query có allowlist (admin only) |
| `/internal/v1/projects/{project_id}/ddl` | POST | DDL có validate (admin only) |

- Kết nối direct PostgreSQL (không qua transaction pool).
- Mọi identifier phải quote/validate; không nhận raw SQL từ public user.
- Audit mọi DDL.

### 6.4. Storage

| Endpoint | Method | Mục đích |
|----------|--------|----------|
| `/internal/v1/projects/{project_id}/objects` | POST/GET | Metadata/upload |
| `/internal/v1/projects/{project_id}/signed-url` | POST | Tạo signed URL |
| `/internal/v1/projects/{project_id}/usage` | GET | Dung lượng |

- Không fetch URL tùy ý (SSRF); chỉ đọc object trong bucket/project.
- Path traversal/MIME sniffing/range request phải được test.

### 6.5. Gateway

| Endpoint | Method | Mục đích |
|----------|--------|----------|
| `/internal/v1/projects` | GET | Snapshot project registry (nếu không đọc file) |
| `/internal/v1/reload` | POST | Reload `projects.json` |
| `/healthz`, `/readyz` | GET | Health |

- Gateway đọc `projects.json` generated; reload qua SIGHUP/internal endpoint.
- Gateway resolve project theo Host; fallback path `/_p/<slug>` cho dev.

## 7. Versioning

- Internal path prefix `/internal/v1`.
- Breaking change → `/internal/v2`; service config biết version qua contract package.
- Thêm field JSON là non-breaking; client MUST ignore unknown fields.
- `service-protocol` package định nghĩa struct/version; mọi service dùng chung.

## 8. Security checklist

- [ ] UDS mode `0660`, group `doctbase`; không world-readable.
- [ ] Internal token bắt buộc; so sánh constant-time.
- [ ] Gateway strip `X-Doctbase-*` từ ngoài.
- [ ] Không log `Authorization`, cookie, API key, JWT, password.
- [ ] Request body/header limits; timeout; slowloris protection.
- [ ] WebSocket origin + JWT validation; max connections/message size.
- [ ] SQL identifier quoting/allowlist; không raw SQL public.
- [ ] SSRF: image proxy/storage không fetch URL tùy ý.
- [ ] Graceful shutdown + connection draining.

## 9. Runtime bootstrap contract

Mọi service Zig dùng `packages/runtime` MUST tuân thủ trình tự và semantics sau:

### 9.1. Bootstrap order

```text
parse args/config path
  → load + validate config
  → compute config hash (SHA-256 canonical resolved config)
  → init allocator, logger, metrics
  → load secrets from credentials directory
  → create listener (UDS native / private TCP Docker)
  → register middleware + common endpoints
  → init service dependencies
  → mark ready; send sd_notify READY=1 (if NOTIFY_SOCKET)
  → serve until SIGTERM/SIGINT
  → drain, deinit, remove UDS, send STOPPING=1
```

- Không nhận traffic trước khi service init xong.
- Nếu init fail, process MUST exit non-zero với error code trong registry; không để socket rác.
- Stale UDS chỉ được xóa sau khi xác nhận không có process sống.

### 9.2. Readiness

- `/healthz` chỉ phản ánh process sống; MUST NOT phụ thuộc DB/upstream.
- `/readyz` MUST aggregate check của service; mỗi check có timeout (mặc định 1s).
- `status=ready|degraded` → HTTP 200; `not_ready` → 503.
- Response MUST có `version`, `config_hash`, `checks`; MUST NOT chứa DSN/password/token.

### 9.3. Info

`GET /internal/v1/info` trả tối thiểu:

```json
{
  "service": "auth",
  "version": "1.0.0",
  "commit": "abc1234",
  "mode": "native",
  "uptime_seconds": 42,
  "config_hash": "sha256:...",
  "started_at": "2026-11-06T10:00:00Z"
}
```

### 9.4. Internal auth và peer credentials

- Native: kiểm tra `SO_PEERCRED` (uid/gid) + bearer internal token; so sánh constant-time.
- Docker: bearer internal token bắt buộc; chỉ tin identity header từ private network.
- Gateway MUST strip `X-Doctbase-*` từ request bên ngoài.
- `X-Request-Id` được propagate; nếu thiếu, runtime sinh ULID.

### 9.5. Graceful shutdown

- Signal `SIGTERM`/`SIGINT`: ngừng accept, drain request tối đa 10s (cấu hình được), đóng pool, gỡ UDS.
- systemd `TimeoutStopSec` MUST lớn hơn drain deadline.
- Log `shutdown_started`/`shutdown_complete` với `request_id` và lý do.

### 9.6. Lifecycle ownership

- Runtime không tự restart process; systemd/Compose là lifecycle owner.
- Service Manager chỉ gọi driver để start/stop/restart; không tự supervise/backoff/cgroups.
- `DevDriver` chỉ dùng cho `doctbase dev`; không dùng production.
