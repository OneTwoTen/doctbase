# Phase 0 Research: Doctbase V1 Foundation — Cài đặt, cấu hình và vận hành dễ dàng

**Feature**: `001-doctbase-install-config`  
**Date**: 2026-11-06  
**Full research**: [docs/nghien-cuu-cai-dat-cau-hinh.md](../../docs/nghien-cuu-cai-dat-cau-hinh.md)

Tài liệu này ghi lại các quyết định kỹ thuật đã chốt cho feature, lý do và các phương án đã cân nhắc. Nghiên cứu đầy đủ — số liệu so sánh, luồng cài đặt, mẫu cấu hình, test matrix, nguồn tham khảo — nằm trong tài liệu nghiên cứu ở trên.

## 1. Deployment model

**Decision**: Native-first với systemd; Docker Compose là optional mode. Không viết supervisor production mới trong V1.

**Rationale**:
- Native phù hợp VPS 2 vCPU/2 GB, không phụ thuộc Docker, tối ưu tài nguyên.
- systemd cung cấp restart, logs, credentials, cgroups, hardening, target/ordering — những thứ đã được kiểm chứng.
- Docker Compose là chuẩn cho portability; profile xử lý optional service.
- Viết supervisor riêng sẽ phải làm lại restart/backoff/logging/signal/cgroups, tăng rủi ro và vi phạm tinh thần “không viết lại hạ tầng”.

**Alternatives considered**:
- **Custom supervisor**: đồng nhất native/Docker nhưng quá nhiều rủi ro cho V1.
- **Một container chứa tất cả**: đơn giản nhưng mất cô lập service, khó scale/update.
- **Kubernetes**: quá nặng cho mục tiêu single-VPS.

## 2. CLI và UX

**Decision**: Một CLI Zig (`doctbase`) làm installer, config manager, lifecycle adapter, doctor, backup/restore, upgrade và project manager.

Command surface chính:

```text
doctbase install | init | dev | up | down | restart
doctbase status | logs | apply | doctor
doctbase config validate|show|diff|render|explain|migrate
doctbase project create|list|show|delete|rotate-key|export|import
doctbase domain add|remove|status
doctbase secret ls|rotate|show
doctbase backup | restore | upgrade | support | uninstall
```

**Rationale**:
- Người dùng chỉ cần nhớ một công cụ.
- Cùng một logic cài đặt/kiểm tra được dùng bởi CLI, dashboard và CI.
- Output human-readable mặc định, `--json` cho automation; exit code ổn định.

**Alternatives considered**:
- Shell scripts rời: khó test, khó idempotent, khó cross-platform.
- Dashboard-first: không phù hợp bootstrap/headless VPS.
- Nhiều CLI riêng cho từng service: tăng cognitive load.

## 3. Configuration model

**Decision**: Một file TOML cho instance tại `/etc/doctbase/doctbase.toml`; project state trong control database; secrets trong file/systemd credentials; generated artifacts không sửa tay.

4 lớp:
1. Instance config — người dùng sửa.
2. Control-plane state — project, key hash, domain, audit.
3. Secrets — sinh tự động, tách khỏi config.
4. Generated artifacts — Caddyfile, `pgbouncer.ini`, `projects.json`, systemd units.

**Rationale**:
- TOML dễ đọc, có comment, schema rõ, không lỗi indentation như YAML.
- Project là dữ liệu động; lưu DB tránh file lock và cho phép CLI/API/dashboard cùng thao tác.
- Generated artifacts đảm bảo một nguồn sự thật, tránh drift.
- `config validate/show/diff/render/explain` giúp người dùng hiểu và kiểm tra trước khi apply.

**Alternatives considered**:
- **YAML**: phổ biến nhưng parser Zig kém trưởng thành, lỗi indentation khó chẩn đoán.
- **JSON**: không comment/trailing comma, kém thân thiện.
- **Tất cả trong một file TOML**: đơn giản ban đầu nhưng khó xử lý project động/concurrent.
- **Tất cả trong DB**: khó version control, khó bootstrap, không minh bạch.

## 4. Internal networking and protocol

**Decision**: HTTP/1.1 + JSON trên Unix domain socket ở native; TCP private network ở Docker; WebSocket cho realtime; dùng `http.zig` (httpz).

