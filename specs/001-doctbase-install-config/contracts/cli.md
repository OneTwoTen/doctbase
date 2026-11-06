# Contract: `doctbase` CLI

**Feature**: `001-doctbase-install-config`  
**Version**: 1.0.0 (draft)  
**Status**: Design contract; implementation must conform.

## 1. Conventions

- Binary: `doctbase` (symlink tới `/usr/local/lib/doctbase/current/bin/doctbase`).
- Config mặc định: `/etc/doctbase/doctbase.toml`; override bằng `--config` hoặc `DOCTBASE_CONFIG`.
- Human-readable output mặc định; `--json` cho automation.
- Màu chỉ khi TTY; tôn trọng `NO_COLOR`.
- Không in secret trừ một lần khi tạo (API key, setup token), kèm cảnh báo lưu ngay.
- Mọi lệnh thay đổi trạng thái MUST hỗ trợ `--dry-run` nếu có thể; MUST idempotent.
- Không interactive khi stdin không phải TTY, trừ khi có `--yes`/`--non-interactive`; nếu thiếu dữ liệu bắt buộc, fail với hướng dẫn.

## 2. Global flags

| Flag | Ý nghĩa |
|------|---------|
| `--config <path>` | Đường dẫn config |
| `--json` | Output JSON machine-readable |
| `--yes`, `-y` | Không hỏi xác nhận |
| `--dry-run` | Hiển thị thay đổi, không ghi |
| `--verbose`, `-v` | Log chi tiết |
| `--no-color` | Tắt màu |
| `--timeout <duration>` | Timeout cho lệnh |
| `--version` | In version |
| `--help` | Trợ giúp |

## 3. Exit codes

| Code | Ý nghĩa |
|------|---------|
| 0 | Thành công |
| 1 | Lỗi chung |
| 2 | Dùng sai CLI/config |
| 3 | Preflight fail |
| 4 | Network/download fail |
| 5 | Database fail |
| 6 | Service/lifecycle fail |
| 7 | Migration fail |
| 8 | Permission fail |
| 9 | Health check fail |
| 10 | Cancelled/rolled back |

## 4. Command surface

### 4.1. Install / init

**Golden path (one-line):**

```bash
# Native (Linux, sudo)
curl -fsSL https://get.doctbase.dev | sudo sh -s -- --domain example.com --email admin@example.com --yes

# Docker
curl -fsSL https://get.doctbase.dev/docker | sh -s -- --domain example.com --email admin@example.com --yes
```

**Audited two-step (recommended when security policy forbids pipe-to-shell):**

```bash
curl -fsSL https://get.doctbase.dev/install.sh -o install.sh
less install.sh
sudo sh install.sh --domain example.com --email admin@example.com --yes
```

**Explicit CLI path:**

```bash
doctbase install [--domain <host>] [--email <email>] [--yes] [--dry-run]
                 [--proxy caddy|external|none] [--firewall] [--offline <bundle>]

doctbase init [--profile native|docker] [--dir <path>] [--domain <host>] [--email <email>]
doctbase up [--profile ...]
doctbase dev [--profile minimal|standard|full]
```

- `install`: cài hệ thống native; preflight, package, cluster, secrets, units, health.
- `init`: tạo config/dev environment; không thay đổi hệ thống.
- `up`: khởi động native target hoặc Docker Compose tùy mode.
- `dev`: chạy foreground cho phát triển; không dùng production.
- `--domain`/`--email` optional; thiếu domain → local mode.
- `--dry-run` in plan: package, user/dir, port, file, service, thay đổi firewall.
- Exit 3 nếu preflight fail; 5 nếu DB; 6 nếu service; 9 nếu health.

### 4.2. Lifecycle

```bash
doctbase up [service...]
doctbase down [service...]
doctbase restart [service...]
doctbase status [--json] [--watch] [--refresh]
doctbase logs [service] [-f] [--since <duration>] [--json]
```

