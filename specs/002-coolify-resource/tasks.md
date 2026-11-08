# Tasks: Triển khai Doctbase như một Coolify resource

**Input**: Design artifacts từ `specs/002-coolify-resource/`
**Prerequisites**: `plan.md`, `spec.md`, amendment đã duyệt
**Branch**: `002-coolify-resource`

## Phase 1: Setup

- [x] T001 Thêm job CI validate compose và smoke test image trong `.github/workflows/ci.yml`
- [x] T002 Cập nhật `.dockerignore` cho build production (không copy `.git`, `zig-out`, `.zig-cache`, `docs`, `specs`)
- [x] T003 [P] Thêm `deploy/docker/.env.example` với đầy đủ biến bắt buộc và default

## Phase 2: Foundational — TCP listener

- [x] T004 Thêm `Options.listen` và parse `host:port` trong `packages/runtime/src/runtime.zig`
- [x] T005 Cho `Runtime.create` khởi tạo httpz bằng TCP khi có `listen`, giữ UDS mặc định; bỏ qua socket file/permissions khi TCP
- [x] T006 Map `DOCTBASE_LISTEN` trong `runService` và log endpoint đúng loại (UDS/TCP) trong `packages/runtime/src/runtime.zig`
- [x] T007 Viết `tests/integration/runtime_tcp_test.zig`: health/ready/info qua TCP, token bắt buộc, graceful shutdown
- [x] T008 Viết `tests/security/runtime_tcp_security_test.zig`: thiếu token trả 401, token sai trả 401, không lộ secret trong response
- [x] T009 Đăng ký 2 test mới trong `build.zig` (`test` step)

## Phase 3: User Story 1 — Cài từ GitHub thành Coolify resource

**Goal**: Một resource compose chạy gateway + management, domain do Coolify cấp.
**Independent test**: `docker compose config` hợp lệ; build và chạy 2 service; `curl /healthz` và `/readyz` trả 200 qua TCP.

- [x] T010 [US1] Tạo `deploy/docker/Dockerfile` multi-stage (Zig 0.17.1 → Debian 13 slim), user non-root, chỉ copy binary theo build arg `SERVICE`
- [x] T011 [US1] Tạo `deploy/docker/entrypoint.sh` sinh `/etc/doctbase/doctbase.toml` từ env, `exec` service; `deploy/docker/healthcheck.sh`
- [x] T012 [US1] Tạo `deploy/docker/compose.yml`: service `gateway` (8080) + `management` (8081), `expose` nội bộ, healthcheck, volume, `init: true`, không `ports`, không `container_name`
- [x] T013 [US1] Khai báo magic env `SERVICE_FQDN_GATEWAY_8080`, `SERVICE_FQDN_MANAGEMENT_8081` và `SERVICE_PASSWORD_64_INTERNALTOKEN` trong compose
- [x] T014 [US1] Cấu hình `DOCTBASE_MODE=docker`, `DOCTBASE_LISTEN`, `DOCTBASE_INTERNAL_TOKEN`, `DOCTBASE_CONFIG` cho từng service
- [x] T015 [US1] Kiểm tra `docker compose config` + build image + chạy 2 container + curl health trong CI
- [x] T016 [US1] Viết `docs/coolify.md`: tạo resource, base directory, compose path, domain, secret, kiểm tra healthy

## Phase 4: User Story 2 — Database bundled hoặc external

- [x] T017 [US2] Thêm `postgres` (PostgreSQL 18) vào profile `bundled` với volume `postgres-data` và healthcheck `pg_isready`
- [x] T018 [US2] Thêm `pgbouncer` (transaction pooling) vào profile `bundled`, trỏ tới `postgres`, healthcheck TCP
- [x] T019 [US2] Map `DOCTBASE_DATABASE_MODE`/`POSTGRES_*` vào config sinh bởi entrypoint; mode `managed` ↔ profile bundled, `external` ↔ database ngoài. **Ghi chú**: URL/credential connection của service là follow-on khi feature DB được triển khai (schema hiện chưa có trường URL).
- [x] T020 [US2] Thêm `COMPOSE_PROFILES` hướng dẫn + test `docker compose --profile bundled config` trong CI
- [x] T021 [US2] Ghi rõ trong docs: service hiện chưa dùng DB (skeleton), profile bundled là hạ tầng sẵn cho feature follow-on

## Phase 5: User Story 3 — Upgrade/rollback