**Rationale**:
- UDS loại bỏ port nội bộ, xung đột port và giảm bề mặt tấn công.
- HTTP/JSON dễ debug bằng curl, ít dependency hơn gRPC.
- httpz hỗ trợ Zig 0.17, UDS, multipart, WebSocket; hiệu năng tốt hơn `std.http.Server`.
- Caddy xử lý TLS/ACME; gateway Zig xử lý routing/CORS/rate limit/auth pre-validation.

**Alternatives considered**:
- **gRPC**: mạnh nhưng thêm codegen/tooling, không cần streaming ngoài WebSocket.
- **Message bus (NATS/Redis)**: thêm service, cấu hình, failure mode; V1 single-node dùng `LISTEN/NOTIFY`.
- **TCP loopback cho mọi service**: đơn giản nhưng mở port nội bộ và dễ xung đột.

## 5. Multi-project isolation

**Decision**: Database-per-project trong một PostgreSQL cluster; role riêng; signing key riêng; storage prefix riêng.

**Rationale**:
- Ranh giới bảo mật rõ, không có query cross-project ngoài ý muốn.
- Backup/restore/drop project độc lập.
- PgBouncer có entry/pool riêng cho từng project.
- Dễ giải thích và kiểm thử.

**Alternatives considered**:
- **Schema-per-project**: ít connection hơn nhưng cô lập yếu hơn, backup/drop khó hơn.
- **Shared schema + project_id + RLS**: tiết kiệm tài nguyên nhưng phụ thuộc hoàn toàn vào RLS, khó bảo vệ tuyệt đối.
- **Database-per-tenant**: tương tự database-per-project; V1 chọn mỗi project một DB.

## 6. PostgreSQL and PgBouncer

**Decision**: PostgreSQL 18 cluster riêng; PgBouncer transaction pooling; native chỉ Unix socket; per-project `[databases]` entry; `auth_query` với function trong template database.

**Rationale**:
- Cluster riêng không đụng PostgreSQL 5432 sẵn có, dễ uninstall/backup.
- Không nghe TCP giảm bề mặt tấn công.
- Transaction pooling phù hợp API/REST; `SET LOCAL` an toàn trong transaction.
- `auth_query` hỗ trợ role động; function trong template đảm bảo mọi project DB đều có.
- Entry riêng cho phép giới hạn pool/connection theo project.

**Caveats**:
- `LISTEN/NOTIFY` không an toàn qua transaction pooling → realtime kết nối trực tiếp PostgreSQL.
- `pg_dump`/restore và DDL dài nên dùng direct connection.
- Prepared statements cần `max_prepared_statements`.

**Alternatives considered**:
- **Session pooling**: an toàn hơn cho session features nhưng tốn connection.
- **Wildcard `*` database**: đơn giản nhưng khó giới hạn pool theo project.
- **PgBouncer TCP localhost**: dễ hơn nhưng mở thêm port và kém an toàn hơn UDS.

## 7. Caddy and TLS

**Decision**: Caddy 2.x làm edge; automatic HTTPS; admin API qua Unix socket native, TCP nội bộ Docker; per-host certificate; không wildcard mặc định.

**Rationale**:
- Caddy tự xử lý ACME/renew/redirect, giảm code và lỗi.
- Admin UDS native tránh mở cổng 2019.
- Per-host cert chỉ cần DNS A/AAAA và HTTP-01/TLS-ALPN, không cần DNS provider plugin.
- Reload qua `POST /load` với Caddyfile; lỗi giữ config cũ.

**Alternatives considered**:
- **Nginx/Traefik**: mạnh nhưng cấu hình TLS/reload phức tạp hơn.
- **Tự viết ACME**: vi phạm nguyên tắc không viết lại hạ tầng.
- **Wildcard cert mặc định**: cần DNS-01 + plugin provider; để phase sau.

## 8. Dashboard

**Decision**: SvelteKit + TypeScript + Tailwind + shadcn-svelte, build static và nhúng vào management binary.

**Rationale**:
- Không cần Node runtime/container.
- Cùng origin với Management API → cookie/CSRF đơn giản.
- Bundle nhỏ, build đơn giản, version khớp management.
- SPA fallback đủ cho dashboard nội bộ.

