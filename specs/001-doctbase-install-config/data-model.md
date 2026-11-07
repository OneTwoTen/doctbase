# Phase 1 Data Model: Doctbase V1 Foundation

**Feature**: `001-doctbase-install-config`  
**Date**: 2026-11-06  
**Spec**: [spec.md](./spec.md)  
**Plan**: [plan.md](./plan.md)

Mô hình dữ liệu logic cho control plane và các thực thể vận hành. Chi tiết schema SQL, kiểu dữ liệu PostgreSQL và migration sẽ được chốt trong implementation; tài liệu này khóa **entity, quan hệ, validation và state transition** để tránh mơ hồ giữa CLI/API/dashboard.

## 1. Quan hệ tổng quan

```text
Instance 1 ─── N AdminUser
Instance 1 ─── N Project
Instance 1 ─── N Operation
Instance 1 ─── N AuditEvent
Instance 1 ─── N Backup (scope = instance)

Project 1 ─── N ProjectService
Project 1 ─── N Domain
Project 1 ─── N ApiKey
Project 1 ─── N SigningKey
Project 1 ─── N Backup (scope = project)

Operation 1 ─── 0..1 Backup
AdminUser 1 ─── N AuditEvent (actor)
Project 1 ─── N AuditEvent (target)
```

- Mọi bản ghi project-scoped MUST có `project_id`.
- `Domain` có `scope` = `instance` hoặc `project`; `project_id` NULL khi scope = instance.
- `Backup` có `scope` = `instance` hoặc `project`; backup instance bao gồm mọi project.
- `AuditEvent` là append-only; không cập nhật/xóa trong luồng thông thường.

## 2. Entities

### 2.1. Instance

Đại diện một cài đặt Doctbase trên một máy chủ.

| Field | Type (logical) | Required | Ghi chú |
|-------|----------------|----------|---------|
| `id` | ULID | Yes | Khóa chính |
| `name` | string(64) | Yes | Tên instance, mặc định `doctbase` |
| `version` | semver | Yes | Version đang chạy |
| `mode` | enum(`native`,`docker`) | Yes | Chế độ triển khai |
| `status` | enum | Yes | Xem state transitions |
| `admin_domain` | hostname | No | `admin.<domain>` nếu có domain |
| `data_dir` | path | Yes | Mặc định `/var/lib/doctbase` |
| `config_hash` | sha256 | Yes | Hash cấu hình đã apply |
| `installed_at` | timestamp UTC | Yes | |
| `updated_at` | timestamp UTC | Yes | |

**Validation**:
- `name` không rỗng, không chứa ký tự điều khiển.
- `version` khớp binary đang chạy; mismatch là lỗi `VERSION_DRIFT`.
- `admin_domain` unique toàn instance, valid DNS name.

### 2.2. AdminUser

Người dùng quản trị instance (không phải end-user của project).

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `email` | email | Yes | Unique, lowercase |
| `password_hash` | string | Yes | Argon2id |
| `role` | enum(`owner`,`admin`,`viewer`) | Yes | V1 mặc định `owner` |
| `status` | enum(`pending`,`active`,`disabled`) | Yes | |
| `setup_token_hash` | string | No | Chỉ lúc bootstrap; xóa sau dùng |
| `last_login_at` | timestamp | No | |
| `created_at` | timestamp | Yes | |
| `updated_at` | timestamp | Yes | |

**Validation**:
- Password tối thiểu 12 ký tự; không lưu plaintext.
- Setup token dùng một lần, hết hạn 30 phút.
- Không thể disable owner cuối cùng.

### 2.3. AdminSession

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | Session ID |
| `admin_user_id` | ULID FK | Yes | |
| `token_hash` | string | Yes | Hash của session token |
| `csrf_secret_hash` | string | Yes | Hash của CSRF token; raw token mirror qua cookie `doctbase_csrf` + header `X-CSRF-Token` |
| `ip` | inet | No | Audit |
| `user_agent` | string | No | Audit |
| `created_at` | timestamp | Yes | |
| `expires_at` | timestamp | Yes | Mặc định 24h |
| `revoked_at` | timestamp | No | |

- Session cookie MUST là `HttpOnly; Secure; SameSite=Lax; Path=/`; token opaque, store chỉ giữ hash.
- Mọi request không an toàn xác thực bằng cookie MUST kèm CSRF hợp lệ; internal bearer token (CLI/service) được miễn.

### 2.4. Project

