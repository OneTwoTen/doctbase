# Implementation Plan: Triển khai Doctbase như một Coolify resource

**Branch**: `002-coolify-resource` | **Date**: 2026-11-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification từ `specs/002-coolify-resource/spec.md`

## Summary

Thêm một đường triển khai tùy chọn: Doctbase chạy như **một Coolify resource kiểu Docker Compose** (chọn repo GitHub như app bình thường), gồm nhiều container độc lập. Slice đầu gồm `gateway` + `management`, kèm profile database `bundled` (PostgreSQL 18 + PgBouncer) hoặc `external` (dùng database sẵn có). Coolify/Traefik sở hữu 80/443 và TLS trong mode này; native/systemd + Caddy vẫn là golden path và không đổi hành vi.

Thay đổi kỹ thuật cốt lõi:

- `packages/runtime`: thêm TCP listener (hiện chỉ có UDS) để container nói chuyện qua private network, giữ nguyên UDS cho native.
- `deploy/docker/`: Dockerfile multi-stage (Zig 0.17.1), compose file cho Coolify, entrypoint render `doctbase.toml` từ biến môi trường.
- Dashboard Svelte được build thành static bundle và chỉ được thêm vào image management; management phục vụ dashboard trên cùng port/domain 8081, không tạo service hay config mới.
- Biến môi trường theo chuẩn Coolify (`SERVICE_FQDN_*`, `SERVICE_PASSWORD_*`) để domain/secret được sinh và giữ qua redeploy.
- CI: validate compose, build image, smoke test TCP + compose profile; test mới cho TCP listener.
- Tài liệu `docs/coolify.md` (tạo resource, domain, database, rollback, giới hạn V1).

## Technical Context

**Language/Version**: Zig `0.17.1` (theo `.zigversion`), Docker Compose v2, POSIX shell cho entrypoint.

**Primary Dependencies**: `httpz` (đã pin), Node.js 22/npm lockfile cho dashboard, PostgreSQL 18, PgBouncer, `curl` cho healthcheck, Docker BuildKit.

**Storage**: PostgreSQL 18 (profile `bundled`) hoặc database ngoài (profile `external`); volume `doctbase-data` cho state/storage; volume `postgres-data` chỉ khi bundled.

**Testing**: `zig build test` (unit + integration, thêm `tests/integration/runtime_tcp_test.zig`), `docker compose config`, build image trong CI, smoke test `gateway`/`management` qua TCP, kiểm tra profile bundled.

**Target Platform**: Linux x86_64/arm64 container; Coolify v4 (Docker Compose resource). Không hỗ trợ Windows native.

**Project Type**: Monorepo microservices + deployment artifacts.

**Performance Goals**:
- Từ lúc bấm deploy đến resource healthy: ≤ 10 phút (SC-001).
- Build image trên CI: ≤ 10 phút (cache layer Zig).
- Rollback: ≤ 5 phút (Coolify redeploy image cũ).
- Footprint cấu hình cơ bản: ≤ 4 GB RAM (SC-005).

**Constraints**:
- Một replica mỗi service; không scale ngang trong V1.
- Không publish cổng nội bộ; chỉ gateway/management nhận traffic từ proxy.
- Không chạy Caddy trong mode Coolify (tránh chiếm 80/443).
- Không thêm supervisor tự viết; Compose là lifecycle owner.
- Secret do Coolify sinh và persist; không có mật khẩu mặc định.
- Native install không bị thay đổi hành vi hay contract.
- Dashboard chỉ hoạt động trong Docker management image; API/auth/services/setup/health/metrics/internal không được SPA fallback; đường dẫn asset phải được giới hạn trong bundle.
- Không thêm biến cấu hình, service, public port hay secret cho dashboard.

