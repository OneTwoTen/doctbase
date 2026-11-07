---
description: "Task list for Doctbase V1 Foundation — cài đặt, cấu hình và vận hành dễ dàng"
---

# Tasks: Doctbase V1 Foundation — Cài đặt, cấu hình và vận hành dễ dàng

**Input**: Design documents from `specs/001-doctbase-install-config/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: Constitution VII yêu cầu test-first; các task test là bắt buộc cho mỗi user story. Viết test trước, xác nhận fail, rồi implement.

**Organization**: Tasks được nhóm theo user story để có thể implement/test độc lập.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Có thể chạy song song (khác file, không phụ thuộc task chưa xong)
- **[Story]**: User story tương ứng (`US1`…`US5`)
- Mọi task có đường dẫn file cụ thể

## Path Conventions

Monorepo theo [plan.md](./plan.md): `apps/`, `packages/`, `dashboard/`, `infrastructure/`, `deploy/`, `tests/`, `tools/`, `docs/`, `specs/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Khởi tạo monorepo, toolchain và khung test/deploy.

- [x] T001 Create monorepo tree and root build files in `build.zig`, `build.zig.zon`, `.zigversion`, `README.md`
- [x] T002 Pin Zig 0.17.1 and dependencies (httpz; TOML subset in `packages/config`; `pg.zig` để sau) in `build.zig.zon` and `build.zig`
- [x] T003 [P] Configure CI (format, build, unit, integration) in `.github/workflows/ci.yml` — E2E install matrix theo dõi ở T136
- [x] T004 [P] Scaffold SvelteKit dashboard in `dashboard/package.json`, `dashboard/svelte.config.js`, `dashboard/src/routes/+layout.svelte`
- [x] T005 [P] Scaffold deploy artifacts in `deploy/native/install.sh`, `deploy/native/units/`, `deploy/native/polkit/`, `deploy/docker/compose.yml`
- [x] T006 [P] Scaffold docs in `docs/quickstart.md`, `docs/config-reference.md`, `docs/upgrade.md`, `docs/backup-restore.md`, `docs/troubleshooting.md`
- [x] T007 [P] Create test harness skeleton in `tests/unit/`, `tests/integration/harness.zig`, `tests/e2e/run-install.sh`, `tests/security/`, `tests/restore/`
- [x] T008 [P] Configure formatting/lint/editor settings in `.editorconfig`, `build.zig` (`fmt`, `test` steps)
- [x] T009 [P] Create release tooling skeleton in `tools/release.zig`, `tools/manifest.zig`
- [x] T010 [P] Create local dev infrastructure in `deploy/dev/compose.yml` for PostgreSQL, PgBouncer, Caddy

**Historical status note**: The initial Slice 1 update predates the completed Phase 2B work and the Coolify feature. Current progress is tracked by the task checkboxes and the feature-specific documents below.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared contracts, config, HTTP, lifecycle, control DB, CLI and dashboard shell. **Không bắt đầu user story trước khi phase này xong.**