- Native: systemd target/units; Docker: Compose. `doctbase dev` dùng `DevDriver` (foreground child process), không dùng production.
- `status` hiển thị instance, từng service, health, endpoint, version, uptime, project count, backup age, disk/memory. `--refresh` bỏ cache trạng thái.
- `logs` redact `authorization`, `apikey`, `password`, `token`, `secret`; nguồn là journald/Compose driver.
- `--watch` refresh mỗi 2 giây (TTY); non-TTY chỉ in một lần.
- Mặc định `restart/up/down` chỉ áp dụng cho 8 app service. Infra service (PostgreSQL, PgBouncer, Caddy) cần `--force` + xác nhận; management API không restart infra nếu policy chưa bật.
- Mọi thao tác restart/start/stop tạo `Operation` + audit event; nếu đang có operation khác cho cùng service, trả lỗi `SERVICE_OPERATION_IN_PROGRESS` (exit 6 / HTTP 409).

### 4.3. Config

```bash
doctbase config validate
doctbase config show [--resolved]
doctbase config diff
doctbase config render [--output <dir>]
doctbase config explain <key>
doctbase config migrate [--dry-run]
doctbase apply [--dry-run] [--yes]
```

- `validate`: parse + schema + semantic checks; exit 2 nếu lỗi.
- `show --resolved`: in giá trị sau defaults/env/CLI.
- `diff`: so sánh desired vs running.
- `render`: in generated artifacts (Caddyfile, pgbouncer.ini, projects.json, units) ra stdout hoặc thư mục.
- `apply`: render → validate → atomic write → reload/restart → migrate nếu cần → health; rollback on failure.
- `apply` không thay đổi nếu không có diff; exit 0.

### 4.4. Project

```bash
doctbase project create <slug> [--name <name>] [--domain <host>]
                        [--services auth,storage,rest] [--origin <url>...]
doctbase project list [--json]
doctbase project show <slug> [--json]
doctbase project delete <slug> [--purge] [--yes]
doctbase project rotate-key <slug> [--type publishable|secret] [--grace 24h]
doctbase project export [<slug>|--all] [--output <file>]
doctbase project import <file> [--yes]
```

- `create`: tạo DB/role/key/domain/routes; in URL + publishable/secret key một lần; ≤ 10 giây.
- `delete`: mặc định disable + giữ data; `--purge` yêu cầu xác nhận + backup.
- `rotate-key`: key cũ retiring trong grace period; key mới in một lần.
- `export`: TOML/JSON không chứa secret; `import` sinh secret mới hoặc đọc từ file.

### 4.5. Domain / secret / admin

```bash
doctbase domain add <host> --project <slug>
doctbase domain remove <host>
doctbase domain status [<host>]

doctbase secret ls
doctbase secret rotate <name>
doctbase secret show <name> --reveal

doctbase admin reset-password
doctbase admin reset-setup
```

- `domain add` kiểm tra DNS, hiển thị bản ghi cần tạo, reload Caddy.
- `secret show --reveal` yêu cầu xác nhận; không log.
- `admin reset-setup` tạo setup token mới, hết hạn 30 phút.

### 4.6. Backup / restore / upgrade

```bash
doctbase backup [--to <dir>] [--scope instance|project] [--project <slug>]
                [--include-secrets] [--encrypt <recipient>]
doctbase restore <backup-path> [--project <slug>] [--force] [--yes]
doctbase upgrade --check
doctbase upgrade [--to <version>] [--major] [--yes]
doctbase upgrade --rollback
doctbase uninstall [--keep-data|--purge] [--yes]
```

- `backup`: control DB + project DBs + storage + auth keys + config + manifest/checksum; default local.
- `restore`: verify version/checksum; refuse overwrite without `--force`; stop/start services.
- `upgrade`: backup first, migration lock, health check, rollback.
- `uninstall`: keep data default; `--purge` requires typed confirmation.

### 4.7. Doctor / support

