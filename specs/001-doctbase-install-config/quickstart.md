# Quickstart Validation Guide: Doctbase V1 Foundation

**Feature**: `001-doctbase-install-config`  
**Date**: 2026-11-06  
**Purpose**: Kịch bản chạy được để chứng minh feature hoạt động end-to-end. Đây là **validation guide** cho implementation, không phải code đã tồn tại.

## 1. Prerequisites

- VPS/VM sạch: Ubuntu 24.04 LTS, 2 vCPU, 2 GB RAM, ≥ 20 GB disk.
- Quyền `sudo`/root.
- Domain (optional): `example.com`; DNS:
  - `A admin.example.com -> <VPS-IP>`
  - `A *.example.com -> <VPS-IP>` (hoặc từng project host)
- Port 80/443 trống.
- Clock sync (NTP).

> Không có domain vẫn chạy được ở local mode; dashboard qua SSH tunnel.

## 2. Native install

**One-line golden path:**

```bash
curl -fsSL https://get.doctbase.dev | sudo sh -s -- \
  --domain example.com --email admin@example.com --yes
```

**Audited two-step (recommended nếu chính sách bảo mật cấm pipe-to-shell):**

```bash
curl -fsSL https://get.doctbase.dev/install.sh -o install.sh
less install.sh
sudo sh install.sh --domain example.com --email admin@example.com --yes
```

**Expected**:

- Progress 9 bước, không lỗi.
- Kết thúc trong ≤ 5 phút.
- In ra dashboard URL + setup token một lần.
- `sudo doctbase status` báo `healthy`.

**Kiểm tra**:

```bash
sudo doctbase status
sudo doctbase doctor
```

- Tất cả service bắt buộc `ready`.
- `doctor` 0 error (warning backup có thể chấp nhận lần đầu).
- Chỉ 22/80/443 public; không có 5432/6432/2019.

## 3. Admin setup

Mở URL:

```text
https://admin.example.com/setup#token=<one-time>
```

Tạo admin với email + password ≥ 12 ký tự.

**Expected**:

- Setup token dùng một lần; hết hạn sau 30 phút.
- Đăng nhập dashboard thành công.
- Không có mật khẩu mặc định trong log/config.

## 4. First project

```bash
sudo doctbase project create myapp \
  --services auth,storage,rest \
  --origin https://myapp.com
```

**Expected**:

- Hoàn tất ≤ 10 giây.
- In ra:
  - `Project URL: https://myapp.example.com`
  - `Publishable key: ...`
  - `Secret key: ...` (một lần)
- Project `active`; health endpoint trả 200.

**Kiểm tra API**:

```bash
curl -fsS https://myapp.example.com/auth/v1/health
```

```json
{"status":"ok","version":"1.0.0"}
```

> Feature 001 validate provisioning/health/route. Full auth signup/login, storage API, REST CRUD, realtime và image proxy là các feature follow-on; quickstart này không yêu cầu chúng.

**Kiểm tra cô lập**:

```bash
sudo doctbase project create otherapp --services auth
curl -H "apikey: <myapp-publishable-key>" https://otherapp.example.com/auth/v1/health
# Expected: 401/403, không trả dữ liệu myapp
```

## 5. Status, logs, doctor

```bash
sudo doctbase status
sudo doctbase logs -f auth
sudo doctbase doctor
sudo doctbase doctor --json
```

**Expected**:

- `status` hiển thị service, health, endpoint, version, uptime, project count.
- `logs` redact token/password/authorization.
- `doctor` chỉ ra lỗi cụ thể + fix + docs link.
- `doctor --json` parse được, exit code 0 nếu không có fail.

## 5.1. Core Runtime & Service Manager validation

**Dev runtime** (không cần systemd):

```bash
doctbase dev --profile minimal
# terminal khác
doctbase status --refresh
curl --unix-socket /run/doctbase/gateway.sock http://localhost/healthz
curl --unix-socket /run/doctbase/gateway.sock http://localhost/readyz
```

**Expected**:

- Ít nhất 2 service chạy foreground qua `DevDriver`; log có prefix theo service.
- `/healthz` trả 200; `/readyz` trả 200 với `status=ready` hoặc `degraded` có lý do.
- `Ctrl-C` gửi SIGTERM, drain sạch, gỡ UDS, không để process con mồ côi.
- `status --json` có `source=dev`, `optional`, `unit`, `last_check_at`.

**Systemd lifecycle** (trên VM Linux):

```bash
sudo systemctl stop doctbase-auth
doctbase status --refresh          # auth = stopped/failed
sudo doctbase restart auth         # hoặc qua dashboard
doctbase status --refresh          # auth = ready
sudo doctbase logs auth | head     # không lộ secret
```

**Expected**:

- `status` phản ánh đúng systemd state; không cache quá 2 giây.
- Restart app service thành công; restart infra service bị chặn nếu thiếu `--force`.
- Viewer không restart được qua management API; audit event được ghi.
- Không có supervisor mới; systemd là lifecycle owner.

## 6. Config validation

```bash
sudo doctbase config show --resolved
sudo doctbase config validate
sudo doctbase config diff
sudo doctbase config render --output /tmp/doctbase-render
```

**Expected**:

- `show --resolved` hiển thị default + override.
- `validate` exit 0.
- `diff` không có thay đổi (empty).
- `render` tạo Caddyfile, pgbouncer.ini, projects.json, units; có header “DO NOT EDIT”.

**Thử lỗi**:

```bash
# sửa tạm một key sai
sudo sed -i 's/^auth = true/auth = "yes"/' /etc/doctbase/doctbase.toml
sudo doctbase apply
# Expected: exit 2, báo line/column, không thay đổi state
```

## 7. Backup and restore

```bash
sudo doctbase backup --scope instance
sudo doctbase status          # last backup just now
```

**Expected**:

- Backup có manifest + checksum.
- Không chứa secret mặc định (trừ khi `--include-secrets`).
- `doctor` không còn warning backup cũ.

**Restore drill** (trên VM sạch cùng version):

```bash
sudo doctbase restore /path/to/backup --force --yes
sudo doctbase status
```

**Expected**:

- Project + dữ liệu + cấu hình + auth keys được khôi phục.
- Health check pass.
- Restore 10 GB ≤ 30 phút.

## 8. Upgrade / rollback drill

```bash
sudo doctbase upgrade --check
sudo doctbase upgrade --to <next-version> --yes
sudo doctbase status
```

**Expected**:

- Backup tự động trước upgrade.
- Migration chạy dưới lock.
- Health check pass; downtime ≤ 3 phút.
- Inject lỗi migration/health → tự rollback hoặc `doctbase upgrade --rollback`.

## 9. Docker mode (optional)

**One-line golden path:**

```bash
curl -fsSL https://get.doctbase.dev/docker | sh -s -- \
  --domain example.com --email admin@example.com --yes
```

**Explicit two-step:**

```bash
curl -fsSL https://get.doctbase.dev/docker-compose.yml -o docker-compose.yml
curl -fsSL https://get.doctbase.dev/.env.example -o .env
# set DOCTBASE_DOMAIN, DOCTBASE_EMAIL
docker compose up -d
docker compose ps
```

**Expected**:

- Tất cả healthcheck pass trong ≤ 5 phút trên máy 4 GB.
- Chỉ Caddy publish 80/443.
- `docker compose exec management doctbase status` healthy.
- `docker compose --profile rest up -d` bật REST; tắt profile không ảnh hưởng core.

## 10. Uninstall

```bash
sudo doctbase uninstall --keep-data --yes
# data còn; service/config sạch
sudo doctbase uninstall --purge --yes
# xóa data/DB; không còn file Doctbase
```

**Expected**:

- `--keep-data`: `/var/lib/doctbase` còn; cài lại được.
- `--purge`: không còn cluster/DB/user/config Doctbase; không đụng PostgreSQL 5432 sẵn có.

## 11. Acceptance checklist

- [ ] Install ≤ 5 phút trên 2 vCPU/2 GB.
- [ ] First API ≤ 60 giây sau install.
- [ ] 0 file bắt buộc sửa.
- [ ] Project create ≤ 10 giây.
- [ ] Cross-project access bị từ chối.
- [ ] `status`, `logs`, `doctor` hoạt động.
- [ ] Config invalid không apply; state không đổi.
- [ ] Backup/restore drill pass.
- [ ] Upgrade/rollback drill pass.
- [ ] Docker mode pass.
- [ ] Uninstall keep-data/purge pass.
- [ ] Không secret trong log/output/support bundle.
- [ ] Chỉ 22/80/443 public.
- [ ] `doctor` phát hiện lỗi phổ biến.

## 12. Troubleshooting nhanh

| Symptom | Kiểm tra |
|---------|----------|
| Dashboard không mở | DNS A record, port 80/443, `doctbase domain status`, Caddy log |
| TLS fail | Clock, DNS, port 80/443, ACME rate limit; thử staging |
| 503 từ project | `doctbase status`, `logs`, DB/PgBouncer health |
| Apply fail | `config validate`, `config diff`, log; state giữ nguyên |
| Restore fail | Version/checksum/manifest; `doctor` |
| Disk full | `df -h`, backup/cache; dọn theo hướng dẫn |
| Permission fail | `doctor --fix` cho lỗi an toàn; kiểm tra owner/mode |

Mọi lỗi phải có `code`, `cause`, `fix`, `docs_url`.
