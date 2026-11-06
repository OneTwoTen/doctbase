# Implementation Plan: Doctbase V1 Foundation — Cài đặt, cấu hình và vận hành dễ dàng

**Branch**: `001-doctbase-install-config` | **Date**: 2026-11-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-doctbase-install-config/spec.md`

## Summary

Xây dựng lớp Foundation của Doctbase V1 để một quản trị viên có thể cài trên VPS trống, cấu hình bằng một file, tạo project đầu tiên và vận hành hệ thống mà không cần hiểu chi tiết microservices bên dưới.

Cách tiếp cận kỹ thuật:

- Một CLI Zig (`doctbase`) làm installer, config manager, lifecycle adapter, doctor, backup/restore, upgrade và project manager.
- `packages/runtime` là shared service harness compile vào từng service executable: bootstrap, config hash, HTTP/UDS server, health/ready/metrics, internal auth, signal handling và graceful shutdown.
- `packages/service-lifecycle` + `apps/management/src/services` là Service Manager: adapter điều phối systemd/Compose, registry service, health probe, cache trạng thái, restart operation và audit. systemd/Compose vẫn là lifecycle owner; không viết supervisor mới.
- Native-first với systemd; Docker Compose là optional mode. Không viết supervisor production mới.
- PostgreSQL 18 cluster riêng, PgBouncer transaction pooling; native dùng Unix domain socket, Docker dùng private TCP network.
- Một file cấu hình TOML cho instance; project state nằm trong control database; secrets tách riêng; Caddyfile, PgBouncer config, project snapshot và systemd units là generated artifacts.
- Multi-project dùng database-per-project, role riêng và signing key riêng.
- Dashboard SvelteKit static nhúng vào management binary.
- Mọi thay đổi đi qua pipeline render → validate → atomic write → reload/restart → health check → rollback.

Tài liệu nghiên cứu đầy đủ: [docs/nghien-cuu-cai-dat-cau-hinh.md](../../docs/nghien-cuu-cai-dat-cau-hinh.md). Bản rút gọn quyết định kỹ thuật: [research.md](./research.md).

## Scope Boundary

Feature này chỉ triển khai **lớp Foundation**:

- Cài đặt, cấu hình, lifecycle, project provisioning, backup/restore/upgrade, dashboard khung.
- Service skeleton + health/ready/metrics + route/toggle cho 8 app service.
- Contract tối thiểu để auth/storage/pg-meta/REST/realtime/image-proxy có thể được triển khai đầy đủ ở feature sau.

**Không thuộc feature này**: full auth flows (signup/login/OAuth/MFA), storage API đầy đủ, PG Meta DDL đầy đủ, REST auto API, realtime WebSocket, image proxy transformations. Các phần đó là feature follow-on riêng, dùng cùng project provisioning và contract đã định nghĩa.

## Technical Context

**Language/Version**: Zig `0.17.1` (pinned; xem `.zigversion` khi implement), TypeScript/SvelteKit cho dashboard, POSIX shell cho bootstrap installer.

**Primary Dependencies**: `http.zig` (httpz) pin commit tương thích Zig 0.17.1 (httpz readme hiện target 0.17.0; 0.17.1 là patch — phải test compatibility khi implement), `pg.zig` hoặc PostgreSQL wire client tương đương, TOML parser (evaluate `zig-toml`, fallback subset parser trong `packages/config`), `libvips` optional cho image proxy, systemd (systemctl/journalctl + polkit), Docker Compose v2, PostgreSQL 18.x, PgBouncer, Caddy 2.x.

**Runtime architecture**: `packages/runtime` là shared library, không phải process riêng. `packages/service-lifecycle` định nghĩa `LifecycleDriver`; `SystemdDriver` gọi `systemctl`/`journalctl` bằng argv, `ComposeDriver` gọi `docker compose`, `DevDriver` chạy child process foreground, `FakeDriver` dùng cho test. `apps/management/src/services/runtime.zig` aggregate trạng thái + health probe + restart operation. `ServiceRuntime` chỉ là view/cache; systemd/Compose là source of truth.

**Storage**: PostgreSQL 18 cluster riêng cho control plane + project databases; local filesystem cho storage/cache; S3 optional cho storage; backup local, offsite qua `rclone`/`restic`. `ServiceRuntime` không persist vào control DB; `Operation`/`AuditEvent` lưu lịch sử thao tác.

**Testing**: `zig build test`, unit tests cho config/render/security/runtime/lifecycle, integration tests với PostgreSQL + PgBouncer + Caddy trong Docker Compose, E2E install trên VM Debian/Ubuntu, fault-injection, security tests (cross-project, JWT/API key, path traversal, SSRF), restore/upgrade drills. Runtime có test UDS + graceful shutdown; lifecycle có test fake/systemd/Compose driver và restart security.

**Target Platform**: Debian 13, Ubuntu 24.04/26.04 LTS trên x86_64/arm64; macOS/Linux dev; Docker optional; không hỗ trợ Windows native hoặc HA multi-node trong V1.

**Project Type**: Monorepo microservices + CLI + web dashboard + native/Docker deployment artifacts.

**Performance Goals**:
- Fresh install đến healthy: ≤ 5 phút (p95) trên 2 vCPU/2 GB.
- Từ install xong đến API request đầu tiên: ≤ 60 giây.
- Tạo project: ≤ 10 giây trên VPS tham chiếu.
- Idle footprint: ≤ ~700 MB RAM native (gồm PostgreSQL) với profile mặc định.
- Gateway overhead: mục tiêu p95 ≤ 5 ms trên loopback/UDS; đo và ghi baseline, không phải SLA thương mại.
- Runtime readiness probe: p95 ≤ 100 ms trên loopback/UDS.
- `status` cho 11 service: ≤ 500 ms (cache hit ≤ 50 ms).
- Restart operation: ≤ 15 giây hoặc timeout có mã lỗi rõ ràng.
- Restore 10 GB: ≤ 30 phút; upgrade N-1: downtime ≤ 3 phút.

**Constraints**:
- Một instance mỗi VPS; ≤ ~100 project/instance trong V1.
- Không mở port nội bộ ngoài 80/443; PostgreSQL/PgBouncer không nghe public TCP ở native.
- Không thêm Redis/NATS/message bus/service mesh/Kubernetes.
- Không viết custom production supervisor; Service Manager chỉ điều phối systemd/Compose.
- Management mặc định không restart infra service (PostgreSQL/PgBouncer/Caddy); infra chỉ status, restart qua CLI với xác nhận.
- Không persist `ServiceRuntime` vào control DB; chỉ cache in-memory + operation/audit.
- Không billing/plans.
- Không yêu cầu domain hoặc email TLS để cài đặt thành công.
- Không tự ý sửa firewall/SSH/DNS hoặc xóa dịch vụ sẵn có.

**Scale/Scope**: 9 nhóm service theo kiến trúc; 8 app service Zig + management dashboard; 3 thành phần hạ tầng (PostgreSQL, PgBouncer, Caddy); 1 CLI; 1 file cấu hình instance; N project database; 1 service registry dùng chung cho CLI/management/render.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Gate | Kết quả |
|-----------|------|---------|
| I. Zig-First, PostgreSQL-Native | Service/CLI dùng Zig; PostgreSQL native; không thay bằng SQLite/abstraction | **PASS** |
| II. Service Independence, Shared Contracts | Mỗi service executable/health/config riêng; contract trong `packages/service-protocol` | **PASS** |
| III. Single-VPS First, Native-First | Native 2 vCPU/2 GB là golden path; Docker optional; không Kubernetes/Redis/NATS | **PASS** |
| IV. Installability & Configurability | Một lệnh cài, một file cấu hình, một lệnh/project; acceptance ≤ 5 phút/≤ 60 giây; generated artifacts; idempotent/dry-run | **PASS** — gate chi tiết ở Phase 2 và tasks |
| V. Security by Default | Secrets sinh tự động; UDS/private network; DB không public; RLS default-deny; admin tách data plane | **PASS** |
| VI. Observability, Backup, Recoverability | status/logs/doctor/support bundle; backup/restore; upgrade rollback | **PASS** |
| VII. Test-First & Contract Discipline | Unit/integration/E2E/security/restore tests; OpenAPI + service protocol | **PASS** |
| Technical Constraints | Zig 0.17.1, PostgreSQL 18, Caddy 2, TOML, systemd/Compose, không billing | **PASS** |
| Process lifecycle constraint | systemd/Compose là lifecycle owner; Service Manager chỉ là control-plane adapter, không supervisor | **PASS** — không cần amendment |

**Post-Design re-check**: Không có violation. Core Runtime là shared library compile vào từng executable; Service Manager không tự supervise process, không thêm port/config/service bắt buộc. Các quyết định trong plan không cần Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/001-doctbase-install-config/
├── spec.md                  # Feature specification
├── plan.md                  # This file
├── research.md              # Phase 0 decisions and alternatives
├── data-model.md            # Phase 1 entities, relationships, state transitions
├── quickstart.md            # Phase 1 runnable validation guide
├── contracts/
│   ├── cli.md               # CLI commands, output, exit codes
│   ├── config.md            # TOML schema contract and precedence
│   ├── management-api.yaml  # OpenAPI 3.1 management surface
│   └── service-protocol.md  # Internal health/error/header contract
├── checklists/
│   └── requirements.md      # Specification quality checklist
└── tasks.md                 # Phase 2 output ($speckit-tasks)
```