- [x] T011 Create executable skeletons for all services in `apps/*/src/main.zig` and `build.zig` targets
- [x] T012 Implement TOML parser adapter in `packages/config/src/toml.zig`
- [x] T013 Implement config schema, defaults and precedence in `packages/config/src/schema.zig`, `packages/config/src/defaults.zig`
- [x] T014 Implement semantic validation (domain, ports, service deps, sizes) in `packages/config/src/validate.zig`
- [x] T015 Implement `config validate/show/diff/render/explain` in `apps/cli/src/commands/config.zig`
- [x] T016 Implement service protocol types, `ReadinessCheck`, `RuntimeInfo`, health/ready/metrics/error envelope in `packages/service-protocol/src/protocol.zig`, `packages/service-protocol/src/errors.zig`
- [x] T017 Implement httpz wrapper, UDS/TCP listener, router and middleware (request ID, panic recovery, body limit) in `packages/http/src/server.zig`, `packages/http/src/uds.zig`, `packages/http/src/middleware.zig`
- [x] T018 Implement structured JSON logging, request correlation and redaction in `packages/telemetry/src/log.zig`, `packages/telemetry/src/redact.zig`
- [x] T019 Implement Prometheus metrics helpers and common runtime metrics in `packages/telemetry/src/metrics.zig`
- [x] T020 Define `LifecycleDriver` interface, `ServiceSpec` registry and `FakeDriver` in `packages/service-lifecycle/src/driver.zig`, `packages/service-lifecycle/src/registry.zig`, `packages/service-lifecycle/src/fake.zig`
- [x] T021 Implement systemd driver (systemctl argv allowlist, status mapping, start/stop/restart; journalctl logs để slice sau) in `packages/service-lifecycle/src/systemd.zig`
- [x] T022 Implement Docker Compose driver (compose argv, `ps`/`logs`, allowlist) in `packages/service-lifecycle/src/compose.zig`
- [x] T023 Implement foreground `DevDriver` and `doctbase dev` command in `packages/service-lifecycle/src/dev.zig`, `apps/cli/src/main.zig`
- [x] T024 Implement CLI globals (`--config`, `--json`, `--yes`, `--dry-run`), JSON envelope and exit codes in `apps/cli/src/main.zig`, `apps/cli/src/output.zig`
- [x] T025 Implement error code registry and docs URL mapping in `packages/core/src/errors.zig`
- [x] T026 Create control DB schema/migrations for Instance, AdminUser, AdminSession, Project, ProjectService, Domain, ApiKey, SigningKey, SecretMetadata, Backup, AuditEvent, Operation, ServiceRuntime in `packages/migrations/control/001_init.sql`
- [x] T027 Implement PostgreSQL pool, migration runner and RLS helpers in `packages/postgres/src/pool.zig`, `packages/postgres/src/migrate.zig`, `packages/postgres/src/rls.zig`
- [x] T028 Implement secret generation, Argon2id password hashing, ULID IDs and constant-time compare in `packages/security/src/secrets.zig`, `packages/security/src/password.zig`, `packages/security/src/ids.zig`
- [x] T029 Implement render pipeline skeleton (staging, atomic write, diff, rollback) in `packages/config/src/render.zig`, `packages/config/src/apply.zig`
- [x] T030 Implement Management API skeleton and cookie+CSRF session middleware in `apps/management/src/main.zig`, `apps/management/src/api/router.zig`, `apps/management/src/auth/session.zig`, `apps/management/src/auth/users.zig`
- [x] T031 Implement gateway skeleton with project registry loader, host/path routing and upstream proxying in `apps/gateway/src/main.zig`, `apps/gateway/src/project_registry.zig`, `apps/gateway/src/router.zig`
- [x] T032 Implement auth service skeleton and internal key API stub in `apps/auth/src/main.zig`, `apps/auth/src/keys.zig`
- [x] T033 Implement dashboard shell, API client and auth store in `dashboard/src/lib/api.ts`, `dashboard/src/lib/auth.ts`, `dashboard/src/routes/+page.svelte`
- [x] T034 Implement integration harness with real PostgreSQL/PgBouncer/Caddy in `tests/integration/harness.zig`
- [x] T035 Create shared test fixtures (config, project, backup) in `tests/fixtures/config/`, `tests/fixtures/projects/`

**Checkpoint**: Phase 2 packages ready — **chưa bắt đầu user story** cho đến khi Phase 2B hoàn tất.

---

## Phase 2B: Core Runtime & Service Manager (blocking, bổ sung)

**Purpose**: Chi tiết hóa T016–T023 thành shared runtime library và lifecycle adapter dùng chung. Các task T151–T160 được bổ sung sau khi bộ task gốc đã có số; **thứ tự thực hiện theo vị trí phase, không theo số ID**.

**⚠️ CRITICAL**: Phase này phải xong trước US1; không service nào được tự viết lại bootstrap/health/shutdown/lifecycle.

