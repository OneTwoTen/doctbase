# Triển khai Doctbase trên Coolify

Coolify là đường triển khai **tùy chọn**: Doctbase chạy như một resource kiểu Docker Compose, gồm nhiều container độc lập. Native/systemd + Caddy vẫn là golden path và không thay đổi.

## Mô hình

```text
Coolify Resource "doctbase"  (chọn repo GitHub, build pack Docker Compose)
├── gateway      -> domain api.<your-domain>     (container port 8080)
├── management   -> domain admin.<your-domain>   (container port 8081)
├── auth         (profile optional, chỉ nội bộ)
├── postgres     (profile bundled, volume postgres-data)
└── pgbouncer    (profile bundled, transaction pooling)
```

- **Một resource** trong Coolify, nhưng **nhiều container**. Mỗi service có health check, log và vòng đời riêng; Compose (Coolify) là lifecycle owner — không có supervisor tự viết trong container.
- Không container nào publish cổng. Proxy của Coolify (Traefik) sở hữu 80/443 và TLS, rồi route vào cổng nội bộ.
- Secret và domain do Coolify sinh (`SERVICE_PASSWORD_*`, `SERVICE_FQDN_*`) và giữ nguyên qua các lần deploy.

## Yêu cầu

- Coolify v4 với Docker Compose build pack và Git integration.
- Repo Doctbase (public hoặc đã kết nối GitHub App).
- Tối thiểu 4 GB RAM cho cấu hình gateway + management + database đi kèm.

## Các bước tạo resource

1. **New Resource → Docker Compose**.
2. Chọn repository và branch cần deploy.
3. Đặt:
   - **Base Directory**: `/`
   - **Docker Compose Location**: `deploy/docker/compose.yml`
4. Trong tab **Environment Variables**:
   - Để Coolify tự sinh `SERVICE_PASSWORD_64_INTERNALTOKEN` và `SERVICE_PASSWORD_64_POSTGRES` (chúng đã khai báo trong compose).
   - Đặt `DOCTBASE_DOMAIN` nếu muốn instance biết domain quản trị.
   - **Database đi kèm**: thêm `COMPOSE_PROFILES=bundled` và `DOCTBASE_DATABASE_MODE=managed`.
   - **Database ngoài**: để trống `COMPOSE_PROFILES`, đặt `DOCTBASE_DATABASE_MODE=external` và cấu hình PostgreSQL của bạn.
   - Bật service tùy chọn: `COMPOSE_PROFILES=bundled,optional`.
5. **Domains**:
   - Service `gateway` → port nội bộ **8080** (ví dụ `https://api.example.com`).
   - Service `management` → port nội bộ **8081** (ví dụ `https://admin.example.com`).
   - Không thêm port public; Coolify route qua proxy của nó.
6. **Deploy**. Khi cả `gateway` và `management` healthy, mở domain để kiểm tra.

Kiểm tra nhanh từ trong container (Coolify Terminal):

```sh
curl -fsS http://127.0.0.1:8080/readyz
curl -fsS http://127.0.0.1:8081/readyz
```

## Biến môi trường

| Biến | Bắt buộc | Default | Mô tả |
|---|---|---|---|
| `SERVICE_PASSWORD_64_INTERNALTOKEN` | Coolify tự sinh | — | Token nội bộ giữa các service. Compose map vào `DOCTBASE_INTERNAL_TOKEN`. |
| `SERVICE_PASSWORD_64_POSTGRES` | Khi dùng `bundled` | — | Mật khẩu PostgreSQL. |
| `DOCTBASE_VERSION` | Không | `dev` | Tag image build ra. |
| `DOCTBASE_DOMAIN` | Không | rỗng | Domain quản trị ghi vào config. |
| `DOCTBASE_ADMIN_EMAIL` | Không | rỗng | Email admin cho ACME (không dùng trong mode này). |
| `DOCTBASE_PROXY_MODE` | Không | `external` | `external` khi đứng sau proxy của Coolify. |
| `DOCTBASE_DATABASE_MODE` | Không | `external` | `managed` khi dùng profile `bundled`. |
| `DOCTBASE_LOG_LEVEL` | Không | `info` | `debug`, `info`, `warn`, `err`. |
| `COMPOSE_PROFILES` | Không | rỗng | `bundled` bật PostgreSQL + PgBouncer; `optional` bật service tùy chọn. |