### Source Code (repository root)

```text
apps/
├── cli/                     # doctbase CLI: install, config, project, backup, upgrade, doctor
├── gateway/                 # application edge: routing, CORS, rate limit, auth pre-validation
├── management/              # Management API + dashboard assets + service runtime aggregator
├── auth/                    # authentication, JWT/JWKS, sessions, API keys
├── rest/                    # optional auto REST API
├── realtime/                # optional WebSocket + LISTEN/NOTIFY + presence
├── storage/                 # buckets, upload/download, signed URLs
├── image-proxy/             # optional resize/crop/cache (libvips)
└── pg-meta/                 # schema/table/index/role/policy management

packages/
├── core/                    # shared domain types, IDs, time, errors
├── runtime/                 # shared service harness: bootstrap, server, health, shutdown, sd_notify
├── http/                    # httpz wrapper, router, middleware, UDS/TCP listener, UDS client
├── postgres/                # connection, transactions, migrations, RLS helpers
├── config/                  # TOML parsing, schema, defaults, validation, render
├── security/                # secrets, Argon2id, JWT, API keys, signed URLs
├── telemetry/               # structured logging, metrics, request IDs, redaction
├── service-protocol/        # health, error envelope, internal headers, versioning
├── service-lifecycle/       # driver interface, registry, systemd/compose/dev/fake
├── migrations/              # embedded SQL for control/project DBs
└── imaging/                 # libvips FFI (optional)

dashboard/                   # SvelteKit source; static build embedded into management
infrastructure/
├── postgres/                # tuning, template DB, bootstrap SQL
├── pgbouncer/               # config templates, auth_query SQL
└── caddy/                   # Caddyfile templates and reload helpers

deploy/
├── native/
│   ├── install.sh           # thin signed bootstrap
│   ├── units/               # systemd units/target
│   └── polkit/              # narrow lifecycle rule
└── docker/
    ├── compose.yml          # generated/maintained compose file
    └── pgbouncer/Dockerfile

docs/
├── nghien-cuu-cai-dat-cau-hinh.md
├── quickstart.md
├── config-reference.md
├── upgrade.md
├── backup-restore.md
├── troubleshooting.md
└── adr/

tests/
├── unit/
├── integration/
├── e2e/
├── security/
├── fixtures/
└── restore/

tools/
├── release.zig              # packaging, manifest
└── manifest.zig             # checksums/signatures

build.zig
build.zig.zon
.zigversion
```