- [x] T151 [P] Implement `Service`/`Runtime` interface, bootstrap order and `sd_notify` in `packages/runtime/src/app.zig`, `packages/runtime/src/bootstrap.zig`, `packages/runtime/src/sd_notify.zig`
- [x] T152 [P] Implement runtime config load, resolved config hash and credential loading in `packages/runtime/src/config.zig`, `packages/runtime/src/secrets.zig`
- [x] T153 [P] Implement runtime server wiring, middleware order, health/ready/info/metrics endpoints in `packages/runtime/src/http.zig`, `packages/runtime/src/endpoints.zig`, `packages/runtime/src/middleware.zig`
- [x] T154 [P] Implement signal handling, graceful shutdown/drain and UDS cleanup in `packages/runtime/src/runtime.zig`
- [x] T155 [P] Implement UDS/TCP health probe client and stale-socket handling in `packages/service-lifecycle/src/health_probe.zig`
- [x] T156 [P] Unit test runtime bootstrap, config hash, readiness aggregation and shutdown in `tests/unit/runtime_bootstrap_test.zig`, `tests/unit/runtime_health_test.zig`, `tests/unit/runtime_shutdown_test.zig`
- [x] T157 [P] Unit test service registry, driver state mapping and `FakeDriver` in `packages/service-lifecycle/src/registry.zig`, `packages/service-lifecycle/src/fake.zig` (inline tests)
- [x] T158 [P] Integration test runtime over temporary UDS, health/ready/info and SIGTERM cleanup in `tests/integration/runtime_uds_test.zig`
- [x] T159 [P] Security test UDS mode/owner, peer credentials, internal token and header strip in `tests/security/runtime_security_test.zig`
- [x] T160 [P] Integration test `doctbase dev` with ≥2 services, prefixed logs and clean SIGTERM in `tests/integration/dev_runner_test.zig`

**Phase 2 & Phase 2B Status (Hoàn thành)**: Toàn bộ packages cốt lõi (telemetry, http, security, service-protocol, runtime, service-lifecycle, config apply/render), tất cả 8 executable skeletons (`doctbase-gateway`, `doctbase-management`, `doctbase-auth`, `doctbase-storage`, `doctbase-pg-meta`, `doctbase-rest`, `doctbase-realtime`, `doctbase-image-proxy`), dashboard shell, test fixtures và toàn bộ test suites đã hoàn tất và vượt qua 100% build & test trên Zig 0.17.1.

**Checkpoint**: Runtime + Service Manager foundation ready — US1 có thể bắt đầu; không có supervisor mới.

**Checkpoint**: Runtime + Service Manager foundation ready — US1 có thể bắt đầu; không có supervisor mới.

---

## Phase 3: User Story 1 — Cài Doctbase trên VPS trống bằng một lệnh (Priority: P1) 🎯

**Goal**: Một lệnh cài đặt native trên VPS sạch, có/không domain, idempotent, không phá hệ thống sẵn có.

**Independent Test**: VM sạch Ubuntu 24.04 2 vCPU/2 GB; chạy `install.sh --domain ... --yes`; dashboard/health OK trong ≤ 5 phút; không sửa file thủ công.

### Tests for User Story 1

- [x] T036 [P] [US1] Unit test preflight (OS, RAM, disk, ports, DNS, existing services) in `tests/unit/preflight_test.zig`
- [x] T037 [P] [US1] Integration test install idempotency (3 lần chạy) in `tests/integration/install_idempotency_test.zig`
- [ ] T038 [P] [US1] E2E test fresh Ubuntu install in `tests/e2e/install-ubuntu.sh`
- [x] T039 [P] [US1] Security test no default secrets, no public DB/admin ports in `tests/security/install_defaults_test.zig`

### Implementation for User Story 1