- [x] T022 [US3] Ghi rõ quy trình rollback Coolify trong `docs/coolify.md` (deploy lại image/commit cũ, giữ volume)
- [x] T023 [US3] Đảm bảo entrypoint không ghi đè config/secret khi restart; volume `doctbase-data` giữ state
- [x] T024 [US3] Thêm kiểm tra idempotent: `compose up` lần hai và health lại trong CI

## Phase 6: User Story 4 — Bật service tùy chọn

- [x] T025 [US4] Thêm service tùy chọn `auth` vào compose với `profiles: ["optional"]`
- [x] T026 [US4] Tài liệu cách bật/tắt từng service và ảnh hưởng tài nguyên
- [x] T027 [US4] Test CI: bật profile optional, `auth` healthy và gateway/management không gián đoạn

## Phase 7: Polish & verification

- [x] T028 Cập nhật `.specify/memory/constitution.md` theo amendment 1.1.0 (external proxy + config surface) và ghi link amendment
- [x] T029 Chạy `zig fmt --check`, `zig build`, `zig build test` (compile), `zig build -Dtarget=aarch64-linux-gnu`; test thực thi trên CI
- [x] T030 Cập nhật `README.md`, `docs/README.md`, `docs/development.md`, `docs/runtime-service-manager.md`
- [x] T031 Chạy CI đầy đủ (2 job hiện có + job compose) và xác nhận xanh
- [x] T032 Mở PR stacked lên `ci/build-test-docker-dev`, link PR, ghi rõ giới hạn slice

## Phase 8: Dashboard cho management (US1)

- [x] T033 [US1] Cập nhật `specs/002-coolify-resource/spec.md` với acceptance scenario cho dashboard root, deep-link, JSON API 404 và chống traversal
- [x] T034 [US1] Cập nhật `specs/002-coolify-resource/plan.md` về static bundle management-only, route boundary, security review và rollback
- [x] T035 [P] [US1] Tạo `dashboard/package-lock.json` và xác nhận `npm ci`, `npm run check`, `npm run build` tạo static fallback
- [x] T036 [US1] Thêm `apps/management/src/dashboard.zig` để phục vụ GET/HEAD, MIME, SPA fallback giới hạn và từ chối path traversal; unit test cả alias `/auth` và `/services`, reserved route, root, asset, deep-link và file không tồn tại
- [x] T037 [US1] Nối dashboard handler vào `apps/management/src/app.zig` và `apps/management/src/main.zig` chỉ trong Docker mode; giữ unknown API JSON 404 và native/systemd behavior
- [x] T038 [US1] Thêm target `management` trong `deploy/docker/Dockerfile`, chọn target đó trong `deploy/docker/compose.yml`, chỉ copy bundle vào image management
- [x] T039 [US1] Mở rộng `.github/workflows/ci.yml` smoke test root HTML, asset MIME, deep-link fallback, API JSON 404, path traversal và xác nhận image gateway không chứa dashboard
- [x] T040 [P] [US1] Cập nhật `docs/coolify.md` và `docs/troubleshooting.md` cách gán domain management, kiểm tra dashboard và rollback image
- [x] T041 Chạy npm check/build, `zig fmt`, `zig build test`, compose config và image smoke test; kết quả: npm check/build đạt (có cảnh báo Rollup), Zig fmt đạt, 193/193 Zig tests, compose default/bundled/optional hợp lệ, build hai image đạt, smoke root/assets/deep-link/API 404/traversal/image boundary đạt.

## Dependencies

- T004 → T005 → T006 → T007/T008 → T009
- T010 → T011 → T012 → T013/T014 → T015/T016
- T017/T018 → T019 → T020
- T022 → T023 → T024
- T025 → T026 → T027
- Tất cả → T028 → T029 → T030 → T031 → T032
- T033 → T034 → T035/T036 → T037 → T038 → T039 → T041
- T040 có thể chạy song song sau T034; T040 → T041

## Constitution Check (mỗi task)

- Principle III/IV: không thêm service bắt buộc, native không đổi, mọi biến có default (trừ DB ngoài/domain).
- Principle V: không publish DB, secret sinh tự động, image non-root.
- Principle VII: test trước/ cùng implementation cho TCP listener và compose.
- Dashboard security: fallback không áp dụng cho `/api`, `/setup`, health/metrics/internal; unknown API giữ JSON 404; asset path không thể thoát khỏi bundle; chỉ management image chứa static files.