**Alternatives considered**:
- **Next.js**: SSR không cần thiết, thêm runtime/build complexity.
- **React SPA**: khả thi; SvelteKit nhỏ hơn, phù hợp dashboard.
- **Server-rendered Zig templates**: ít JS nhưng DX/component ecosystem kém.

**Management auth — quyết định chốt**:

- Phiên admin dùng cookie `doctbase_session`: `HttpOnly; Secure; SameSite=Lax; Path=/`, TTL mặc định 24h. Token là opaque 256-bit; store chỉ giữ SHA-256 hash (`admin_sessions.token_hash`), không giữ plaintext.
- CSRF dùng double-submit: cookie `doctbase_csrf` (JavaScript đọc được) + header `X-CSRF-Token`. Server giữ `csrf_secret_hash` và so sánh constant-time. Mọi method không an toàn (POST/PUT/PATCH/DELETE) xác thực bằng cookie MUST có CSRF hợp lệ; Bearer internal token dành cho CLI/service được miễn vì không phải ambient credential.
- Dashboard dùng `credentials: same-origin`, không lưu session token/JWT trong `localStorage`/`sessionStorage`.
- Login trả cùng một lỗi `INVALID_CREDENTIALS` cho email không tồn tại và sai mật khẩu; rate limit/IP allowlist cho login vẫn thuộc FR-027 (T134/T162).
- Session/CSRF secret chỉ trả một lần khi login; CSRF được mirror qua cookie để SPA khôi phục sau reload.

**Alternatives considered**:
- **JWT trong `localStorage`**: dễ bị XSS đánh cắp; loại bỏ.
- **Bearer token cho dashboard**: không có ambient credential nên không cần CSRF, nhưng buộc JS giữ token; loại bỏ.
- **Chỉ cookie session không CSRF**: SameSite=Lax giảm rủi ro nhưng không đủ cho state-changing request; loại bỏ.

## 9. Secrets and key ownership

**Decision**: Secrets sinh tự động; native dùng systemd credentials; Docker dùng Compose secrets. JWT private keys do auth service sở hữu tại `/var/lib/doctbase/auth/keys`; management chỉ nhận public key/JWKS.

**Rationale**:
- Không có secret trong TOML/log/env.
- Management không cần đọc private key của project.
- Auth service là issuer duy nhất, giảm khả năng lộ key qua service khác.
- Rotation có thể thực hiện qua auth internal API.

**Alternatives considered**:
- **Secrets trong TOML**: đơn giản nhưng nguy hiểm, dễ commit nhầm.
- **Tất cả secret trong environment**: dễ lộ qua process list/log.
- **Management giữ toàn bộ key**: tăng quyền và rủi ro.

## 10. Install packaging

**Decision**: Native installer dùng PGDG cho PostgreSQL 18, repo chính thức cho PgBouncer/Caddy; tạo cluster/unit riêng; không dùng unit mặc định của distro; Docker dùng image pin digest.

**Rationale**:
- Version PostgreSQL thống nhất, có security update.
- Cluster/unit riêng tránh xung đột với dịch vụ sẵn có.
- Docker image pin digest đảm bảo reproducible.

**Alternatives considered**:
- **Bundle PostgreSQL binary**: khó cập nhật bảo mật, nặng.
- **Dùng cluster mặc định 5432**: dễ xung đột, khó uninstall.
- **Chỉ hỗ trợ Docker**: trái native-first.

## 11. Backup, restore, upgrade

**Decision**: Backup logic gồm control DB, project DBs, storage, auth keys, config, generated files, manifest/checksum; restore cùng version; upgrade có backup, migration lock, health check, rollback.

**Rationale**:
- Đủ để dựng lại instance trên VPS mới.
- Manifest/checksum phát hiện backup hỏng.
- Rollback symlink + restore DB là con đường an toàn nhất trên single VPS.
- Không hứa zero-downtime; Caddy có thể trả 503 trong maintenance.

**Alternatives considered**:
- **Chỉ pg_dump**: thiếu storage/keys/config.
- **Chỉ snapshot VPS**: không portable, không kiểm soát consistency.
- **PITR/WAL ngay V1**: tốt nhưng phức tạp; để phase sau.

## 12. Versions and support matrix

