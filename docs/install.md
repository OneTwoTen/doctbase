# Cài đặt native trên Linux

Tài liệu này mô tả luồng `doctbase install` trên một VPS Debian 13 hoặc
Ubuntu 24.04/26.04 (x86_64/arm64). Đây là golden path native; Docker/Coolify là
đường tùy chọn và có tài liệu riêng.

> **Trạng thái slice hiện tại**: orchestration, state file, lock, rollback,
> health verification và summary đã có. Bootstrap admin/setup token trong
> Management API (task T050), `project create` (US2), script cài một dòng
> (T053) và `uninstall` (T054) vẫn là các slice tiếp theo.

## Điều kiện

- Debian 13 hoặc Ubuntu 24.04/26.04, x86_64 hoặc arm64.
- Tối thiểu 2 GiB RAM và 20 GiB trống cho `/var/lib/doctbase`.
- Port 80/443 chưa bị dịch vụ khác chiếm (trừ khi bạn tự chuyển sang chế độ
  external proxy ở slice sau).
- Có quyền root (hoặc `sudo`).
- DNS của domain (nếu dùng) đã trỏ về server để Caddy lấy chứng chỉ.

Kiểm tra trước khi thay đổi hệ thống:

```sh
sudo doctbase install --domain example.com --email admin@example.com --dry-run
```

`--dry-run` chỉ đọc host và in kế hoạch: package, user/thư mục, cluster/port,
file generated, service và các cảnh báo preflight. Không ghi file, không tạo
user, không cài package.

## Cài đặt

Với gói release (asset mặc định nằm dưới
`/usr/local/lib/doctbase/current/share`, binary dưới
`/usr/local/lib/doctbase/current/bin`):

```sh
sudo doctbase install --domain example.com --email admin@example.com --yes
```

Không có domain (chế độ local, chỉ truy cập qua SSH tunnel):

```sh
sudo doctbase install --yes
```

Khi chạy từ repo trong lúc phát triển:

```sh
sudo ./zig-out/bin/doctbase install --yes \
  --assets . \
  --bin-dir zig-out/bin
```

### Các bước installer thực hiện

1. Preflight: OS/arch, RAM, dung lượng đĩa, port 80/443, DNS (warning), host
   không hỗ trợ thì dừng trước khi ghi bất cứ thứ gì.
2. Cài PostgreSQL 18 (PGDG), PgBouncer và Caddy; tạm chặn package tự bật
   service và không để PostgreSQL tạo cluster mặc định trên 5432.
3. Tạo group `doctbase`, user riêng cho từng service và các thư mục với mode
   đã định nghĩa.
4. Sinh secret 256-bit dưới `/etc/doctbase/secrets` (mode `0600`); không ghi
   secret vào config, log hay environment.
5. Tạo cluster PostgreSQL 18 tên `doctbase` trên port 5433, chỉ Unix socket;
   ghi tuning, `pg_hba.conf` không có dòng `host`, và bootstrap role/database.
6. Render `pgbouncer.ini` (transaction pooling, `listen_addr` rỗng) và
   `Caddyfile` (admin API qua Unix socket).
7. Ghi `/etc/doctbase/doctbase.toml` nếu chưa có. File này là file duy nhất
   người vận hành sửa; installer không ghi đè sau lần đầu.
8. Copy binary service vào `/usr/local/lib/doctbase/current/bin`, render unit
   systemd, target và polkit rule.
9. Enable/start `doctbase.target`, sau đó chờ gateway và management trả
   `/readyz` qua Unix socket.

### Kết quả

```text
Health: gateway ready, management ready
Config: /etc/doctbase/doctbase.toml
Setup token: /etc/doctbase/secrets/admin_setup_token (đọc bằng root)
Log: /var/log/doctbase/install.log
State: /var/lib/doctbase/state.json
```

- Dashboard: `https://admin.<domain>/` khi có domain.
- Local mode: dùng SSH tunnel tới `/run/doctbase/management.sock`.
- Không lệnh nào in giá trị secret.

## Idempotency, resume và rollback

- Mỗi bước đều idempotent: secret đã có được giữ nguyên, cluster đã có được
  dùng lại, file managed chỉ ghi khi khác nội dung, config của người dùng
  không bị ghi đè.
- Nếu lần cài bị gián đoạn, chạy lại cùng lệnh. State file ghi tiến độ từng
  bước; các bước đã hoàn tất sẽ được kiểm tra lại thay vì tạo trùng.
- Nếu một bước lỗi, installer dừng, log lỗi kèm mã (ví dụ
  `DATABASE_SETUP_FAILED`) và rollback các tài nguyên **do lần chạy đó tạo**:
  unit/process, file generated, thư mục, user/group và cluster. Tài nguyên có
  trước đó không bị xóa.
- `/run/doctbase/install.lock` ngăn hai installer chạy song song; lock tự nhả
  khi process thoát.
- `state.json` lưu version component (PostgreSQL, PgBouncer, Caddy) để `doctor`
  đối chiếu sau này.

## Bảo mật

- PostgreSQL và PgBouncer không mở TCP; chỉ Unix socket. Caddy là thành phần
  duy nhất bind 80/443 và chạy bằng user riêng với `CAP_NET_BIND_SERVICE`.
- Secret nằm ngoài image/config, mode `0600`, owner `root:doctbase`; service
  nhận internal token qua `LoadCredential`, không qua environment.
- Caddy admin API dùng Unix socket, không mở cổng 2019.
- Log installer chỉ ghi tên bước và mã lỗi, không ghi giá trị secret.

## Giới hạn hiện tại

- Chưa có script cài một dòng (`deploy/native/install.sh` vẫn là placeholder).
- Chưa có setup flow/admin bootstrap trong Management API; setup token đã được
  sinh nhưng chưa có endpoint xác thực.
- Chưa có `project create`, `uninstall`, `repair` và external database/proxy.
- Chưa hỗ trợ nhiều replica hoặc HA.

Xem thêm [Troubleshooting](troubleshooting.md), [Configuration reference](config-reference.md)
và [Upgrade](upgrade.md).
