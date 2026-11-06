# Phát triển, build và test

Tài liệu này mô tả ba cách chạy build/test của Doctbase: native (Linux/macOS), Docker (mọi hệ điều hành) và CI. Constitution là nguồn chuẩn; tài liệu này chỉ hướng dẫn thao tác.

## Yêu cầu chung

- Zig đúng phiên bản ghim trong [`.zigversion`](../.zigversion) (hiện tại `0.17.1`).
- Không dùng bản Zig development cho release.
- Build lần đầu cần mạng để tải dependency `httpz` khai báo trong [`build.zig.zon`](../build.zig.zon).

> **Windows:** mã runtime dùng `std.posix` (signal handling, Unix domain socket) nên **không build native trên Windows**. Dùng Docker (mục dưới) hoặc WSL2. `zig build -Dtarget=x86_64-linux-gnu` chỉ kiểm tra biên dịch, không chạy được test.

## Native (Linux/macOS)

```bash
zig build --summary all
zig build test --summary all
zig fmt --check build.zig apps packages tests
```

Chạy gateway ở chế độ dev (xem [Core Runtime + Service Manager](runtime-service-manager.md)):

```bash
./zig-out/bin/doctbase dev --run-dir /tmp/doctbase-dev --bin-dir zig-out/bin --token dev-secret
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/healthz
```

## Docker (không cần cài Zig)

Toolchain nằm trong [`deploy/dev/Dockerfile`](../deploy/dev/Dockerfile), chạy qua [`deploy/dev/compose.yml`](../deploy/dev/compose.yml). Repo được mount vào `/src`, nên sửa file trên host là container thấy ngay và `zig-out/`, `.zig-cache/` ghi thẳng vào repo.

```bash
docker compose -f deploy/dev/compose.yml build
docker compose -f deploy/dev/compose.yml run --rm toolchain zig build
docker compose -f deploy/dev/compose.yml run --rm toolchain zig build test --summary all
docker compose -f deploy/dev/compose.yml run --rm toolchain zig fmt --check build.zig apps packages tests
docker compose -f deploy/dev/compose.yml run --rm toolchain zig version
```

Mở shell trong toolchain khi cần debug:

```bash
docker compose -f deploy/dev/compose.yml run --rm --entrypoint bash toolchain
```

Lưu ý:

- Image mặc định dùng `ZIG_VERSION=0.17.1`. Khi đổi `.zigversion`, chạy lại với `ZIG_VERSION=<phiên bản>` hoặc cập nhật biến môi trường để image và native build khớp nhau.
- Cache của Zig nằm trong repo (`.zig-cache/`, `.zig-global-cache/`), nên lần build sau không tải lại dependency và bạn xoá được bằng tay.
- Trên Linux, nếu uid của bạn khác `1000`, truyền `--user "$(id -u):$(id -g)"` cho `docker compose run` để file sinh ra không thuộc user lạ. Trên Windows/macOS không cần.
- Trên Windows cần Docker Desktop (WSL2 backend) và quyền admin để cài đặt. Nếu chưa có Docker, xem mục CI bên dưới.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) chạy trên `ubuntu-24.04` cho mỗi push vào `main`, mỗi pull request và chạy tay (`workflow_dispatch`). Pipeline:

1. Cài Zig theo `.zigversion` và đối chiếu SHA256 với `ziglang.org/download/index.json`.
2. `zig fmt --check build.zig apps packages tests`.
3. `zig build --summary all`.
4. `zig build test --summary all`.
5. Cross-build `-Dtarget=aarch64-linux-gnu` để bắt lỗi kiến trúc sớm.

Job thứ hai (`docker-toolchain`) build `deploy/dev/Dockerfile` rồi chạy `zig build test` bên trong container, để đường Docker được kiểm chứng ngay trên CI.

E2E install matrix (Ubuntu 24.04, Debian 13, x86_64/arm64) nằm ở task T136 trong [`specs/001-doctbase-install-config/tasks.md`](../specs/001-doctbase-install-config/tasks.md) và chưa được bật.

## Kiểm tra nhanh sau khi build

```bash
zig build test --summary all
ls zig-out/bin   # doctbase + 8 service binary
```