```bash
doctbase doctor [--fix] [--json]
doctbase support bundle [--output <file>]
doctbase completion <shell>
```

- `doctor`: checks OS, systemd, RAM/disk, ports, DNS, TLS, DB, PgBouncer, Caddy, services, config drift, secrets perms, backup age, firewall, version.
- `--fix`: only safe fixes (dirs, perms, reload, restart failed service, re-render); never destructive.
- `support bundle`: redacted config, versions, health, logs (last N), systemd/compose status, disk/memory; no secrets.

## 5. JSON output contract

Success:

```json
{
  "ok": true,
  "data": {},
  "meta": {
    "version": "1.0.0",
    "request_id": "01J...",
    "duration_ms": 123
  }
}
```

Error:

```json
{
  "ok": false,
  "error": {
    "code": "DB_CONN_REFUSED",
    "message": "Không kết nối được PostgreSQL qua Unix socket.",
    "cause": "cluster doctbase chưa chạy",
    "fix": "sudo systemctl start postgresql@18-doctbase",
    "docs_url": "https://doctbase.dev/errors/DB_CONN_REFUSED",
    "request_id": "01J..."
  }
}
```

- `error.code` stable, UPPER_SNAKE_CASE.
- `error.fix` actionable; `docs_url` optional but recommended.
- Không có secret trong bất kỳ field nào.

## 6. Output examples

### Install

```text
[1/9] Preflight ........................ OK (Ubuntu 24.04, 2 vCPU, 2 GB)
[2/9] Packages ......................... OK (PostgreSQL 18, PgBouncer, Caddy)
[3/9] Users/directories ................ OK
[4/9] Secrets .......................... OK
[5/9] PostgreSQL cluster ............... OK
[6/9] PgBouncer ........................ OK
[7/9] Caddy + TLS ...................... OK
[8/9] Services ......................... OK (8/8 ready)
[9/9] Health ........................... OK

Doctbase 1.0.0 ready in 3m 42s.
Dashboard: https://admin.example.com/setup#token=<one-time>
Next: doctbase project create myapp --services auth,storage,rest
```

### Status

```text
Doctbase 1.0.0  healthy  uptime 2h14m
Domain: example.com   Mode: native   Data: /var/lib/doctbase

SERVICE      STATE    HEALTH  ENDPOINT                              VERSION
postgresql   running  ready   unix:/var/run/postgresql              18.6
pgbouncer    running  ready   unix:/run/doctbase/pgbouncer.sock      1.24
caddy        running  ready   :443                                   2.10
gateway      running  ready   unix:/run/doctbase/gateway.sock
management   running  ready   https://admin.example.com
auth         running  ready   unix:/run/doctbase/auth.sock
storage      running  ready   unix:/run/doctbase/storage.sock
pg-meta      running  ready   unix:/run/doctbase/pg-meta.sock
rest         off      -       -                                      optional
realtime     off      -       -                                      optional
image-proxy  off      -       -                                      optional

PROJECTS 3   LAST BACKUP 6h ago   DISK 12.4/40 GB   MEM 612 MB
```

### Doctor

```text
[✓] OS/arch: Ubuntu 24.04, x86_64
[✓] systemd: 255
[✓] PostgreSQL cluster: running, 18.6
[✓] PgBouncer: running, auth_query OK
[✓] Caddy: running, admin API OK
[✓] TLS: certificate valid, 89 days left
[✓] Services: 8/8 ready
[✓] Config: valid, no drift
[✓] Secrets: permissions OK
[!] Backup: last backup 6 days ago
    fix: sudo doctbase backup
1 warning, 0 errors.
```

## 7. Compatibility

- CLI flags/exit codes/JSON `error.code` là public contract; thay đổi phá vỡ phải qua major version.
- `--json` schema có `schema_version` trong `meta` khi cần mở rộng.
- Command mới có thể thêm; command cũ không bị xóa trong minor version.
- Hidden aliases có thể tồn tại nhưng không được tài liệu hóa như public API.