**Decision**: Zig 0.17.1; PostgreSQL 18.x; Caddy 2.x; Debian 13 / Ubuntu 24.04 & 26.04 LTS; x86_64/arm64; Docker optional.

**Rationale**:
- Zig 0.17.1 là stable tại thời điểm nghiên cứu; httpz hỗ trợ 0.17.
- PostgreSQL 18 là bản current; PgBouncer hỗ trợ các tính năng cần thiết.
- Giới hạn matrix giúp test sâu và giảm lỗi “hỗ trợ nửa vời”.

**Alternatives considered**:
- **Zig dev/nightly**: không ổn định cho release.
- **Nhiều distro/RHEL ngay V1**: tăng test matrix quá mức.
- **PostgreSQL 15/16**: ổn định nhưng thiếu một số tracking/optimization mới; có thể cân nhắc nếu PGDG 18 gặp vấn đề.

## 13. Resolved clarifications

| Question | Decision |
|----------|----------|
| Native hay Docker là mặc định? | Native |
| Có viết supervisor riêng? | Không; systemd/Compose |
| Cấu hình một file hay nhiều file? | Một file instance TOML; project state trong DB |
| Multi-project cô lập thế nào? | Database-per-project |
| Internal protocol? | HTTP/JSON UDS native, TCP private Docker; WebSocket realtime |
| Dashboard runtime? | Static SvelteKit embedded |
| Domain có bắt buộc? | Không; local mode nếu thiếu |
| Có wildcard TLS mặc định? | Không; per-host cert |
| Có Redis/NATS? | Không trong V1 |
| Có billing/plans? | Không |
| Core Runtime là process riêng hay shared library? | Shared library compile vào từng service executable |
| Service Manager có phải supervisor? | Không; adapter systemd/Compose, systemd/Compose là source of truth |
| Nguồn sự thật trạng thái service? | systemd/Compose; `ServiceRuntime` chỉ là view/cache |
| Restart infra service? | Status-only mặc định; CLI explicit + confirmation |
| Gọi systemd thế nào? | `systemctl` argv + polkit allowlist; D-Bus dự phòng |
| Health probe transport? | HTTP/1.1 qua UDS/TCP nội bộ; `std.http.Client.connectUnix` có trong Zig 0.17.1, vẫn test integration và có fallback client tối giản |
| Có persist `ServiceRuntime` vào control DB? | Không; cache in-memory + `Operation`/`AuditEvent` |

## 14. Core Runtime — shared service harness

**Decision**: `packages/runtime` là library Zig được compile vào từng service executable. Runtime sở hữu các process concern dùng chung; service sở hữu business logic. Không có process runtime trung tâm đứng ra host service.

**Interface dự kiến** (chốt chi tiết khi implement):

```zig
pub const Service = struct {
    key: ServiceKey,
    init: *const fn (*Context) anyerror!void,
    deinit: *const fn (*Context) void,
    registerRoutes: *const fn (*Router) anyerror!void,
    readiness: *const fn (*Context, *std.ArrayList(ReadinessCheck)) anyerror!void,
};

pub const Runtime = struct {
    pub fn init(allocator: std.mem.Allocator, options: Options) !Runtime;
    pub fn run(self: *Runtime) !void;
    pub fn requestShutdown(self: *Runtime) void;
};
```

**Trình tự bootstrap**:

1. Parse CLI args và xác định config path (`--config` > `DOCTBASE_CONFIG` > default).
2. Load TOML + env override; resolve default; validate semantic; tính SHA-256 của resolved config (config hash).
3. Khởi tạo allocator, structured logger, metrics registry.
4. Load secret từ `$CREDENTIALS_DIRECTORY` (native) hoặc `/run/secrets` (Docker); kiểm tra owner/mode trước khi dùng.
5. Tạo listener: UDS `0660 group doctbase` ở native, TCP private network ở Docker. Chỉ xóa stale socket sau khi xác nhận không có process sống.
6. Dựng router theo thứ tự middleware: request ID → access log → panic recovery → body limit → internal auth → service routes.
7. Đăng ký endpoint chung: `/healthz`, `/readyz`, `/metrics`, `/internal/v1/info`.
8. Init dependency của service (DB pool, cache, upstream client) và đăng ký readiness check.
9. Chỉ chuyển sang ready khi tất cả check bắt buộc đạt; gửi `READY=1` qua `sd_notify` nếu có `NOTIFY_SOCKET`.
10. Chờ `SIGTERM`/`SIGINT`; drain request, đóng pool, gỡ UDS, gửi `STOPPING=1`, thoát.