- [x] T040 [US1] Implement read-only Linux host collection and preflight evaluation (OS, RAM, data disk, TCP listeners, optional DNS) in `apps/cli/src/install/preflight.zig`
- [x] T041 [US1] Define transaction-safe package install plan/executor for PGDG PostgreSQL 18, PgBouncer, Caddy and optional libvips in `apps/cli/src/install/packages.zig`; unit tests in `tests/unit/install_packages_test.zig`
- [x] T042 [US1] Create system users/groups/directories/tmpfiles with documented modes in `apps/cli/src/install/users.zig`, `deploy/native/tmpfiles/doctbase.conf`
- [x] T043 [US1] Implement secret generation and file permissions in `apps/cli/src/install/secrets.zig`
- [x] T044 [US1] Create dedicated PostgreSQL cluster `doctbase` on port 5433, UDS-only, with auto tuning in `apps/cli/src/install/postgres.zig`, `infrastructure/postgres/tuning.conf`
- [x] T045 [US1] Create template database, extensions, schemas and `pgbouncer_auth` function in `infrastructure/postgres/template.sql`
- [x] T046 [US1] Render and install PgBouncer UDS config/unit in `apps/cli/src/install/pgbouncer.zig`, `deploy/native/units/doctbase-pgbouncer.service.tmpl`
- [x] T047 [US1] Render and install Caddy config/unit (UDS admin, auto TLS, per-host sites) in `apps/cli/src/install/caddy.zig`, `deploy/native/units/doctbase-caddy.service.tmpl`
- [x] T048 [US1] Create systemd unit templates/target and polkit allowlist in `deploy/native/units/doctbase-*.service.tmpl`, `deploy/native/polkit/50-doctbase.rules`
- [x] T049 [US1] Implement install orchestration, state file, lock and rollback in `apps/cli/src/install/install.zig`, `apps/cli/src/install/state.zig`
- [ ] T050 [US1] Implement admin bootstrap and one-time setup token in `apps/cli/src/install/bootstrap.zig`, `apps/management/src/api/setup.zig`
- [x] T051 [US1] Implement post-install health verification and rollback in `apps/cli/src/install/health.zig`
- [x] T052 [US1] Implement install summary, log file and support hints in `apps/cli/src/install/summary.zig`
- [ ] T053 [US1] Implement one-line signed bootstrap installer and audited two-step variant in `deploy/native/install.sh`, `tools/manifest.zig`
- [ ] T054 [US1] Implement uninstall `--keep-data`/`--purge` in `apps/cli/src/commands/uninstall.zig`
- [ ] T055 [US1] Implement repair/reinstall without data loss in `apps/cli/src/install/repair.zig`
- [ ] T056 [US1] Implement one-line Docker install and explicit `init --profile docker`/`up` path in `apps/cli/src/commands/docker.zig`, `deploy/docker/compose.yml.tmpl`
- [ ] T057 [US1] Write native/Docker install docs in `docs/quickstart.md`, `docs/install.md`
- [ ] T058 [US1] Run E2E matrix (Ubuntu 24.04, Debian 13, arm64) in `tests/e2e/matrix-install.sh`

**Checkpoint**: US1 hoạt động độc lập; dashboard/health đạt; không cần project.

---

## Phase 4: User Story 2 — Tạo project đầu tiên và gọi API ngay (Priority: P1) 🎯

**Goal**: Một lệnh tạo project, database/role/key/domain/routes tự động, API dùng được ngay, cô lập project.

**Independent Test**: Từ instance US1, `project create myapp --services auth,storage,rest`; nhận URL/key; gọi health/CRUD; project khác bị từ chối truy cập chéo.

### Tests for User Story 2

- [ ] T059 [P] [US2] Integration test project create (DB, role, key, domain, health) in `tests/integration/project_create_test.zig`
- [ ] T060 [P] [US2] Security test cross-project access denied in `tests/security/project_isolation_test.zig`
- [ ] T061 [P] [US2] Test API key one-time display, hash and rotation grace in `tests/unit/api_key_test.zig`
- [ ] T062 [P] [US2] Test project create rollback on failure in `tests/integration/project_rollback_test.zig`

### Implementation for User Story 2

- [ ] T063 [US2] Implement project repository (control DB) in `apps/management/src/projects/repository.zig`
- [ ] T064 [US2] Implement slug/domain validation and reserved-name rules in `apps/management/src/projects/validate.zig`
- [ ] T065 [US2] Implement database/role provisioning from template with per-project roles, RLS helper and default-deny policy scaffolding in `apps/management/src/projects/provision.zig`, `infrastructure/postgres/project_roles.sql`, `infrastructure/postgres/rls_helpers.sql`
- [ ] T066 [US2] Implement auth signing-key create/rotate internal API and minimal JWKS/verify endpoints in `apps/auth/src/keys.zig`, `apps/auth/src/api/internal_keys.zig`
- [ ] T067 [US2] Implement API key generation, prefix/hash storage and one-time reveal in `packages/security/src/apikey.zig`, `apps/management/src/projects/keys.zig`
- [ ] T068 [US2] Render `projects.json` snapshot (hosts, services, JWKS, key hashes) in `apps/management/src/render/projects_json.zig`
- [ ] T069 [US2] Render/reload PgBouncer per-project database entry in `apps/management/src/render/pgbouncer.zig`
- [ ] T070 [US2] Render/reload Caddy site block per project and register gateway host route in `apps/management/src/render/caddy.zig`, `apps/gateway/src/project_registry.zig`
- [ ] T071 [US2] Create default storage bucket/prefix, project storage dirs and storage health route in `apps/management/src/projects/storage.zig`
- [ ] T072 [US2] Implement `project create` CLI and output URL/keys in `apps/cli/src/commands/project.zig`
- [ ] T073 [US2] Implement `project list/show/export/import` in `apps/cli/src/commands/project.zig`
- [ ] T074 [US2] Implement `project delete` and `--purge` with backup/confirmation in `apps/management/src/projects/delete.zig`
- [ ] T075 [US2] Implement Management API project/key/domain endpoints in `apps/management/src/api/projects.zig`, `apps/management/src/api/keys.zig`, `apps/management/src/api/domains.zig`
- [ ] T076 [US2] Emit audit events for project/key/domain changes in `apps/management/src/audit.zig`
- [ ] T077 [US2] Implement dashboard setup and project-create pages in `dashboard/src/routes/setup/+page.svelte`, `dashboard/src/routes/projects/new/+page.svelte`
- [ ] T078 [US2] Implement dashboard project detail/keys/services pages in `dashboard/src/routes/projects/[slug]/+page.svelte`, `dashboard/src/routes/projects/[slug]/keys/+page.svelte`
- [ ] T079 [US2] Implement project health check (auth/storage/REST routes) and rollback in `apps/management/src/projects/health.zig`
- [ ] T080 [US2] Write project lifecycle docs in `docs/projects.md`
- [ ] T081 [US2] Run E2E project create + first API call in `tests/e2e/project-first-api.sh`
- [ ] T082 [US2] Performance test project create ≤ 10s in `tests/integration/project_perf_test.zig`