Đơn vị cô lập dữ liệu và quyền truy cập.

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `slug` | string(32) | Yes | Unique, dùng trong URL |
| `name` | string(100) | Yes | Hiển thị |
| `db_name` | string(63) | Yes | Unique, generated |
| `status` | enum | Yes | Xem state transitions |
| `domain` | hostname | No | Default `<slug>.<instance-domain>` |
| `allowed_origins` | string[] | No | CORS; mặc định rỗng = deny |
| `storage_quota_bytes` | bigint | No | 0/NULL = unlimited |
| `created_at` | timestamp | Yes | |
| `updated_at` | timestamp | Yes | |
| `deleted_at` | timestamp | No | Soft delete |

**Validation**:
- `slug`: `^[a-z][a-z0-9-]{2,30}$`, không trùng reserved names (`admin`, `www`, `api`, `app`, `mail`, `status`, `doctbase`).
- `db_name`: `doctbase_<slug>_<shortid>`; ≤ 63 ký tự; an toàn cho SQL identifier (chỉ `[a-z0-9_]`).
- `domain` unique toàn instance, valid DNS, không wildcard trong V1.
- Một project chỉ có một database; không đổi `db_name` sau khi active.

### 2.5. ProjectService

Trạng thái bật/tắt và cấu hình riêng của một service trong project.

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `project_id` | ULID FK | Yes | Composite PK |
| `service_key` | enum | Yes | `auth`,`storage`,`pg_meta`,`rest`,`realtime`,`image_proxy` |
| `enabled` | boolean | Yes | Mặc định theo template |
| `config` | jsonb | No | Cấu hình riêng đã validate (không chứa secret) |
| `updated_at` | timestamp | Yes | |

**Validation**:
- `service_key` thuộc enum; không cho service lạ.
- `rest` yêu cầu `pg_meta` (hoặc schema catalog tương đương).
- `realtime` yêu cầu `auth` nếu private channel bật.
- `image_proxy` yêu cầu `storage`.
- Tắt service không xóa dữ liệu; chỉ đóng route và dừng xử lý.

### 2.6. Domain

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `host` | hostname | Yes | Unique |
| `scope` | enum(`instance`,`project`) | Yes | |
| `project_id` | ULID FK | No | Bắt buộc khi scope=project |
| `status` | enum | Yes | `pending`,`verified`,`active`,`error`,`expired` |
| `verification_token` | string | No | DNS TXT nếu cần |
| `last_checked_at` | timestamp | No | |
| `cert_expires_at` | timestamp | No | Từ Caddy/ACME |
| `created_at` | timestamp | Yes | |

**Validation**:
- Host lowercase, không trailing dot, không wildcard V1.
- `scope=project` ⇒ `project_id` NOT NULL.
- Không xóa domain đang active nếu project còn route; phải disable trước.

### 2.7. ApiKey

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `project_id` | ULID FK | Yes | |
| `type` | enum(`publishable`,`secret`) | Yes | |
| `prefix` | string(12) | Yes | Hiển thị để nhận diện |
| `key_hash` | sha256 | Yes | Không lưu plaintext |
| `scopes` | string[] | No | Mặc định theo type |
| `status` | enum(`active`,`retiring`,`revoked`,`expired`) | Yes | |
| `created_at` | timestamp | Yes | |
| `last_used_at` | timestamp | No | |
| `revoked_at` | timestamp | No | |

**Validation**:
- Mỗi project MUST có ít nhất một publishable key active.
- Secret key hiển thị đúng một lần khi tạo.
- `key_hash` unique; so sánh constant-time.
- Retiring cho phép overlap tối đa 24h trước khi revoke.

### 2.8. SigningKey

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `project_id` | ULID FK | Yes | |
| `algorithm` | enum(`Ed25519`) | Yes | V1 |
| `public_key` | string | Yes | JWKS |
| `private_key_ref` | path | Yes | `/var/lib/doctbase/auth/keys/<project_id>.key` |
| `status` | enum(`pending`,`active`,`retiring`,`retired`) | Yes | |
| `created_at` | timestamp | Yes | |
| `activated_at` | timestamp | No | |
| `retired_at` | timestamp | No | |

**Validation**:
- Đúng một `active` key/project tại một thời điểm.
- Public key xuất hiện trong `projects.json`/JWKS khi active hoặc retiring.
- Private key không bao giờ rời auth service; management chỉ nhận public key.
- Rotation: pending → active; key cũ active → retiring → retired sau khi token cũ hết hạn.

### 2.9. SecretMetadata

