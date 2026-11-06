# Contract: Instance Configuration (TOML)

**Feature**: `001-doctbase-install-config`  
**Version**: 1.0.0 (draft)  
**Status**: Design contract; implementation must conform.

## 1. File and precedence

- Path mặc định: `/etc/doctbase/doctbase.toml`.
- Override: `--config <path>` (CLI) hoặc `DOCTBASE_CONFIG` (env).
- Quyền: `0640 root:doctbase`; không chứa secret.
- Precedence: **CLI flag > env > TOML > auto-detected default**.
- Project settings không nằm trong file này; project state nằm trong control DB và được quản lý qua CLI/API/dashboard.
- Unknown key → error (không bỏ qua), kèm gợi ý key gần đúng.

## 2. Schema

```toml
schema_version = 1

[instance]
name = "doctbase"
domain = "example.com"          # optional; empty => local mode
admin_email = "admin@example.com" # optional; ACME email
timezone = "Asia/Ho_Chi_Minh"

[database]
mode = "managed"                # managed | external
max_connections = 200
# url_file = "/etc/doctbase/secrets/database_url"  # only for external

[pooler]
enabled = true
pool_mode = "transaction"
default_pool_size = 10
max_client_conn = 1000

[proxy]
mode = "caddy"                  # caddy | external | none
tls = "auto"                    # auto | internal | off | custom
# custom_cert = "/etc/doctbase/secrets/tls.crt"
# custom_key  = "/etc/doctbase/secrets/tls.key"

[services]
auth = true
storage = true
pg_meta = true
rest = false
realtime = false
image_proxy = false

[storage]
backend = "local"               # local | s3
max_upload = "50MB"
# s3_endpoint = "..."
# s3_bucket = "..."

[backup]
enabled = true
schedule = "03:00"              # local time
retain_daily = 7
retain_weekly = 4
# destination = "/mnt/backups/doctbase"
# encrypt = true

[logging]
level = "info"                  # debug | info | warn | error
format = "json"                 # json | text

[security]
admin_ip_allowlist = []
session_ttl = "24h"
default_rate_limit = "600/min"
```

## 3. Keys and defaults

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `schema_version` | int | 1 | Bắt buộc; migrate khi tăng |
| `instance.name` | string | `doctbase` | |
| `instance.domain` | string | `""` | Empty → local mode |
| `instance.admin_email` | string | `""` | ACME email optional |
| `instance.timezone` | IANA tz | system tz | Hiển thị log/backup |
| `database.mode` | enum | `managed` | `external` cần `url_file` |
| `database.max_connections` | int | 200 | 50–1000; auto tune nếu không đặt |
| `database.url_file` | path | — | Chỉ external; secret file |
| `pooler.enabled` | bool | true | |
| `pooler.pool_mode` | enum | `transaction` | V1 chỉ transaction |
| `pooler.default_pool_size` | int | 10 | 1–50 |
| `pooler.max_client_conn` | int | 1000 | |
| `proxy.mode` | enum | `caddy` | `none` cho local |
| `proxy.tls` | enum | `auto` | `internal` dev, `off` external LB |
| `proxy.custom_cert` | path | — | Khi `tls=custom` |
| `proxy.custom_key` | path | — | Khi `tls=custom` |
| `services.*` | bool | core true, optional false | Instance-level |
| `storage.backend` | enum | `local` | `s3` optional |
| `storage.max_upload` | size | `50MB` | Parse `KB/MB/GB` |
| `backup.enabled` | bool | true | |
| `backup.schedule` | `HH:MM` | `03:00` | Local time |
| `backup.retain_daily` | int | 7 | |
| `backup.retain_weekly` | int | 4 | |
| `backup.destination` | path | local | Offsite via rclone/restic |
| `backup.encrypt` | bool | false | Offsite khuyến nghị true |
| `logging.level` | enum | `info` | |
| `logging.format` | enum | `json` | |
| `security.admin_ip_allowlist` | string[] | `[]` | CIDR/IP |
| `security.session_ttl` | duration | `24h` | |
| `security.default_rate_limit` | string | `600/min` | Per project/IP |

## 4. Environment overrides

Chỉ các biến sau được hỗ trợ chính thức (curated, không map toàn bộ TOML):

| Env | Ý nghĩa |
|-----|---------|
| `DOCTBASE_CONFIG` | Đường dẫn config |
| `DOCTBASE_DATA_DIR` | Override data dir (dev/test) |
| `DOCTBASE_DOMAIN` | Override domain (install) |
| `DOCTBASE_ACME_EMAIL` | Override ACME email |
| `DOCTBASE_LOG_LEVEL` | Override log level |
| `DOCTBASE_NO_COLOR` | Tắt màu |
| `DOCTBASE_YES` | Non-interactive |
| `DOCTBASE_DATABASE_URL_FILE` | External DB URL file |