**Health semantics**:

- `/healthz`: 200 nếu process còn sống; không kiểm tra dependency.
- `/readyz`: 200 cho `ready`/`degraded`, 503 cho `not_ready`; mỗi check có timeout riêng (mặc định 1s), không trả secret/DSN.
- `/internal/v1/info`: service key, build version/commit, mode (`native`/`docker`), uptime, config hash, started_at.
- `/metrics`: Prometheus; metric chung gồm build info, request count/duration, readiness gauge, dependency check duration.

**Internal auth**:

- Native: kiểm tra peer credentials (`SO_PEERCRED`) + bearer internal token; so sánh constant-time.
- Docker: bearer internal token bắt buộc; chỉ tin identity header khi request đến từ private network.
- Gateway strip toàn bộ `X-Doctbase-*` từ request bên ngoài.
- `X-Request-Id` hợp lệ được giữ nguyên; nếu thiếu, runtime sinh ULID.

**Graceful shutdown**:

- Ngừng accept connection ngay khi nhận signal.
- Drain request đang chạy tối đa 10s (cấu hình được); quá hạn thì đóng connection.
- Đóng DB pool/upstream client, gỡ UDS, ghi log `shutdown_complete`.
- systemd unit đặt `TimeoutStopSec` lớn hơn drain deadline.

**Lỗi và panic**:

- Panic trong handler được recovery, trả `application/problem+json` với code `INTERNAL`, không lộ stack cho caller.
- Stack trace chỉ ghi ở mức debug và đã redact.
- Mọi lỗi khởi động trả exit code theo registry `packages/core/src/errors.zig` và có `cause`/`fix`/`docs_url`.

**Tests bắt buộc**:

- Unit: config hash ổn định, readiness aggregation, middleware order, internal auth, shutdown state machine.
- Integration: chạy runtime với UDS tạm, gọi health/ready/info, gửi SIGTERM, xác nhận socket bị gỡ và process thoát sạch.
- Security: mode/owner UDS, peer credential, internal token, header strip, không lộ secret trong log.

**Alternatives considered**:

- **Process runtime trung tâm host nhiều service**: vi phạm Principle II (service independence) và tạo single point of failure; loại bỏ.
- **Để framework sở hữu `main`**: khó cho service tự chọn dependency/route; mỗi service vẫn phải có executable riêng; loại bỏ.
- **Dùng `std.http.Server` thay httpz**: thiếu WebSocket/UDS tooling và hiệu năng thấp hơn; loại bỏ.
- **Tự viết toàn bộ HTTP server**: tăng bề mặt lỗi không cần thiết; loại bỏ.

## 15. Service Manager — control-plane lifecycle adapter

**Decision**: `packages/service-lifecycle` cung cấp `LifecycleDriver`; `apps/management/src/services/` cung cấp aggregator, cache và API. systemd (native) và Docker Compose (Docker) là **source of truth** cho trạng thái process. Không viết supervisor production mới.

**Service registry** — một nguồn sự thật duy nhất cho CLI, management và render:

```zig
pub const ServiceSpec = struct {
    key: ServiceKey,                 // gateway, management, auth, ...
    display_name: []const u8,
    kind: enum { app, infra },
    unit_name: ?[]const u8,          // doctbase-auth.service
    compose_service: ?[]const u8,    // auth
    socket_path: ?[]const u8,        // /run/doctbase/auth.sock
    optional: bool,
    depends_on: []const ServiceKey,
    health_path: []const u8,         // /readyz
    health_timeout_ms: u32,
    allowed_actions: ActionSet,      // status, logs, start, stop, restart, enable, disable
};
```

- Registry là dữ liệu tĩnh trong code/config package, không phải bảng control DB.
- Tên unit/compose service lấy từ registry; không nhận tên tùy ý từ user input.

**Driver interface**:

```zig
pub const LifecycleDriver = struct {
    list: *const fn (*Driver, std.mem.Allocator) anyerror![]ServiceState,
    get: *const fn (*Driver, ServiceKey) anyerror!ServiceState,
    start: *const fn (*Driver, ServiceKey) anyerror!OperationResult,
    stop: *const fn (*Driver, ServiceKey) anyerror!OperationResult,
    restart: *const fn (*Driver, ServiceKey) anyerror!OperationResult,
    enable: *const fn (*Driver, ServiceKey, bool) anyerror!void,
    logs: *const fn (*Driver, ServiceKey, LogQuery) anyerror!LogStream,
};
```

**SystemdDriver**:

- Gọi `systemctl` bằng argv, không qua shell; allowlist `doctbase-*` và `doctbase.target`.
- Đọc trạng thái bằng `systemctl show -p ActiveState,SubState,Result,UnitFileState,ExecMainStartTimestamp,MainPID --no-pager`.
- Restart đồng bộ với timeout; không dùng `--no-block` để còn xác nhận kết quả.
- Logs qua `journalctl -u <unit> --no-pager -o json`; redact trước khi trả.
- Polkit rule chỉ cho user `doctbase-management` thao tác unit `doctbase-*`.
- D-Bus trực tiếp là phương án dự phòng khi parse `systemctl` không ổn định; V1 ưu tiên subprocess để tránh link `libsystemd`.

**ComposeDriver**:

- Gọi `docker compose -f <file> --project-name doctbase` bằng argv; allowlist service name.
- `ps --format json` để lấy state/health; `logs --no-color --tail` để đọc log.
- Dashboard Docker mặc định chỉ đọc trạng thái; thao tác trực tiếp chỉ khi opt-in socket proxy.
- Không mở Docker socket cho management nếu user không bật rõ ràng.

**DevDriver**:

- Chạy child process foreground, giữ process group, forward signal, prefix log theo service.
- Chỉ dùng cho `doctbase dev`; không dùng production.
- Có `FakeDriver` cho unit test và test không cần systemd.

**Aggregator** (`apps/management/src/services/runtime.zig`):

- `list()`: lấy state từ driver + probe `/readyz` qua UDS/TCP với timeout; cache ngắn (mặc định 2s) để tránh bão health check.
- Map trạng thái: `active + ready` → `ready`; `active + not ready` → `degraded`; `activating` → `starting`; `deactivating` → `stopping`; `inactive` → `stopped`; `failed` → `failed`.
- `ServiceRuntime` chỉ là view/cache; không persist vào control DB. Nếu cần audit, ghi `Operation`/`AuditEvent`.
- Restart flow: authz → validate action → per-service operation lock → idempotency key → driver.restart → poll state/ready với backoff (tối đa 15s) → cập nhật `Operation` → audit → trả 202.
- Nếu operation đang chạy: trả 409 kèm operation hiện tại, không restart chồng.
- Infra service (PostgreSQL, PgBouncer, Caddy): mặc định status-only. Restart qua CLI cần confirmation rõ ràng; management API không restart infra trừ khi policy được bật.

**Security**:

- Management restart endpoint yêu cầu admin session + CSRF + rate limit + IP allowlist.
- Chỉ role `owner`/`admin` được restart; `viewer` chỉ đọc.
- Audit mọi thao tác restart/enable/disable với actor, service, operation ID, kết quả.
- Không log command line chứa secret; không trả stderr thô cho public.

**Error codes đề xuất**:

| Code | Khi nào |
|------|---------|
| `SERVICE_NOT_FOUND` | Service key không có trong registry |
| `SERVICE_NOT_RESTARTABLE` | Infra/optional service bị policy chặn |
| `SYSTEMD_UNAVAILABLE` | Không có systemd hoặc không kết nối được |
| `SYSTEMD_PERMISSION_DENIED` | Polkit/từ chối quyền |
| `SYSTEMD_UNIT_NOT_FOUND` | Unit không tồn tại |
| `SERVICE_RESTART_TIMEOUT` | Quá thời gian chờ ready |
| `SERVICE_NOT_READY` | Process lên nhưng readiness fail |
| `SERVICE_OPERATION_IN_PROGRESS` | Đang có operation khác |
| `COMPOSE_UNAVAILABLE` | Docker/Compose không có |
| `COMPOSE_SOCKET_DENIED` | Không có quyền socket |
| `HEALTH_PROBE_TIMEOUT` | Probe UDS/TCP quá hạn |
| `HEALTH_PROBE_PROTOCOL` | Response health không hợp lệ |