**Structure Decision**: Monorepo Zig theo kiến trúc đã chốt; thêm `apps/cli` cho installer/CLI, `packages/runtime` cho shared service harness và `packages/service-lifecycle` cho adapter systemd/Compose/dev. Dashboard là static build, không phải service runtime. `deploy/native` và `deploy/docker` chứa artifact triển khai; `infrastructure/` chứa template cấu hình hạ tầng.

## Phase 0 — Research (đã hoàn tất)

Các quyết định chính đã được nghiên cứu và ghi tại [research.md](./research.md), dựa trên tài liệu đầy đủ tại [docs/nghien-cuu-cai-dat-cau-hinh.md](../../docs/nghien-cuu-cai-dat-cau-hinh.md):

1. Native-first, systemd; Docker Compose optional; không custom supervisor.
2. Một CLI + một file TOML; project state trong control DB; generated artifacts.
3. HTTP/JSON trên UDS native, private TCP Docker; httpz.
4. Database-per-project; PgBouncer entry riêng + `auth_query`.
5. Caddy auto TLS; admin qua UDS native, TCP nội bộ Docker.
6. SvelteKit static embedded.
7. Secrets qua systemd credentials/Compose secrets; JWT private keys do auth service sở hữu.
8. Backup/restore/upgrade có manifest, checksum, rollback.
9. Core Runtime là shared library compile vào từng service executable; bootstrap/health/metrics/internal auth/graceful shutdown dùng chung.
10. Service Manager là control-plane adapter trên systemd/Compose; registry + driver + health probe + cache + restart operation; không supervisor.
11. `ServiceRuntime` là view/cache in-memory; systemd/Compose là source of truth; infra mặc định status-only.

