# Cài đặt native trên Linux

Tài liệu này mô tả luồng `doctbase install` trên một VPS Debian 13 hoặc
Ubuntu 24.04/26.04 (x86_64/arm64). Đây là golden path native; Docker/Coolify là
đường tùy chọn và có tài liệu riêng.

> **Trạng thái slice hiện tại**: orchestration, state file, lock, rollback,
> health verification, summary, `repair`, `uninstall`, admin setup token
> (T050), signed bootstrap installer (T053) và đường Docker
> `init --profile docker`/`up` đã có. `project create` (US2) là slice tiếp theo.

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

### Một lệnh (release)

```sh
curl -fsSL https://get.doctbase.dev | sudo sh -s -- \
  --domain example.com --email admin@example.com --yes
```

Bootstrap tải manifest đã ký, xác minh chữ ký Ed25519 và SHA-256 của artifact,
giải nén, cài CLI rồi chạy `doctbase install`. Public key release được truyền
qua `--pubkey`/`DOCTBASE_RELEASE_PUBKEY_FILE`; release pipeline chịu trách nhiệm
ký manifest (T140/T141). Với chế độ audit hai bước:

```sh
curl -fsSL https://get.doctbase.dev/install.sh -o install.sh
less install.sh
sudo sh install.sh --domain example.com --email admin@example.com --yes
```

Có thể kiểm tra trước mà không thay đổi host:

```sh
sh install.sh --manifest /path/manifest.json --artifact /path/bundle.tar.gz \
  --pubkey /path/release-pub.pem --dry-run
```