Biến nội bộ khác (`DOCTBASE_LISTEN`, `DOCTBASE_HTTP_PORT`, `DOCTBASE_CONFIG`, `DOCTBASE_CONFIG_MANAGED`) đã đặt sẵn trong compose, không cần chỉnh.

Chi tiết hợp đồng: [`specs/002-coolify-resource/contracts/env.md`](../specs/002-coolify-resource/contracts/env.md).

## Config được sinh như thế nào

Image chạy `deploy/docker/entrypoint.sh`: mỗi lần container khởi động, script ghi `/etc/doctbase/doctbase.toml` từ biến môi trường, rồi `exec` service. File này là **generated artifact** — không sửa tay.

Muốn giữ config riêng: đặt `DOCTBASE_CONFIG_MANAGED=0` và mount file của bạn vào `/etc/doctbase/doctbase.toml`.

## Nâng cấp và rollback

- **Nâng cấp**: deploy commit mới trong Coolify. Image được build lại; volume `doctbase-data` (và `postgres-data` nếu bundled) được giữ nguyên.
- **Rollback**: dùng tính năng rollback/deploy lại commit cũ của Coolify. Không xoá volume; không chạy migration hai lần.
- Trước khi nâng cấp production: backup theo quy trình backup/restore của feature 001 (cùng schema PostgreSQL).

## Chạy thử cục bộ (không cần Coolify)

```sh
cd deploy/docker
cp .env.example .env
docker compose --env-file .env -f compose.yml up --build gateway management
```

Kiểm tra:

```sh
docker compose -f compose.yml exec gateway curl -fsS http://127.0.0.1:8080/healthz
docker compose -f compose.yml exec management curl -fsS http://127.0.0.1:8081/healthz
docker compose -f compose.yml down
```

## Giới hạn của slice hiện tại

- `gateway` và `management` mới là skeleton: health/ready/metrics hoạt động qua TCP, nhưng dashboard static chưa được nhúng vào management và các API nghiệp vụ là feature follow-on.
- Profile `bundled` tạo PostgreSQL 18 + PgBouncer sẵn sàng, nhưng **service chưa kết nối database** cho đến khi feature DB/provisioning được triển khai.
- Một replica mỗi service; không hỗ trợ scale ngang hoặc HA.
- Không tự di trú dữ liệu giữa native và Coolify.
- `auth` là service tùy chọn mẫu để chứng minh bật/tắt; các service tùy chọn khác thêm dần.

## Bảo mật

- Không publish cổng nội bộ; chỉ proxy của Coolify nhận traffic.
- Image chạy user `doctbase` (uid 10001), không phải root, không chứa secret.
- `management` yêu cầu xác thực; chỉ gán domain khi đã cấu hình admin và cân nhắc IP allowlist.
- Token nội bộ do Coolify sinh và persist; không dùng giá trị mặc định trong `.env.example` cho production.

## Xử lý sự cố

| Triệu chứng | Kiểm tra |
|---|---|
| Container restart liên tục | Log container; thường do `DOCTBASE_LISTEN` sai định dạng hoặc config không parse được. |
| `internal token is required` khi deploy | Chưa có `SERVICE_PASSWORD_64_INTERNALTOKEN`; để Coolify sinh hoặc đặt trong Environment Variables. |
| Domain trả 502 | Domain phải gắn đúng service và port nội bộ (8080/8081); container phải healthy. |
| Database không nhận kết nối | Profile `bundled` phải bật **và** `DOCTBASE_DATABASE_MODE=managed`; xem health của `postgres`/`pgbouncer`. |
| 401 khi gọi `/internal/v1/info` | Đúng thiết kế: endpoint nội bộ cần `Authorization: Bearer $DOCTBASE_INTERNAL_TOKEN`. |

## Liên quan

- [Spec](../specs/002-coolify-resource/spec.md) · [Plan](../specs/002-coolify-resource/plan.md) · [Tasks](../specs/002-coolify-resource/tasks.md)
- [Amendment external proxy](../.specify/memory/amendments/2026-11-06-external-proxy-coolify.md)
- [Phát triển, build và test](development.md)