Metadata cho secret; **không chứa giá trị secret**.

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `scope` | enum(`instance`,`project`) | Yes | |
| `project_id` | ULID FK | No | |
| `name` | string(64) | Yes | `postgres_admin`, `pgbouncer_auth`, `internal_token`, ... |
| `path` | path | Yes | File/credential path |
| `owner` | string | Yes | System user |
| `mode` | octal | Yes | 0600/0640 |
| `version` | integer | Yes | Tăng khi rotate |
| `created_at` | timestamp | Yes | |
| `rotated_at` | timestamp | No | |

### 2.10. Backup

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `scope` | enum(`instance`,`project`) | Yes | |
| `project_id` | ULID FK | No | |
| `version` | semver | Yes | Version Doctbase tại thời điểm backup |
| `status` | enum(`creating`,`complete`,`verified`,`failed`) | Yes | |
| `path` | path | Yes | Local/remote path |
| `checksum` | sha256 | Yes | Manifest checksum |
| `size_bytes` | bigint | Yes | |
| `manifest` | jsonb | Yes | Danh sách file/DB, version, timestamp |
| `created_at` | timestamp | Yes | |
| `completed_at` | timestamp | No | |
| `error_code` | string | No | Khi failed |

### 2.11. AuditEvent

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `actor_type` | enum(`admin`,`system`,`cli`) | Yes | |
| `actor_id` | string | No | Admin ID hoặc `system` |
| `action` | string(64) | Yes | `project.create`, `project.delete`, `config.apply`, ... |
| `target_type` | string(32) | No | `project`, `service`, `backup`, ... |
| `target_id` | string | No | |
| `request_id` | string | No | Correlation |
| `ip` | inet | No | |
| `metadata` | jsonb | No | Redacted |
| `created_at` | timestamp | Yes | |

**Validation**:
- Append-only; không chứa secret/token/password.
- Retention mặc định 90 ngày (cấu hình được).

### 2.12. Operation

Theo dõi tác vụ dài: install, apply, upgrade, restore, project create/delete.

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `id` | ULID | Yes | |
| `type` | enum | Yes | `install`,`apply`,`upgrade`,`restore`,`backup`,`project_create`,`project_delete` |
| `status` | enum | Yes | `pending`,`running`,`succeeded`,`failed`,`rolled_back`,`cancelled` |
| `target` | string | No | Project slug/host/version |
| `started_at` | timestamp | Yes | |
| `finished_at` | timestamp | No | |
| `error_code` | string | No | |
| `log_ref` | path | No | Install/operation log |
| `rollback_ref` | string | No | Backup/operation ID dùng để rollback |

### 2.13. ServiceRuntime

Trạng thái runtime của service; là **view/cache in-memory** từ systemd/Compose, không phải source of truth và không persist vào control DB.

| Field | Type | Required | Ghi chú |
|-------|------|----------|---------|
| `service_key` | enum | Yes | 8 app services + infra |
| `instance_id` | ULID | Yes | |
| `source` | enum(`systemd`,`compose`,`dev`,`fake`) | Yes | Nguồn trạng thái |
| `unit` | string | No | systemd unit hoặc compose service name |
| `optional` | bool | Yes | Optional service có thể off |
| `state` | enum(`starting`,`running`,`ready`,`degraded`,`stopping`,`stopped`,`failed`) | Yes | `running` = process active nhưng chưa có kết quả probe mới |
| `health` | enum(`ok`,`warn`,`error`,`unknown`) | Yes | |
| `version` | semver | Yes | |
| `endpoint` | string | Yes | UDS path hoặc private address |
| `config_hash` | sha256 | No | Phát hiện drift |
| `started_at` | timestamp | No | |
| `last_check_at` | timestamp | Yes | |
| `last_error` | string | No | Mã lỗi gần nhất, đã redact |
| `operation_id` | ULID | No | Operation restart/start/stop đang chạy hoặc gần nhất |

**Validation**:
- `service_key` MUST thuộc registry; không nhận key tùy ý từ user.
- `state=ready` chỉ khi process active và `/readyz` trả 200.
- `state=degraded` khi process active nhưng readiness `degraded` hoặc một check không bắt buộc fail.
- `state=failed` khi systemd `failed` hoặc process thoát bất thường; `last_error` MUST có mã lỗi.
- `optional=true` + `state=stopped` không làm instance unhealthy.
- `source` và `unit` MUST khớp registry; không dùng dữ liệu này để gọi systemd với tên tùy ý.

**State mapping**:

| systemd/compose | ServiceRuntime |
|-----------------|----------------|
| `active` + ready | `ready` |
| `active` + chưa probe | `running` |
| `active` + degraded | `degraded` |
| `activating` | `starting` |
| `deactivating` | `stopping` |
| `inactive` | `stopped` |
| `failed` | `failed` |