**Checkpoint**: US1 + US2 = MVP; cài xong tạo project và gọi API.

---

## Phase 5: User Story 3 — Vận hành, chẩn đoán và xem trạng thái (Priority: P2)

**Goal**: `status`, `logs`, `doctor`, drift detection, dashboard service/logs; lỗi có mã/cách sửa.

**Independent Test**: Dừng một service; `status`/`doctor` chỉ rõ; `logs` redact; config drift được phát hiện; `doctor --fix` chỉ sửa an toàn.

### Tests for User Story 3

- [ ] T083 [P] [US3] Contract test `status` human/JSON output in `tests/unit/status_contract_test.zig`
- [ ] T084 [P] [US3] Fault-injection test doctor checks in `tests/integration/doctor_faults_test.zig`
- [ ] T085 [P] [US3] Log redaction test in `tests/security/log_redaction_test.zig`
- [ ] T086 [P] [US3] Config drift detection test in `tests/integration/config_drift_test.zig`
- [x] T161 [P] [US3] Integration test `SystemdDriver` state mapping/restart with fake `systemctl` in `packages/service-lifecycle/src/systemd.zig` (inline test)
- [ ] T162 [P] [US3] Security test restart authz, CSRF, rate limit and polkit allowlist in `tests/security/service_restart_security_test.zig`
- [ ] T163 [P] [US3] E2E test stop/restart/recover service with systemd in `tests/e2e/service-manager.sh`

### Implementation for User Story 3

- [ ] T087 [US3] Implement ServiceRuntime aggregator (registry, driver, health probe, state mapping, 2s cache) in `apps/management/src/services/runtime.zig`, `apps/management/src/services/state.zig`, `apps/management/src/services/probe.zig`
- [ ] T088 [US3] Implement `status` command (human/JSON/watch/refresh) in `apps/cli/src/commands/status.zig`
- [ ] T089 [US3] Implement `logs` command with journald/Compose and redaction in `apps/cli/src/commands/logs.zig`
- [ ] T090 [US3] Implement doctor core checks (OS, RAM, disk, ports, DNS, TLS, DB, PgBouncer, Caddy, services, permissions, backup age) in `apps/cli/src/doctor/checks.zig`
- [ ] T091 [US3] Implement safe `doctor --fix` in `apps/cli/src/doctor/fix.zig`
- [ ] T092 [US3] Implement generated-file checksum/drift detection in `packages/config/src/drift.zig`
- [ ] T093 [US3] Implement Management API services/logs/doctor endpoints incl. `/services`, `/services/{name}`, `/services/{name}/restart` with 409, operation lock and audit in `apps/management/src/api/services.zig`, `apps/management/src/api/logs.zig`, `apps/management/src/api/doctor.zig`, `apps/management/src/services/operations.zig`, `apps/management/src/services/policy.zig`
- [ ] T094 [US3] Implement dashboard services/logs pages in `dashboard/src/routes/services/+page.svelte`, `dashboard/src/routes/logs/+page.svelte`
- [ ] T095 [US3] Implement redacted support bundle in `apps/cli/src/commands/support.zig`
- [ ] T096 [US3] Add error code docs links and docs pages in `docs/errors.md`
- [ ] T097 [US3] Run doctor fault-injection E2E in `tests/e2e/doctor-faults.sh`
- [ ] T098 [US3] Write troubleshooting guide in `docs/troubleshooting.md`
- [ ] T099 [US3] Update quickstart with status/logs/doctor validation in `docs/quickstart.md`