Với gói release đã cài sẵn (asset mặc định nằm dưới
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

## Tạo admin bằng setup token

Installer sinh `admin_setup_token` (256-bit, hết hạn sau 30 phút) và một file
metadata không chứa secret tại `/var/lib/doctbase/control/setup.json` (chỉ hash
SHA-256 + deadline). Management đọc hash này, nên token dùng một lần và không bị
mở lại sau restart. Sau khi admin tồn tại, setup đóng vĩnh viễn.

- Có domain: mở `https://admin.<domain>/setup`, nhập token đọc bằng root từ
  `/etc/doctbase/secrets/admin_setup_token`, email và password ≥ 12 ký tự.
- Local mode: dùng SSH tunnel tới management socket rồi gọi `POST /setup` (xem
  `tests/e2e/install-ubuntu.sh` để biết ví dụ curl), hoặc chờ dashboard setup
  page ở slice US2.
- Token hết hạn: chạy lại `doctbase repair --yes` **không** gia hạn token cũ;
  dùng `doctbase admin reset-setup` khi command này được bổ sung (T135).

Admin hiện được lưu tại `/var/lib/doctbase/control/admin.json` (Argon2id,
mode `0600`) cho tới khi repository control DB thay thế; không có mật khẩu mặc
định và không ghi secret vào log.

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

## Repair / reinstall

`repair` là cách khôi phục một instance đã cài mà không mất dữ liệu:

```sh
sudo doctbase repair --dry-run
sudo doctbase repair --yes
sudo doctbase repair --domain example.com --yes
```

- Yêu cầu `/var/lib/doctbase/state.json` đã có; host chưa cài phải dùng
  `doctbase install`.
- Chạy lại đúng chuỗi bước idempotent của installer: adopt user/secret/cluster
  đã có, render lại unit/file generated khi lệch, copy binary, start service và
  kiểm tra health.
- `domain`/`email` mặc định lấy từ state; nếu truyền `--domain`/`--email` thì
  giá trị mới được dùng để render và ghi lại vào state.
- Preflight coi 80/443 là do Doctbase quản lý **chỉ khi** unit
  `doctbase-caddy.service` đang active; nếu dịch vụ khác chiếm port, repair vẫn
  bị chặn.
- Không ghi đè `/etc/doctbase/doctbase.toml` đã có, không rotate secret, không
  xóa project database, storage, auth key hay backup.
- Nếu một bước lỗi, rollback chỉ xóa tài nguyên **do lần repair đó tạo**; dữ
  liệu có trước đó được giữ nguyên.

## Gỡ cài đặt

Mặc định `uninstall` giữ cấu hình và dữ liệu để có thể cài lại:

```sh
sudo doctbase uninstall            # hỏi xác nhận y/N
sudo doctbase uninstall --yes
sudo doctbase uninstall --purge    # bắt buộc gõ đúng "purge"
sudo doctbase uninstall --purge --dry-run
```

- `keep-data` (mặc định): dừng và xóa `doctbase.target`, unit service, polkit
  rule, binary dưới `/usr/local/lib/doctbase` và artifact generated. Giữ
  `/etc/doctbase` (config + secret) và `/var/lib/doctbase` (control/project
  data, auth key, backup) để lần cài sau dùng lại.
- `--purge`: làm thêm các bước trên, drop cluster PostgreSQL 18 `doctbase`,
  xóa `/etc/doctbase`, `/var/lib/doctbase`, `/var/log/doctbase`, dữ liệu
  cluster và user/group service. Xác nhận dạng gõ chữ không bị bỏ qua bởi
  `--yes`.
- `--dry-run` chỉ in kế hoạch, không cần root và không thay đổi gì.
- PostgreSQL/PgBouncer/Caddy package hệ thống **không** bị gỡ: đó là tài
  nguyên dùng chung, người vận hành quyết định gỡ bằng package manager.
- Uninstall idempotent: unit/file đã không còn được coi là thành công.

## Docker mode (tùy chọn)

Docker không phải điều kiện của native mode. Có hai đường Docker:

### Standalone (`init --profile docker` + `up`)

Dùng khi bạn tự chạy Docker Compose trên VPS; Caddy trong stack công khai
80/443 và tự lấy TLS.

```sh
doctbase init --profile docker --dir /opt/doctbase \
  --domain example.com --email admin@example.com \
  --database external \
  --assets /usr/local/lib/doctbase/current/share

doctbase up --profile docker --dir /opt/doctbase
```

`init` sinh trong `--dir`:

| File | Nội dung |
|------|----------|
| `compose.yml` | gateway, management, Caddy; profile `optional` (auth) và `bundled` (PostgreSQL 18 + PgBouncer) |
| `Caddyfile` | reverse proxy về management; `:80` khi không có domain |
| `.env` | version/image prefix, domain, database mode, secret 256-bit mode `0600` |

- Chạy lại `init` là idempotent: secret đã sinh không bao giờ bị ghi đè; các
  key cấu hình (`DOCTBASE_VERSION`, domain, database mode, ...) được cập nhật
  theo cờ mới và key thiếu được bổ sung. `compose.yml`/`Caddyfile` là generated
  artifact và được render lại.
- `--dry-run` in kế hoạch, không tạo file, không generate secret.
- `--database bundled` đặt `DOCTBASE_DATABASE_MODE=managed` và
  `COMPOSE_PROFILES=bundled`. Mặc định là `external`.
- Core service không publish port; chỉ Caddy publish 80/443.
- `up` kiểm tra `compose.yml` tồn tại rồi chạy
  `docker compose -f ... --env-file ... up -d --wait --wait-timeout 180`.
  Docker Compose vẫn là lifecycle owner; không có supervisor mới.
- Nâng cấp: sửa `DOCTBASE_VERSION` trong `.env` (hoặc chạy `init --version`),
  sau đó `doctbase up`. Rollback: pin version cũ và `up` lại; volume
  `doctbase-data`/`postgres-data` được giữ.
- Ảnh phải được publish ở registry. Release bundle sẽ cung cấp binary và
  template; trong repo dùng `--assets .` hoặc `deploy/docker/install.sh`.

Một lệnh trong repo/bundle hiện tại:

```sh
sh deploy/docker/install.sh --domain example.com --email admin@example.com \
  --dir /opt/doctbase --database bundled --yes
```

### Coolify / platform-managed proxy

Dùng [compose resource](coolify.md) tại `deploy/docker/compose.yml`: không
publish port, domain/TLS do Coolify/Traefik quản lý, Caddy không bật. Hai đường
này không trộn file compose với nhau.

## Bảo mật

- PostgreSQL và PgBouncer không mở TCP; chỉ Unix socket. Caddy là thành phần
  duy nhất bind 80/443 và chạy bằng user riêng với `CAP_NET_BIND_SERVICE`.
- Secret nằm ngoài image/config, mode `0600`, owner `root:doctbase`; service
  nhận internal token qua `LoadCredential`, không qua environment.
- Caddy admin API dùng Unix socket, không mở cổng 2019.
- Log installer chỉ ghi tên bước và mã lỗi, không ghi giá trị secret.

## Giới hạn hiện tại

- Chưa publish release artifacts/manifest có chữ ký tại `get.doctbase.dev`
  (T140/T141); bootstrap đã hỗ trợ manifest local và remote.
- Admin store dùng file JSON tạm thời; control DB repository sẽ thay thế.
- Chưa có `project create` và external database/proxy mode.
- Docker standalone cần ảnh `doctbase/*` đã publish; chưa có E2E pull từ
  registry trong repo này.
- Chưa hỗ trợ nhiều replica hoặc HA.

Xem thêm [Troubleshooting](troubleshooting.md), [Configuration reference](config-reference.md)
và [Upgrade](upgrade.md).
