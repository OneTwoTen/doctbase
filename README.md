# Doctbase

Doctbase là hệ sinh thái Backend-as-a-Service (BaaS) mã nguồn mở, modular, self-hosted, phát triển bằng Zig, dùng PostgreSQL nguyên bản và tối ưu cho triển khai trên một VPS.

**Trạng thái hiện tại**: Spec Kit cho V1 Foundation đã hoàn tất; **Core Runtime + Service Manager Slice 2** đã có implementation (shared runtime, gateway/auth skeleton, UDS health/ready/info/metrics, graceful shutdown, `doctbase dev/status/restart`, `DevDriver` + `SystemdDriver`). `ComposeDriver`, Service Manager API và Management dashboard là slice tiếp theo.

## Chạy thử nhanh

Yêu cầu: Zig `0.17.1` (xem [.zigversion](.zigversion)).

```bash
zig build
./zig-out/bin/doctbase dev \
  --run-dir /tmp/doctbase-dev \
  --bin-dir zig-out/bin \
  --token dev-secret
```

```bash
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/healthz
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/readyz
curl --unix-socket /tmp/doctbase-dev/gateway.sock \
  -H 'Authorization: Bearer dev-secret' \
  http://localhost/internal/v1/info
```

Test: `zig build test`. Chi tiết: [Core Runtime + Service Manager](docs/runtime-service-manager.md).

### Build/test bằng Docker (không cần cài Zig)

Toolchain Zig `0.17.1` nằm trong [`deploy/dev`](deploy/dev/compose.yml); repo được mount vào `/src`:

```bash
docker compose -f deploy/dev/compose.yml build
docker compose -f deploy/dev/compose.yml run --rm toolchain zig build
docker compose -f deploy/dev/compose.yml run --rm toolchain zig build test --summary all
```

Windows không build native được (runtime dùng POSIX signal + Unix domain socket) — dùng Docker hoặc WSL2. CI trên GitHub Actions tự chạy format/build/test cho mỗi push và pull request. Chi tiết: [Phát triển, build và test](docs/development.md).

## Bắt đầu đọc

- [Constitution](.specify/memory/constitution.md) — nguyên tắc dự án.
- [Feature 001 — Spec](specs/001-doctbase-install-config/spec.md) — cài đặt, cấu hình và vận hành dễ dàng.
- [Feature 001 — Plan](specs/001-doctbase-install-config/plan.md) — kế hoạch kỹ thuật.
- [Feature 001 — Tasks](specs/001-doctbase-install-config/tasks.md) — 165 task triển khai, gồm Core Runtime + Service Manager foundation.
- [Phát triển, build và test](docs/development.md) — build native, Docker toolchain và CI.
- [Docs index](docs/README.md) — toàn bộ tài liệu.
- [Nghiên cứu chi tiết](docs/nghien-cuu-cai-dat-cau-hinh.md) — phân tích và quyết định thiết kế.

## Mục tiêu V1

- 9 nhóm service: Database + Pooler, Gateway, Management + Dashboard, Auth, REST, Realtime, Storage, Image Proxy, PostgreSQL Metadata.
- Native-first trên Debian/Ubuntu, Docker optional.
- Một CLI, một file cấu hình, một lệnh tạo project.
- Cài xong trên VPS 2 vCPU/2 GB trong ≤ 5 phút; API đầu tiên trong ≤ 60 giây.

## Cấu trúc repo dự kiến

```text
apps/          # service Zig + CLI
packages/      # shared Zig packages (runtime, config, core, protocol, lifecycle)
dashboard/     # SvelteKit static dashboard
infrastructure/# PostgreSQL, PgBouncer, Caddy templates
deploy/        # native systemd + Docker
docs/          # research + user docs
specs/         # Spec Kit feature artifacts
tests/         # unit/integration/e2e/security/restore
```

## Quy ước

- Spec Kit là nguồn chuẩn cho yêu cầu và kế hoạch.
- Không sửa generated artifacts; dùng `doctbase apply`.
- Mọi thay đổi phải pass Constitution Check và installability budget.