**Checkpoint**: Hệ thống quan sát được; lỗi có thể chẩn đoán.

---

## Phase 6: User Story 4 — Sao lưu, phục hồi và nâng cấp an toàn (Priority: P2)

**Goal**: Backup có manifest/checksum; restore cùng version; upgrade có backup/migration/health/rollback.

**Independent Test**: Tạo data, backup, restore trên VM sạch; upgrade N-1; inject lỗi và rollback.

### Tests for User Story 4

- [ ] T100 [P] [US4] Test backup manifest/checksum in `tests/unit/backup_manifest_test.zig`
- [ ] T101 [P] [US4] Integration restore test in `tests/restore/restore_instance_test.zig`
- [ ] T102 [P] [US4] Upgrade rollback fault-injection test in `tests/integration/upgrade_rollback_test.zig`
- [ ] T103 [P] [US4] Test backup excludes secrets by default in `tests/security/backup_secrets_test.zig`
- [ ] T104 [P] [US4] Test restore version/checksum mismatch rejection in `tests/restore/restore_validation_test.zig`

### Implementation for User Story 4

- [ ] T105 [US4] Implement backup manifest/checksum library in `packages/core/src/backup_manifest.zig`
- [ ] T106 [US4] Implement control DB dump in `apps/cli/src/backup/control.zig`
- [ ] T107 [US4] Implement project DB dump with bounded parallelism in `apps/cli/src/backup/projects.zig`
- [ ] T108 [US4] Implement storage archive/link-dest in `apps/cli/src/backup/storage.zig`
- [ ] T109 [US4] Implement auth keys/config/generated/secrets capture in `apps/cli/src/backup/files.zig`
- [ ] T110 [US4] Implement `backup` CLI/API in `apps/cli/src/commands/backup.zig`, `apps/management/src/api/backups.zig`
- [ ] T111 [US4] Implement `restore` ordering/validation in `apps/cli/src/commands/restore.zig`
- [ ] T112 [US4] Implement upgrade preflight/backup in `apps/cli/src/upgrade/preflight.zig`
- [ ] T113 [US4] Implement migration lock/apply in `apps/cli/src/upgrade/migrate.zig`
- [ ] T114 [US4] Implement symlink swap/health/rollback in `apps/cli/src/upgrade/rollback.zig`
- [ ] T115 [US4] Implement backup timer/retention in `deploy/native/units/doctbase-backup.timer`, `apps/cli/src/backup/retention.zig`
- [ ] T116 [US4] Implement dashboard backup/restore/upgrade pages in `dashboard/src/routes/backups/+page.svelte`, `dashboard/src/routes/upgrade/+page.svelte`
- [ ] T117 [US4] Write backup/restore/upgrade docs in `docs/backup-restore.md`, `docs/upgrade.md`
- [ ] T118 [US4] Run E2E restore/upgrade drills in `tests/e2e/backup-restore-upgrade.sh`

**Checkpoint**: Vận hành dài hạn an toàn; có rollback.

---

## Phase 7: User Story 5 — Cấu hình nâng cao mà không phá mặc định (Priority: P3)

**Goal**: External DB, external proxy, optional services, dry-run/diff, config explain/migrate.

**Independent Test**: Đổi domain/toggle service/external DB; dry-run diff đúng; apply chỉ ảnh hưởng dịch vụ liên quan; invalid config không apply.

### Tests for User Story 5

- [ ] T119 [P] [US5] Advanced config validation tests in `tests/unit/config_advanced_test.zig`
- [ ] T120 [P] [US5] External PostgreSQL integration test in `tests/integration/external_postgres_test.zig`
- [ ] T121 [P] [US5] External proxy mode integration test in `tests/integration/external_proxy_test.zig`
- [ ] T122 [P] [US5] Service toggle integration test in `tests/integration/service_toggle_test.zig`
- [ ] T123 [P] [US5] Dry-run diff/no-side-effect test in `tests/integration/apply_dry_run_test.zig`