**Scale/Scope**: 2 service public (gateway, management) + 2 service hạ tầng tùy chọn (postgres, pgbouncer); 5 service tùy chọn bật sau (auth, rest, realtime, storage, image-proxy, pg-meta).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Gate | Kết quả |
|-----------|------|---------|
| I. Zig-First, PostgreSQL-Native | Không đổi service/CLI; PostgreSQL native; không thêm abstraction | **PASS** |
| II. Service Independence, Shared Contracts | Mỗi service vẫn là executable + container + health riêng; không gộp process | **PASS** |
| III. Single-VPS First, Native-First | Native vẫn golden path; Coolify là optional; không Kubernetes/Redis/NATS | **PASS** (sau amendment cho external proxy) |
| IV. Installability & Configurability | Một resource, biến môi trường có default, không sửa file generated, idempotent | **PASS** — env là config surface trong mode Coolify (ghi ở Complexity Tracking) |
| V. Security by Default | Secret sinh tự động, không publish DB, private network, management có auth, non-root image; fallback không che API và asset path được giới hạn | **PASS** |
| VI. Observability, Backup, Recoverability | Health theo container, log có cấu trúc, rollback ≤ 5 phút, volume bền vững | **PASS** |
| VII. Test-First & Contract Discipline | Test TCP listener, dashboard route boundaries, compose config và smoke test CI trước khi coi là xong | **PASS** |
| Technical Constraints — Docker "only Caddy publishes 80/443" | Cần amendment: external managed proxy được phép sở hữu 80/443 trong mode Coolify | **AMENDMENT** (xem `.specify/memory/amendments/2026-11-06-external-proxy-coolify.md`) |
| Process lifecycle constraint | Compose là lifecycle owner; không supervisor tự viết | **PASS** |

**Post-Design re-check**: Dashboard dùng management port/image hiện có, không thêm service, public port, biến cấu hình hay secret; route API/setup/health/metrics/internal không nhận HTML fallback; asset paths được giới hạn trong bundle. Native/systemd không được bật dashboard. Hai quyết định kiến trúc đã duyệt trước đó vẫn là: (1) amendment external proxy/TLS, (2) config surface bằng env trong container mode.

## Project Structure

### Documentation (this feature)

```text
specs/002-coolify-resource/
├── spec.md
├── plan.md
├── research.md          # quyết định Coolify magic vars, profile, healthcheck
├── quickstart.md        # các bước trên Coolify UI
├── contracts/
│   └── env.md           # danh sách biến môi trường + default
└── checklists/
    └── requirements.md
```

### Source Code (repository root)

```text
packages/runtime/src/runtime.zig        # thêm TCP listener + Option.listen
packages/runtime/src/bootstrap.zig      # (nếu cần) map env → options
tests/integration/runtime_tcp_test.zig  # test health/ready/info qua TCP
tests/security/runtime_tcp_security_test.zig  # token/allowlist qua TCP
apps/management/src/dashboard.zig      # serve static bundle, MIME và SPA fallback có giới hạn
dashboard/package-lock.json            # khóa dependency để build dashboard lặp lại được

deploy/docker/
├── Dockerfile             # multi-stage: Zig + dashboard; target management chứa static bundle
├── compose.yml            # resource cho Coolify (gateway, management, profiles)
├── entrypoint.sh          # render /etc/doctbase/doctbase.toml từ env
├── .env.example           # biến cho chạy local/không Coolify
└── healthcheck.sh         # wrapper curl cho healthcheck

docs/coolify.md            # hướng dẫn tạo resource, domain, DB, rollback
docs/development.md        # thêm mục chạy compose local

.github/workflows/ci.yml   # thêm job compose + image smoke test
```

**Structure Decision**: Đặt artifact triển khai trong `deploy/docker/` theo plan.md của feature 001 (T005/T138), không tạo cây thư mục mới. Docker dev toolchain hiện có ở `deploy/dev/` giữ nguyên vai trò build/test local.

## Phase Plan

### Phase 0 — Research (research.md)

- Xác nhận hành vi Coolify magic env (`SERVICE_FQDN_<SERVICE>_<PORT>`, `SERVICE_PASSWORD_*`) và cách Coolify gắn domain cho từng service trong compose.
- Chọn cách truyền config: entrypoint render TOML từ env (giữ một file cấu hình, config hash ổn định) thay vì đọc env rải rác trong code.
- Chọn healthcheck (`curl -fsS http://127.0.0.1:PORT/readyz`) và thời gian `start_period`.
- Quyết định profile `bundled`/`external` dùng `COMPOSE_PROFILES` do Coolify inject.
- Xác nhận không dùng `container_name`, không publish `ports`, không đặt traefik label thủ công (Coolify tự sinh cho Git-based compose).

### Phase 1 — Design & contracts

