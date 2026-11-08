# Quickstart

Tài liệu một trang cho hai đường cài đặt: **native** (mặc định, khuyến nghị) và
**Docker** (tùy chọn). Chi tiết đầy đủ ở [Install](install.md); các giới hạn
của slice hiện tại ở cuối trang đó.

## 1. Cài native

Yêu cầu: Debian 13 hoặc Ubuntu 24.04/26.04, x86_64/arm64, 2 GiB RAM, 20 GiB
trống, quyền root. Domain và email TLS là tùy chọn.

```sh
# Một lệnh từ release (manifest + artifact có chữ ký)
curl -fsSL https://get.doctbase.dev | sudo sh -s -- \
  --domain example.com --email admin@example.com --yes

# Hoặc CLI đã cài sẵn
sudo doctbase install --domain example.com --email admin@example.com --dry-run
sudo doctbase install --domain example.com --email admin@example.com --yes
sudo doctbase install --yes    # local mode, dùng SSH tunnel
```

Kết quả cuối có URL dashboard (hoặc hướng dẫn SSH tunnel), health gateway và
management, đường dẫn config, setup token và log. Không lệnh nào in giá trị
secret.

## 2. Tạo admin

```sh
sudo cat /etc/doctbase/secrets/admin_setup_token   # chỉ đọc một lần
```

Mở `https://admin.<domain>/setup` (hoặc gọi `POST /setup` qua SSH tunnel tới
`/run/doctbase/management.sock` trong local mode), nhập token, email và password
≥ 12 ký tự. Token hết hạn sau 30 phút và chỉ dùng một lần; không có mật khẩu mặc
định.

## 3. Kiểm tra và repair

```sh
sudo doctbase status
sudo doctbase repair --dry-run
sudo doctbase repair --yes
```

`repair` chạy lại transaction idempotent của installer: giữ config, secret,
PostgreSQL cluster, project data và backup; chỉ thêm/sửa binary, unit, file
generated và khởi động lại service còn thiếu. Chạy `repair` khi:

- lần cài trước bị gián đoạn hoặc health fail;
- binary/unit bị thiếu sau khi nâng cấp OS;
- muốn khôi phục service về trạng thái healthy mà không mất dữ liệu.

Repair yêu cầu state `/var/lib/doctbase/state.json` đã tồn tại. Host chưa cài
phải dùng `doctbase install`.

## 4. Gỡ cài đặt

```sh
sudo doctbase uninstall --dry-run
sudo doctbase uninstall --yes            # giữ config + data để cài lại
sudo doctbase uninstall --purge          # gõ đúng "purge"; xóa toàn bộ data
```

## 5. Docker (tùy chọn)

Docker cần Docker Engine + Compose v2. Đường Docker độc lập dùng Caddy công
khai 80/443; các service lõi chỉ `expose` trong mạng Compose.

```sh
# Một lệnh trong repo/bundle hiện tại
sh deploy/docker/install.sh \
  --domain example.com --email admin@example.com \
  --dir /opt/doctbase --database bundled --yes

# Hoặc hai bước tường minh
doctbase init --profile docker --dir /opt/doctbase \
  --domain example.com --email admin@example.com \
  --database bundled --assets /usr/local/lib/doctbase/current/share
doctbase up --profile docker --dir /opt/doctbase
```

`init` sinh `compose.yml`, `Caddyfile` và `.env` (secret 256-bit, mode `0600`)
trong thư mục đích. Chạy lại sẽ cập nhật các key cấu hình theo cờ mới nhưng
không bao giờ ghi đè secret đã sinh. `up` gọi
`docker compose ... up -d --wait`, không thêm supervisor.

- `--database external` (mặc định): trỏ tới PostgreSQL bạn tự quản lý.
- `--database bundled`: bật profile `bundled` (PostgreSQL 18 + PgBouncer).
- Không có domain: Caddy phục vụ HTTP trên `:80` cho local/SSH tunnel.
- Nâng cấp: đổi `DOCTBASE_VERSION`/`--version` trong `.env` rồi chạy lại
  `doctbase up`; rollback bằng cách pin version cũ. Volume giữ nguyên.
- Chạy trên Coolify/nền tảng có proxy riêng: dùng
  [compose resource](coolify.md) (`deploy/docker/compose.yml`), không dùng
  template standalone.

Ảnh `doctbase/*` phải được publish ở registry (release bundle); trong repo,
`deploy/docker/install.sh` dùng binary `doctbase` và template local.

## 6. Phát triển

Cài Zig theo `.zigversion`, build và chạy vài service foreground:

```sh
zig build
./zig-out/bin/doctbase dev --run-dir /tmp/doctbase-dev --bin-dir zig-out/bin --token dev-secret
```

Kiểm tra qua Unix socket:

```sh
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/healthz
curl --unix-socket /tmp/doctbase-dev/gateway.sock http://localhost/readyz
```

Xem [Development](development.md) cho Docker toolchain/CI và
[Install](install.md) cho chi tiết native/Docker, idempotency, rollback và giới
hạn slice hiện tại.