**Không còn NEEDS CLARIFICATION.**

## Phase 1 — Design & Contracts

### Data model

Xem [data-model.md](./data-model.md). Các entity chính: Instance, AdminUser, Project, ProjectService, Domain, ApiKey, SigningKey, SecretMetadata, Backup, AuditEvent, Operation, ServiceRuntime.

### Runtime & Service Manager design

- `packages/runtime` — interface `Service`/`Runtime`, bootstrap sequence, config hash, health semantics, internal auth, graceful shutdown, sd_notify. Chi tiết tại [research.md](./research.md) §14.
- `packages/service-lifecycle` — `ServiceSpec` registry, `LifecycleDriver`, `SystemdDriver`, `ComposeDriver`, `DevDriver`, `FakeDriver`, health probe. Chi tiết tại [research.md](./research.md) §15.
- `apps/management/src/services/` — aggregator, state mapping, cache, per-service operation lock, restart policy, audit. Chi tiết tại [research.md](./research.md) §15–§16.
- Không thêm process runtime trung tâm, không persist trạng thái service vào control DB, không thêm port/config/service bắt buộc.

### Contracts

- [contracts/cli.md](./contracts/cli.md) — command surface, JSON output, exit codes.
- [contracts/config.md](./contracts/config.md) — TOML schema, defaults, precedence, generated artifacts.
- [contracts/management-api.yaml](./contracts/management-api.yaml) — OpenAPI 3.1 cho Management API.
- [contracts/service-protocol.md](./contracts/service-protocol.md) — health/ready/metrics/error/header nội bộ + runtime bootstrap.

### Quickstart

Xem [quickstart.md](./quickstart.md) — kịch bản validate end-to-end trên VM sạch, Docker mode, project đầu tiên, status/doctor, backup/restore, dev runtime/service manager.

## Implementation Phases

### Phase A — Core Runtime, Service Manager và CLI skeleton

- `packages/config`: TOML schema, defaults, validation, `show/diff/render/explain`.
- `packages/runtime`: bootstrap, config load + hash, httpz UDS/TCP server, health/ready/info/metrics, internal auth, signal handling, graceful shutdown, optional sd_notify.
- `packages/service-protocol`, `packages/http`, `packages/telemetry`.
- `packages/service-lifecycle`: `ServiceSpec` registry, `LifecycleDriver`, `FakeDriver`, `DevDriver`.
- `apps/cli` skeleton: `install/init/dev/status/logs/doctor/config`.
- Error code registry, JSON output, exit codes, redaction.
- Build/release skeleton, `.zigversion`, signed manifest.

**Exit gate**: `doctbase init` tạo config; `doctbase config validate/show/render` chạy; `doctbase dev` chạy ít nhất 2 service qua UDS; SIGTERM drain sạch; runtime/lifecycle unit tests pass; không có supervisor mới.

### Phase B — Native installer và hạ tầng

- Preflight, package install, user/group/dirs, secrets, state file, lock.
- PostgreSQL 18 cluster riêng + template DB + tuning.
- PgBouncer UDS + auth_query + per-project entries.
- Caddy unit + Caddyfile render + UDS admin reload.
- systemd units/target (`Type=notify` + runtime `sd_notify`, fallback `Type=exec`; `TimeoutStopSec` > drain deadline), polkit rule, journald logs.
- `status`, `logs`, `doctor` bản đầu; backup/restore local; uninstall.

**Exit gate**: fresh Ubuntu 24.04 2 GB cài ≤ 5 phút; idempotent; không đụng PostgreSQL 5432; uninstall sạch.

### Phase C — Management, project provisioning và dashboard

- Control DB schema/migrations; management API.
- Render pipeline `doctbase apply`; atomic write; rollback.
- Project create/list/show/delete/export/import; database-per-project; roles; signing key qua auth.
- RLS helper + default-deny policy scaffolding trong project template.
- Caddy/PgBouncer/projects.json reload; health check.
- Service Manager: `SystemdDriver`, registry, health probe, state cache, per-service operation lock, restart policy, `/services` API, audit.
- Dashboard shell, setup token, admin session, project/service/logs pages.
- Audit log.