**Alternatives considered**:

- **D-Bus/systemd API trực tiếp**: ổn định hơn nhưng thêm dependency `libsystemd`/static-link phức tạp; để sau.
- **Docker Engine API**: linh hoạt nhưng phải mở socket, tăng rủi ro bảo mật; V1 dùng CLI.
- **Custom supervisor**: vi phạm Technical Constraints; loại bỏ.
- **Lưu ServiceRuntime trong PostgreSQL làm source of truth**: dễ stale và tạo hai nguồn sự thật; loại bỏ.

## 16. Runtime & Service Manager acceptance và rollout

**Rollout slices**:

1. **Slice 1 — Core Runtime**: `packages/runtime`, hello service qua UDS, health/ready/info/metrics, graceful shutdown, signal handling.
2. **Slice 2 — Lifecycle abstraction**: registry, `LifecycleDriver`, `FakeDriver`, `DevDriver`, health probe; `doctbase dev` chạy 2 service.
3. **Slice 3 — Systemd + Management**: `SystemdDriver`, polkit, aggregator, `/services`, restart, audit, CLI `status/restart/logs`.
4. **Slice 4 — Compose + hardening**: `ComposeDriver`, Docker status, security tests, E2E matrix.

**Gate**:

- `doctbase dev` chạy ít nhất 2 service qua UDS; `status` hiển thị đúng; SIGTERM drain sạch.
- `FakeDriver` test pass toàn bộ state mapping, restart timeout, operation lock.
- Trên Linux VM: stop một unit → `status` báo down → restart qua CLI/management → ready trở lại.
- Management restart yêu cầu auth/CSRF/rate limit; viewer bị từ chối; infra bị chặn mặc định.
- Không có supervisor mới; systemd/Compose vẫn là lifecycle owner.
- Không thêm port public, không thêm config bắt buộc, không thêm secret mới.

**Performance targets**:

- Readiness probe p95 ≤ 100ms trên loopback/UDS.
- `status` cho 11 service ≤ 500ms (cache hit ≤ 50ms).
- Restart operation ≤ 15s hoặc trả timeout có mã lỗi rõ ràng.
- Runtime overhead ≤ ~10MB RSS/service (không tính DB pool).

**Rủi ro và giảm thiểu**:

| Risk | Mitigation |
|------|------------|
| `systemctl` output khác version/systemd | Parse key-value ổn định; test trên Ubuntu 24.04/Debian 13; fallback D-Bus |
| Polkit rule quá rộng | Allowlist prefix `doctbase-`; test unit ngoài prefix bị từ chối |
| Health probe treo | Timeout ngắn, circuit cache, không block toàn bộ status |
| Stale UDS socket | Kiểm tra process sống trước khi xóa; log warning |
| Docker socket lộ quyền | Mặc định read-only; opt-in socket proxy; test security |
| Restart chồng nhau | Per-service lock + idempotency key + 409 |
| Cache trạng thái sai | TTL ngắn; `status --refresh` bỏ cache; audit operation |
| `std.http.Client.connectUnix` thay đổi API/hành vi giữa các bản Zig | Đã có trong 0.17.1; test integration sớm; fallback HTTP/1.1 client tối giản trên UDS |

## 17. Sources

Các nguồn chính đã khảo sát (chi tiết và URL đầy đủ trong [docs/nghien-cuu-cai-dat-cau-hinh.md](../../docs/nghien-cuu-cai-dat-cau-hinh.md#12-nguồn-tham-khảo)):

- Supabase self-hosting Docker và compose chính thức.
- Appwrite self-hosting và Appwrite 2.0.
- PocketBase single-binary/FAQ.
- Coolify/Dokploy installation và requirements.
- Caddy automatic HTTPS, admin API, Caddyfile.
- PgBouncer configuration, `auth_query`, pooling modes.
- PostgreSQL 18 RLS.
- systemd credentials.
- Docker Compose profiles.
- Zig 0.17.1 và http.zig.
- RFC 9457, OpenAPI 3.1, OWASP ASVS, Twelve-Factor App.