Không hỗ trợ nested env cho mọi key để tránh ambiguity. Secret dùng `*_FILE`/credential, không dùng env trực tiếp.

## 5. Secrets

- Không có secret trong TOML.
- Native: systemd credentials (`LoadCredential=`), path trong `$CREDENTIALS_DIRECTORY`.
- Docker: Compose secrets, mount `/run/secrets/<name>`.
- Secret files: `0600` (hoặc `0640` với group hẹp), owner service tương ứng.
- Các secret chính:
  - `postgres_admin`
  - `pgbouncer_auth`
  - `internal_token`
  - `admin_setup_token`
  - JWT private keys do auth service sở hữu (không nằm trong `/etc/doctbase/secrets`).
- `doctbase secret rotate` cập nhật secret + restart service liên quan; JWT key rotation có grace period.

## 6. Generated artifacts

Các file sau được render từ TOML + control DB; **không sửa tay**:

```text
/etc/doctbase/generated/Caddyfile
/etc/doctbase/generated/pgbouncer.ini
/etc/doctbase/generated/projects.json
/etc/doctbase/generated/services.env
/etc/systemd/system/doctbase-*.service
/etc/systemd/system/doctbase.target
```

Header bắt buộc:

```text
# Generated by doctbase <version>. DO NOT EDIT.
# Source: /etc/doctbase/doctbase.toml + control database.
# Apply:  sudo doctbase apply
```

- `config render` in ra stdout hoặc thư mục staging.
- `apply` ghi atomic (temp + rename), backup bản cũ, reload/restart, rollback nếu fail.
- Drift detection: so sánh checksum generated file với `state.json`; `doctor` báo `CONFIG_DRIFT`.

## 7. Validation rules

- `schema_version` bắt buộc; version cao hơn binary → lỗi, yêu cầu upgrade.
- `instance.domain`: lowercase, valid DNS, không wildcard, không IP (trừ local mode).
- `database.mode=external` ⇒ `database.url_file` tồn tại, đọc được, không phải symlink ra ngoài.
- `proxy.mode=caddy` không hợp lệ nếu Caddy không được cài/bật.
- `proxy.tls=custom` ⇒ cả `custom_cert` và `custom_key` tồn tại, cert/key khớp.
- `services.realtime=true` yêu cầu `auth=true` nếu private channel bật.
- `services.rest=true` yêu cầu `pg_meta=true`.
- `services.image_proxy=true` yêu cầu `storage=true`.
- `backup.schedule` đúng `HH:MM` 24h; retention ≥ 0.
- `security.admin_ip_allowlist` là CIDR/IP hợp lệ; rỗng = không giới hạn.
- Size/duration parse theo đơn vị; reject giá trị âm/overflow.

## 8. Apply semantics

```text
load + validate
  → load control DB state
  → render staging
  → diff current
  → if no diff: exit 0
  → backup current
  → atomic write
  → validate Caddyfile
  → reload Caddy (admin API)
  → reload PgBouncer (SIGHUP/systemd reload)
  → restart services whose config_hash changed
  → run migrations if needed
  → health check
  → on failure: restore artifacts + reload + report
```

- Lock: `/run/doctbase/apply.lock` (flock).
- `--dry-run`: render + diff only.
- `--yes`: non-interactive.
- Idempotent: no diff → no reload/restart.

## 9. Example: minimal config

```toml
schema_version = 1

[instance]
domain = "example.com"
admin_email = "admin@example.com"
```

Mọi key khác lấy default. Nếu không có domain:

```toml
schema_version = 1
```

→ local mode, dashboard qua SSH tunnel; có thể thêm domain sau bằng `doctbase domain add`.

## 10. Example: external PostgreSQL

```toml
schema_version = 1

[database]
mode = "external"
url_file = "/etc/doctbase/secrets/database_url"

[pooler]
enabled = false
```

- `database_url` chứa connection string, quyền `0600`, owner `doctbase-management`.
- Doctbase không tạo cluster/role; chỉ chạy migration và kiểm tra version.
- `doctor` kiểm tra quyền, extension, `max_connections`, `pgbouncer` nếu dùng.

## 11. Versioning

- `schema_version` tăng khi có thay đổi không tương thích.
- `doctbase config migrate` backup file, chuyển đổi, validate, ghi atomic.
- Minor version có thể thêm key optional với default; không được thêm key bắt buộc.
- Major version có thể đổi semantics; phải có migration + release notes.
