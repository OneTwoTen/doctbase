# Contract: Biến môi trường cho Docker/Coolify mode

**Feature**: `specs/002-coolify-resource`

Contract này mô tả bề mặt cấu hình của image production và compose resource. Mọi biến **MUST** có default trừ khi ghi rõ "bắt buộc". Không đổi tên biến mà không cập nhật `docs/coolify.md` và compose.

## 1. Biến do nền tảng cung cấp

| Biến | Bắt buộc | Sinh bởi | Dùng cho |
|---|---|---|---|
| `SERVICE_PASSWORD_64_INTERNALTOKEN` | Có (hoặc đặt tay) | Coolify magic var | Token nội bộ; compose map sang `DOCTBASE_INTERNAL_TOKEN`. |
| `SERVICE_PASSWORD_64_POSTGRES` | Chỉ profile `bundled` | Coolify magic var | Mật khẩu PostgreSQL/PgBouncer. |
| `SERVICE_FQDN_GATEWAY_8080` | Không | Coolify magic var | Tạo domain cho gateway, route port 8080. |
| `SERVICE_FQDN_MANAGEMENT_8081` | Không | Coolify magic var | Tạo domain cho management, route port 8081. |
| `COMPOSE_PROFILES` | Không | Người dùng/Coolify | `bundled` (postgres + pgbouncer), `optional` (service tùy chọn). |

Không có secret nào có giá trị mặc định trong image hoặc compose.

## 2. Biến do compose đặt cho container

| Biến | Bắt buộc | Default | Ý nghĩa |
|---|---|---|---|
| `DOCTBASE_MODE` | Có | `docker` (trong compose) | Chọn mode runtime; `docker` bắt buộc config file tồn tại. |
| `DOCTBASE_CONFIG` | Không | `/etc/doctbase/doctbase.toml` | Đường dẫn config được sinh. |
| `DOCTBASE_CONFIG_MANAGED` | Không | `1` | `1` = render config từ env; `0` = dùng file mount. |
| `DOCTBASE_LISTEN` | Có | — | `host:port` IPv4; Docker dùng `0.0.0.0:<port>`. |
| `DOCTBASE_HTTP_PORT` | Không | `8080` | Cổng dùng cho healthcheck nội bộ. |
| `DOCTBASE_INTERNAL_TOKEN` | Có | — | Token cho endpoint `/internal/v1/*`. |
| `DOCTBASE_INSTANCE_NAME` | Không | `doctbase` | `[instance].name`. |
| `DOCTBASE_DOMAIN` | Không | rỗng | `[instance].domain`. |
| `DOCTBASE_ADMIN_EMAIL` | Không | rỗng | `[instance].admin_email`. |
| `DOCTBASE_PROXY_MODE` | Không | `external` | `[proxy].mode`; `external` khi đứng sau proxy nền tảng. |
| `DOCTBASE_DATABASE_MODE` | Không | `external` | `[database].mode`: `managed` hoặc `external`. |
| `DOCTBASE_LOG_LEVEL` | Không | `info` | `[logging].level`. |
| `DOCTBASE_SERVICE_AUTH` | Không | `true` | `[services].auth`. |
| `DOCTBASE_SERVICE_STORAGE` | Không | `true` | `[services].storage`. |
| `DOCTBASE_SERVICE_PG_META` | Không | `true` | `[services].pg_meta`. |
| `DOCTBASE_SERVICE_REST` | Không | `false` | `[services].rest`. |
| `DOCTBASE_SERVICE_REALTIME` | Không | `false` | `[services].realtime`. |
| `DOCTBASE_SERVICE_IMAGE_PROXY` | Không | `false` | `[services].image_proxy`. |
| `DOCTBASE_POOLER_ENABLED` | Không | `false` | `[pooler].enabled`; bật khi dùng profile `bundled`. |

## 3. Mapping sang `doctbase.toml`

`deploy/docker/entrypoint.sh` sinh file theo thứ tự:

```toml
schema_version = 1

[instance]        # DOCTBASE_INSTANCE_NAME, DOCTBASE_DOMAIN, DOCTBASE_ADMIN_EMAIL
[database]        # DOCTBASE_DATABASE_MODE
[pooler]          # DOCTBASE_POOLER_ENABLED
[proxy]           # DOCTBASE_PROXY_MODE, tls = "off"
[services]        # DOCTBASE_SERVICE_*
[logging]         # DOCTBASE_LOG_LEVEL, format = "json"
```

Giá trị được ghi nguyên văn từ env; không có escape TOML. Không đặt giá trị chứa dấu `"` hoặc xuống dòng trong các biến này.

## 4. Ràng buộc

- `DOCTBASE_LISTEN` chỉ chấp nhận IPv4 literal `host:port`; IPv6 chỉ khi dùng dạng literal có `:` (ví dụ `::1:8080` không được hỗ trợ — dùng IPv4 trong V1).
- Không publish cổng: compose chỉ dùng `expose`.
- `management` chỉ nên gán domain sau khi đã có xác thực admin và (tùy chọn) IP allowlist.
- Thay đổi tên biến là thay đổi contract: cập nhật file này, `docs/coolify.md`, compose và test CI.