**Exit gate**: tạo project qua CLI/dashboard ≤ 10 giây; URL hoạt động; cross-project bị từ chối; apply invalid không đổi state; stop/restart service qua CLI/management hoạt động trên Linux VM; viewer bị từ chối restart; infra mặc định status-only.

### Follow-on Features (separate specs)

Các feature sau dùng Foundation contract nhưng **không nằm trong plan này**:

- **Auth**: signup/login, JWT/JWKS đầy đủ, sessions, OAuth, MFA.
- **Storage**: bucket policy, signed URL, streaming upload, S3 backend.
- **PG Meta**: introspection/DDL, roles/policies UI.
- **REST**: auto REST API + OpenAPI per project.
- **Realtime**: WebSocket + LISTEN/NOTIFY + presence + broadcast.
- **Image Proxy**: libvips resize/crop/cache.

Mỗi feature có spec/plan/tasks riêng, dùng chung `packages/service-protocol`, `packages/postgres`, `packages/security` và project provisioning của feature 001.

### Phase D — Docker, offline, upgrade/hardening và release

- Docker Compose đầy đủ + profiles + healthcheck + secrets.
- `ComposeDriver` + Docker status/restart (socket proxy opt-in), test trên Docker mode.
- Offline bundle native/Docker.
- Upgrade/rollback + migration backup.
- Security hardening, SBOM, signed release, rate limit, IP allowlist, secret rotation.
- E2E VM matrix, fault injection, restore drill, docs.

**Exit gate**: V1 release checklist pass; install/upgrade/restore targets đạt; security review pass; compose lifecycle/status pass; không có supervisor mới.

## Complexity Tracking

> Không có violation cần justify.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| None | — | — |

## Risks & Mitigations (plan-level)

| Risk | Mitigation |
|------|------------|
| CLI/installer quá phức tạp | Tách phase A/B; test trên VM sạch; `--dry-run`; idempotent state machine |
| TOML parser chưa trưởng thành | Evaluate `zig-toml`; vendor pin; fallback subset parser với test đầy đủ |
| PgBouncer transaction pooling | Direct connection cho realtime/backup/pg-meta; test `SET LOCAL`; prepared statements |
| Multi-project connection exhaustion | Pool limit/project; `max_connections`; monitor; tune theo RAM |
| Caddy/ACME failures | Per-host cert; staging test; doctor DNS/TLS; không wildcard mặc định |
| Docker lifecycle | Dashboard read-only mặc định; CLI qua compose; socket proxy opt-in |
| Systemd/polkit khác version hoặc output không ổn định | Parse key-value; test Ubuntu 24.04/Debian 13; allowlist `doctbase-*`; fallback D-Bus |
| UDS health probe treo/sai protocol | Timeout ngắn; cache; test stale socket; fallback HTTP client tối giản nếu `std.http.Client.connectUnix` lỗi |
| Restart chồng nhau | Per-service operation lock + idempotency key + trả 409 |
| `ServiceRuntime` cache stale | TTL ngắn; `status --refresh`; audit operation; systemd/Compose là source of truth |
| Management restart infra quá rộng | Infra mặc định status-only; CLI explicit confirmation; test security |
| Same-host secrets | systemd credentials; auth owns JWT keys; least-privilege users; log redaction |
| Upgrade migration failure | Backup trước; advisory lock; health check; rollback symlink + restore |
| Scope creep | V1 spec chỉ install/config/lifecycle; auth/storage/REST/realtime là feature sau hoặc phase D/E |

## Definition of Done

- Tất cả FR trong `spec.md` có test/acceptance tương ứng.
- Success Criteria SC-001…SC-020 được đo trên VM tham chiếu.
- Constitution Check pass, không violation.
- Quickstart chạy được từ đầu đến cuối trên Ubuntu 24.04 sạch.
- Backup/restore và upgrade/rollback được diễn tập.
- Không có secret trong log/output mặc định.
- `doctbase doctor` phát hiện các lỗi phổ biến trong fault-injection suite.
- Core Runtime: `doctbase dev` chạy ≥ 2 service qua UDS; health/ready/info/metrics đúng; SIGTERM drain sạch; không rò secret.
- Service Manager: `status` đúng cho app + infra; restart app service qua CLI/management; viewer/infra bị chặn đúng policy; audit đầy đủ; không có supervisor mới.
- Docs: quickstart, config reference, upgrade, backup/restore, troubleshooting, runtime/service-manager validation.