- `contracts/env.md`: bảng biến môi trường (tên, bắt buộc, default, mô tả, ví dụ), gồm `DOCTBASE_MODE`, `DOCTBASE_LISTEN`, `DOCTBASE_INTERNAL_TOKEN`, `DOCTBASE_DOMAIN`, `DATABASE_*`, `SERVICE_FQDN_*`.
- `quickstart.md`: luồng Coolify UI từng bước (New Resource → Docker Compose → repo → base directory → compose path → env → domain → deploy).
- `data-model.md`: không có entity mới ở tầng dữ liệu; ghi rõ volume/secret là entity vận hành. (Có thể bỏ nếu không cần.)

### Phase 2 — Implementation slices

1. **TCP listener (P1)**: `Options.listen`, parse `DOCTBASE_LISTEN=host:port`, httpz TCP; giữ UDS mặc định; test integration + security; cập nhật `docs/runtime-service-manager.md`.
2. **Image & entrypoint (P1)**: Dockerfile multi-stage, user non-root, entrypoint render TOML, healthcheck script.
3. **Compose resource (P1)**: gateway + management, `expose` nội bộ, healthcheck, volumes, env mẫu, profile `bundled`/`external`.
4. **Domain & secret qua Coolify (P1)**: `SERVICE_FQDN_GATEWAY_8080`, `SERVICE_FQDN_MANAGEMENT_8081`, secret sinh bằng `SERVICE_PASSWORD_64_*`; tài liệu cách đổi domain.
5. **CI & verification (P1)**: job compose config + build image + `up` hai service + curl health; chạy profile bundled (postgres) một lần.
6. **Dashboard (P1)**: build static từ lockfile; chỉ management image nhận bundle; management phục vụ root, asset đúng MIME và deep-link fallback có giới hạn; API/auth/services/setup/health/metrics/internal tiếp tục trả response hiện hữu.
7. **Docs (P2)**: `docs/coolify.md` và troubleshooting mô tả domain management, kiểm tra root/asset/deep-link/API 404, giới hạn (1 replica, không di trú native ↔ Coolify) và rollback image.

### Phase 3 — Rollout / rollback

- Rollback: Coolify rollback về deployment trước; volume `doctbase-data`/`postgres-data` không bị xoá; migration chạy dưới lock và idempotent.
- Nếu image mới lỗi dashboard, rollback về image/commit trước trong Coolify; không xoá volume hoặc đổi config. Native/systemd không bị ảnh hưởng.
- Nếu amendment không được duyệt: dừng ở Phase 1, không merge compose có Traefik; giữ artifact ở nhánh feature.

## Risks

| Risk | Mitigation |
|------|------------|
| Coolify đổi hành vi magic env giữa các phiên bản | Chỉ dựa trên biến có tài liệu; luôn cho phép đặt domain thủ công qua UI |
| Compose profile không được Coolify truyền | Dùng `COMPOSE_PROFILES` env (Coolify inject) + tài liệu; test trong CI |
| TCP listener làm lộ cổng nội bộ | Chỉ `expose`; không `ports`; test CI khẳng định không publish |
| Migration chạy 2 lần khi redeploy | Lock + idempotent (đã có ở feature 001) |
| Image quá lớn | Build stage cache + chỉ copy binary cần cho từng service (build arg `SERVICE`) |
| SPA fallback che lỗi API hoặc health | Loại trừ namespace API/auth/services/setup/runtime trước fallback; kiểm tra unknown API vẫn là Problem Details JSON trong test và CI |
| Path traversal đọc file host/container | Chỉ nhận path tương đối hợp lệ trong bundle; từ chối encoding/dấu phân cách nguy hiểm và test traversal |
| Dashboard bị đóng gói vào mọi service | Dùng Docker target management riêng; CI xác nhận tài nguyên UI chỉ tồn tại trong image management |
| Amendment bị từ chối | Giữ mode Coolify ngoài phạm vi merge; native path không bị ảnh hưởng |

## Complexity Tracking

| Deviation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| Config surface bằng env trong container mode | Coolify quản lý cấu hình qua env UI; mount file thủ công phá "một resource, không sửa file" | Bắt người dùng mount TOML thủ công làm hỏng trải nghiệm cài đặt và không idempotent |
| External proxy (Traefik) sở hữu 80/443 | Coolify đã có proxy/TLS tích hợp; chạy thêm Caddy sẽ xung đột cổng | Giữ Caddy buộc phải tắt proxy Coolify, mất TLS/domain tự động của nền tảng |