**Ghi chú**: `ServiceRuntime` không thay thế `Operation`/`AuditEvent`; mọi restart/start/stop phải tạo `Operation` và audit event tương ứng.

## 3. State Transitions

### 3.1. Instance

```text
installing → healthy → degraded → healthy
                  ↘ upgrading → healthy
                  ↘ failed (terminal until repair/rollback)
```

- `installing`: installer đang chạy; chưa phục vụ traffic.
- `healthy`: tất cả service bắt buộc ready.
- `degraded`: ít nhất một service optional lỗi hoặc một bắt buộc down; data plane có thể vẫn chạy.
- `upgrading`: maintenance; không nhận thay đổi cấu hình.
- `failed`: install/upgrade fail; cần `doctor`/`repair`/rollback.

### 3.2. Project

```text
provisioning → active → disabled → active
                    ↘ deleting → deleted
                    ↘ failed (rollback tạo DB/role/config)
```

- `provisioning`: đang tạo DB/role/key/route; chưa public.
- `active`: route hoạt động; key hợp lệ.
- `disabled`: route đóng; dữ liệu giữ nguyên.
- `deleting`: soft-delete, revoke key, chờ purge.
- `deleted`: DB/role/storage đã xóa (purge).
- `failed`: rollback; không để rác.

### 3.3. Domain

```text
pending → verified → active
                    ↘ error ↔ pending
                    ↘ expired → pending
```

### 3.4. ApiKey

```text
active → retiring → revoked
      ↘ revoked
      ↘ expired
```

### 3.5. SigningKey

```text
pending → active → retiring → retired
```

- Chỉ một active/project.
- Retiring vẫn verify token cũ; retired không còn trong JWKS.

### 3.6. Backup

```text
creating → complete → verified
                    ↘ failed
```

- `verified` sau khi kiểm tra checksum/manifest.
- Restore chỉ chấp nhận `complete`/`verified`.

### 3.7. Operation

```text
pending → running → succeeded
                 ↘ failed → rolled_back
                 ↘ cancelled
```

## 4. Cross-entity Rules

1. **Tenant isolation**: mọi truy vấn project-scoped MUST filter `project_id`; API key/signing key/domain của project A không được dùng cho project B.
2. **Unique active signing key**: partial unique index trên `(project_id)` WHERE `status='active'`.
3. **Unique host**: `Domain.host` unique toàn instance; project domain và instance admin domain không trùng.
4. **No secret values in control DB**: chỉ hash/ref/metadata; private JWT key nằm ở auth key store.
5. **Deletion order**: project delete → revoke keys → disable routes → backup (nếu purge) → drop DB/roles → remove storage → audit.
6. **Restore order**: instance → control DB → project DBs → storage → auth keys → generated config → apply → health.
7. **Audit**: mọi thao tác admin qua API/CLI tạo AuditEvent; system job quan trọng (upgrade/restore) cũng tạo.
8. **Timestamps**: UTC, ISO-8601; hiển thị theo timezone instance.
9. **IDs**: ULID cho sortable IDs; slug/host là định danh người dùng, không dùng làm khóa ngoại.
10. **Retention**: audit 90 ngày; backup theo policy 7 daily/4 weekly; log theo journald/logrotate.

## 5. Data Volume Assumptions

- Một instance: ≤ 100 project.
- Mỗi project: database riêng; dung lượng tùy storage VPS; quota optional.
- Mỗi project: 1 signing key active + tối đa 1 retiring; 1 publishable key active + N secret key active/retiring.
- Mỗi project: 1 domain mặc định + tối đa 5 custom domain (V1.1 nếu cần).
- Backup: ≤ 10 GB/project trong test reference; retention local 7 daily/4 weekly.
- Audit: ~100k events/instance/tháng trước khi prune.

## 6. Open Items for Implementation

Các mục sau chưa cần chốt trong spec/plan nhưng phải được quyết định khi viết migration:

- Kiểu PostgreSQL cụ thể cho ULID (`uuid` vs `text`), JSONB indexing, partial index.
- Cơ chế lưu `config` của ProjectService (JSONB schema version).
- Chi tiết bảng `schema_migrations` cho control DB và project DB.
- Cơ chế encrypt backup (age/restic) và quản lý khóa backup.
- Chính sách retention/audit có cấu hình hay cố định V1.
- Cách biểu diễn `storage_quota` (bytes) và enforce ở storage service.