### Implementation for User Story 5

- [ ] T124 [US5] Extend config schema for external DB/proxy/storage S3/backup keys in `packages/config/src/schema.zig`
- [ ] T125 [US5] Implement external PostgreSQL adapter and validation in `packages/postgres/src/external.zig`
- [ ] T126 [US5] Implement external proxy mode (bind localhost TCP/UDS handoff) in `apps/cli/src/install/external_proxy.zig`
- [ ] T127 [US5] Implement service enable/disable lifecycle and route closing in `apps/management/src/services/toggle.zig`
- [ ] T128 [US5] Implement dry-run plan/diff output in `packages/config/src/plan.zig`, `apps/cli/src/commands/apply.zig`
- [ ] T129 [US5] Implement `config explain` and `config migrate` in `apps/cli/src/commands/config.zig`
- [ ] T130 [US5] Implement dashboard settings/service-toggle pages in `dashboard/src/routes/settings/+page.svelte`
- [ ] T131 [US5] Write configuration reference and advanced examples in `docs/config-reference.md`
- [ ] T132 [US5] Run advanced-config E2E in `tests/e2e/advanced-config.sh`

**Checkpoint**: Người dùng nâng cao có escape hatch mà không phá golden path.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Hardening, Docker/offline, security, performance, release và validation.

- [ ] T133 [P] Complete security review checklist in `docs/security-review.md`
- [ ] T134 [P] Implement gateway rate limit and admin IP allowlist (FR-027) in `apps/gateway/src/ratelimit.zig`, `apps/management/src/auth/allowlist.zig`
- [ ] T135 [P] Implement secret/JWT key rotation flows (FR-028) in `apps/cli/src/commands/secret.zig`, `apps/auth/src/keys.zig`
- [ ] T136 [P] Run E2E matrix (Ubuntu 24.04, Debian 13, x86_64, arm64) in `.github/workflows/e2e.yml`
- [ ] T137 [P] Implement offline bundle (FR-026) in `tools/offline.zig`, `docs/offline.md`
- [ ] T138 [P] Complete Docker Compose profiles/healthchecks/secrets in `deploy/docker/compose.yml`
- [ ] T139 [P] Measure performance baseline (install, project create, gateway overhead, idle RAM) in `tests/perf/baseline.md`
- [ ] T140 [P] Generate SBOM and signed release manifest (FR-029) in `tools/release.zig`, `tools/manifest.zig`
- [ ] T141 Build release artifacts and checksums in `tools/release.zig`
- [ ] T142 Final docs review (quickstart, config, upgrade, backup, troubleshooting) in `docs/`
- [ ] T143 Run quickstart usability validation with 8/10 target in `tests/e2e/quickstart-usability.md`
- [ ] T144 Run final acceptance suite against SC-001…SC-020 in `tests/e2e/acceptance.sh`
- [ ] T145 Code cleanup, dead code removal and `zig fmt` across `apps/`, `packages/`
- [ ] T146 Update docs index and spec links in `docs/README.md`, `specs/001-doctbase-install-config/README.md`
- [ ] T147 Re-run Constitution Check and record results in `specs/001-doctbase-install-config/plan.md`
- [ ] T148 Prepare release candidate checklist in `docs/release-checklist.md`
- [ ] T149 Write operator runbook (on-call, incident, restore) in `docs/runbook.md`
- [ ] T150 Validate no secrets/ports regression and close feature in `tests/security/final_regression_test.zig`
- [ ] T164 [P] Integration test `ComposeDriver` status/restart/logs and socket-denied path in `tests/integration/compose_lifecycle_test.zig`
- [ ] T165 [P] Document runtime/service-manager operations and validation in `docs/runtime-service-manager.md`, update `docs/README.md` and `docs/quickstart.md` links

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: Không phụ thuộc; bắt đầu ngay.
- **Foundational (Phase 2)**: Phụ thuộc Setup; **blocks tất cả user story**.
- **Core Runtime & Service Manager (Phase 2B)**: Phụ thuộc Phase 2; **blocks US1–US5**; hoàn tất trước khi bắt đầu bất kỳ service executable nào.
- **US1 (Phase 3)**: Sau Phase 2B; không phụ thuộc story khác.
- **US2 (Phase 4)**: Sau Phase 2B; cần US1 installer cho E2E, nhưng logic project có thể làm song song sau T063.
- **US3 (Phase 5)**: Sau US1 + US2 (cần instance/project để quan sát) và sau T087/T093.
- **US4 (Phase 6)**: Sau US1 + US2 (cần data/project để backup).
- **US5 (Phase 7)**: Sau US1 + US2.
- **Polish (Phase 8)**: Sau các story mong muốn.

### User Story Dependencies

| Story | Priority | Depends on | Có thể test độc lập khi |
|-------|----------|------------|--------------------------|
| US1 | P1 | Phase 2B | VM sạch + installer |
| US2 | P1 | Phase 2B + US1 | Instance healthy + project create |
| US3 | P2 | US1 + US2 + T087/T093 | Instance/project đang chạy |
| US4 | P2 | US1 + US2 | Có data/project để backup |
| US5 | P3 | US1 + US2 | Instance ổn định + config nâng cao |

### Within Each User Story

- Tests MUST viết trước và fail trước implementation.
- Models/repository trước service/provision.
- Service/provision trước endpoint/CLI/dashboard.
- Core implementation trước integration/E2E.
- Story hoàn tất trước khi chuyển priority tiếp theo (trừ khi chạy song song có kiểm soát).

---

## Parallel Execution Examples

### Foundation

```bash
# Sau T011, các package độc lập có thể chạy song song:
Task: T012 config TOML parser
Task: T016 service protocol
Task: T017 http wrapper
Task: T018 telemetry logging
Task: T020 lifecycle interface
Task: T028 security primitives

# Phase 2B sau khi T016–T023 xong:
Task: T151 runtime app/bootstrap
Task: T152 runtime config/secrets
Task: T153 runtime health/info
Task: T154 runtime shutdown
Task: T155 health probe client
Task: T156–T159 runtime tests
Task: T160 dev runner integration
```

### US1

```bash
# Sau preflight (T040), các nhánh hạ tầng song song:
Task: T041 packages
Task: T042 users/dirs
Task: T043 secrets
Task: T044 PostgreSQL cluster
Task: T046 PgBouncer
Task: T047 Caddy
```

### US2

```bash
# Sau project repository (T063) + validation (T064):
Task: T065 DB/roles
Task: T066 auth keys
Task: T067 API keys
Task: T068 projects.json
Task: T069 PgBouncer entry
Task: T070 Caddy site
```

### US4

```bash
# Sau manifest lib (T105):
Task: T106 control DB dump
Task: T107 project DB dump
Task: T108 storage archive
Task: T109 auth keys/config capture
```

---

## Implementation Strategy

### MVP First (US1 + US2)

1. Hoàn thành Phase 1 + Phase 2 + Phase 2B.
2. Hoàn thành US1: cài native trên VM sạch.
3. Hoàn thành US2: tạo project + gọi API đầu tiên.
4. **STOP + VALIDATE**: quickstart §2–§5 + §5.1; đo SC-001…SC-005.
5. Demo MVP.

### Incremental Delivery

1. Foundation + Core Runtime → internal skeleton chạy được.
2. Service Manager foundation → status/dev/restart qua driver.
3. US1 → cài được.
4. US2 → tạo project/API (MVP).
5. US3 → vận hành/chẩn đoán + systemd restart.
6. US4 → backup/restore/upgrade.
7. US5 → advanced config.
8. Polish → Docker/offline/security/release.

### Parallel Team Strategy

- Sau Phase 2B:
  - Dev A: US1 installer/hạ tầng.
  - Dev B: US2 project provisioning/render.
  - Dev C: US3 status/doctor/dashboard + SystemdDriver.
  - Dev D: US4 backup/upgrade.
- US5 và polish sau khi US1/US2 ổn định.
- Tránh sửa cùng file: phân chia theo `apps/`, `packages/`, `deploy/`, `dashboard/`.

---

## Notes

- `[P]` = khác file, không dependency chưa xong.
- `[US*]` map task → user story để traceability.
- Test-first: test phải fail trước implementation.
- Commit theo task hoặc nhóm logic.
- Không bắt đầu US3/US4 khi US1/US2 chưa có checkpoint.
- T151–T165 là task bổ sung sau bộ task gốc; thứ tự thực hiện theo phase, không theo số ID.
- Mọi task phải giữ Constitution Check (đặc biệt Principle IV và VII).
- Cập nhật `tasks.md` khi scope thay đổi; không đánh dấu hoàn thành nếu acceptance chưa pass.
