# Doctbase V1 — Nghiên cứu cài đặt & cấu hình dễ dàng

> **Vai trò trong Spec Kit:** Đây là tài liệu nghiên cứu tham chiếu (Phase 0) cho feature [`001-doctbase-install-config`](../specs/001-doctbase-install-config/spec.md). Nguồn chuẩn là [constitution](../.specify/memory/constitution.md), [spec](../specs/001-doctbase-install-config/spec.md), [plan](../specs/001-doctbase-install-config/plan.md) và [tasks](../specs/001-doctbase-install-config/tasks.md). Tài liệu này cung cấp bối cảnh, số liệu so sánh và mẫu cấu hình chi tiết; khi mâu thuẫn, các artifact Spec Kit ở trên thắng.

> **Ngày nghiên cứu:** 06/11/2026  
> **Trạng thái:** Đề xuất kỹ thuật, dùng làm đầu vào cho giai đoạn Foundation  
> **Phạm vi:** cách cài đặt, cấu hình, nâng cấp, sao lưu và vận hành Doctbase trên một VPS; không thay đổi kiến trúc tổng thể 9 nhóm service đã chốt.

---

## 0. Tóm tắt điều hành

Yêu cầu “cài đặt và cấu hình phải dễ” không nên được hiểu là “ít tính năng” hay “ẩn hết mọi thứ”. Với một hệ BaaS gồm PostgreSQL, PgBouncer, Caddy và 8 service Zig, mục tiêu đúng là:

> **Người dùng chỉ cần biết 1 lệnh cài, 1 file cấu hình, 1 lệnh tạo project và 1 URL để bắt đầu — trong khi vẫn giữ được PostgreSQL nguyên bản, microservices và khả năng tự vận hành.**

### 0.1. Kết luận chính

1. **Native install là đường chính (golden path), Docker là đường phụ.** Native cho phép tối ưu tài nguyên trên VPS 2 GB, không phụ thuộc Docker và đúng tinh thần “single-VPS first”. Docker vẫn phải cài được bằng một lệnh, nhưng không phải điều kiện bắt buộc.
2. **Một CLI duy nhất (`doctbase`) làm installer, config manager, lifecycle manager, doctor, backup và upgrade.** Logic cài đặt nằm trong binary Zig; shell script chỉ là bootstrap nhỏ, có kiểm tra chữ ký.
3. **Một file cấu hình người dùng sửa: `/etc/doctbase/doctbase.toml`.** Mọi thứ khác — Caddyfile, `pgbouncer.ini`, systemd units, danh sách project, JWKS — là **generated artifacts**, có header “do not edit” và được render lại bằng `doctbase apply`.
4. **Mặc định phải chạy được mà không cần sửa gì.** Domain và email TLS là tùy chọn. Nếu không có domain, hệ vẫn cài được ở chế độ local/SSH tunnel. Không có mật khẩu mặc định; admin được bootstrap bằng token dùng một lần.
5. **Không mở thêm port nội bộ.** Ở chế độ native, PostgreSQL và PgBouncer chỉ nghe Unix socket; các service Zig nói chuyện với nhau qua Unix socket. Ra Internet chỉ có 80/443 của Caddy. Điều này vừa dễ cấu hình vừa giảm bề mặt tấn công.
6. **Không viết một service supervisor mới trong V1.** Dùng systemd cho native và Docker Compose cho Docker, thông qua một lớp `LifecycleDriver` mỏng. Chỉ có một dev-runner chạy foreground cho môi trường phát triển. Đây là quyết định quan trọng để giảm rủi ro và tận dụng hạ tầng có sẵn.
7. **Multi-project dùng database-per-project.** Mỗi project có database, role và JWT key riêng. Cách này cho ranh giới bảo mật rõ, backup/restore/drop độc lập và PgBouncer vẫn pool được bằng `[databases]` + `auth_query`.
8. **Dashboard là SvelteKit static, nhúng vào binary management.** Không cần Node.js runtime, không thêm container, không thêm service.
9. **Giao thức nội bộ là HTTP/1.1 + JSON trên Unix socket.** Dùng `http.zig` (httpz) — tại thời điểm nghiên cứu hỗ trợ Zig 0.17, Unix socket, multipart và WebSocket. Không dùng gRPC trong V1.
10. **“Dễ” phải được đo bằng acceptance test, không chỉ bằng tài liệu.** Mục tiêu: cài xong trên VPS trống 2 vCPU/2 GB trong ≤ 5 phút, tạo project và gọi API đầu tiên trong ≤ 60 giây, 0 lần sửa file bắt buộc.

### 0.2. Sáu quyết định cần chốt ngay trong Foundation

| # | Vấn đề | Quyết định đề xuất |
|---|--------|-------------------|
| 1 | Cô lập nhiều project | Database-per-project, role riêng, JWT key riêng, storage prefix riêng |
| 2 | Frontend Dashboard | SvelteKit + TypeScript + Tailwind + shadcn-svelte, build static và nhúng vào management binary |
| 3 | Giao thức nội bộ | HTTP/1.1 + JSON trên Unix socket; WebSocket cho realtime; `httpz` làm HTTP stack |
| 4 | Service supervisor | systemd (native) / Docker Compose (Docker) qua `LifecycleDriver`; không viết supervisor production mới |
| 5 | Định dạng cấu hình | TOML 1.0, một file instance; project là dữ liệu control-plane; secrets tách riêng |
| 6 | Nền tảng native V1 | Debian 13 / Ubuntu 24.04 & 26.04 LTS, x86_64 & arm64; PostgreSQL 18; Zig 0.17.1 |

---

## 1. Định nghĩa “dễ” một cách đo được

“Dễ” là một thuộc tính của sản phẩm, không phải của tài liệu. Dưới đây là bộ tiêu chí đề xuất, dùng làm acceptance gate cho V1.

| Mã | Tiêu chí | Mục tiêu đo được | Cách kiểm chứng |
|----|----------|------------------|-----------------|
| C1 | Cài bằng một lệnh | Một lệnh bootstrap + một lệnh install; không thao tác thủ công | Test trên VM trống |
| C2 | Thời gian đến API đầu tiên | ≤ 5 phút trên 2 vCPU/2 GB; ≤ 60 giây từ install xong đến curl thành công | Stopwatch + script E2E |
| C3 | Zero mandatory config | Không bắt buộc sửa file; tối đa 2 câu hỏi tương tác (domain, email) | Chạy `--yes` không nhập gì |
| C4 | Một file cấu hình | Người dùng chỉ sửa `doctbase.toml`; secrets và generated files tách biệt | Kiểm tra tài liệu + filesystem |
| C5 | Một lệnh cho mỗi việc | `status`, `logs`, `doctor`, `backup`, `upgrade`, `project create` | CLI help + test |
| C6 | Idempotent | Chạy lại install/apply không mất dữ liệu, không đổi gì nếu config không đổi | Chạy 3 lần, so sánh checksum |
| C7 | Có thể đảo ngược | `uninstall --keep-data` và `--purge`; upgrade có rollback | Test trên VM |
| C8 | Lỗi có thể sửa được | Mỗi lỗi có mã, nguyên nhân, gợi ý, link docs; `doctor` phát hiện lỗi phổ biến | Fault injection |
| C9 | Cài offline | Có bundle offline cho native và Docker | Test air-gapped |
| C10 | Nâng cấp an toàn | Backup trước migration; rollback tự động nếu health check fail | Test N-1 → N |
| C11 | Nhiều project dễ dàng | Tạo project bằng một lệnh; không cần tạo DB/role/domain thủ công | Tạo 10 project |
| C12 | Bảo mật mặc định | Secrets sinh tự động; không có DB port public; TLS auto; RLS default-deny | Security review |
| C13 | Tài liệu một trang | Quickstart ≤ 1 trang, copy-paste được, không có prerequisite ẩn | Review |
| C14 | Tài nguyên hợp lý | Idle ≤ ~700 MB RAM native (gồm PostgreSQL) với profile mặc định | Đo trên VPS 2 GB |
| C15 | Không phá hệ thống sẵn có | Không chiếm 5432/6432; dùng cluster và unit riêng; không tự ý xóa dịch vụ khác | Test trên VPS có PostgreSQL/Caddy sẵn |

### 1.1. Anti-criteria — những thứ không nên làm để “cho dễ”

- **Không** thêm một database abstraction mới thay PostgreSQL; điều đó phá kiến trúc đã chốt.
- **Không** dùng SQLite làm mặc định chỉ để cài nhanh; sẽ tạo hai chế độ vận hành và hai bộ bug.
- **Không** nhúng toàn bộ PostgreSQL/PgBouncer/Caddy vào một binary khổng lồ; khó cập nhật bảo mật và trái nguyên tắc “không viết lại hạ tầng”.
- **Không** tự động sửa firewall, SSH, DNS hay xóa web server đang chạy. Mọi thay đổi hệ thống phải hiện trong `--dry-run`.
- **Không** che giấu cấu hình bằng một UI duy nhất. Người vận hành phải luôn xem được file, diff và generated output.
- **Không** biến management API thành một cổng root không giới hạn. Dashboard phải chạy quyền thấp, thao tác lifecycle qua kênh có allowlist.

---

## 2. Nghiên cứu tham chiếu: các hệ self-hosted đã giải bài toán này thế nào?

### 2.1. Supabase self-hosted

**Quan sát:**

- Bản Docker Compose chính thức (2026) gồm khoảng **11 service nền**: `studio`, `api-gw` (Envoy), `auth` (GoTrue), `rest` (PostgREST), `realtime`, `storage`, `imgproxy`, `meta`, `functions`, `db`, `supavisor`; logs/analytics là lớp optional thêm `analytics` + `vector`.
- Cấu hình tập trung trong `.env` với rất nhiều biến: mật khẩu Postgres, JWT secret, anon key, service role key, dashboard user/password, S3 keys, SMTP, OAuth…
- Tài liệu nói rõ người self-host phải tự chịu trách nhiệm: provisioning, hardening, cập nhật OS/service, bảo trì Postgres, backup/disaster recovery, monitoring.
- Nâng cấp thường phải chạy script, pull image, recreate service; không có cơ chế rollback thống nhất.

**Bài học cho Doctbase:**

- Feature-complete đi kèm nhiều service và nhiều secret; **không nên copy mô hình 11 service làm mặc định cho một VPS 2 GB**.
- `.env` nhiều biến là dễ với người đã quen, nhưng là rào cản lớn với người mới. Cần **defaults + generated secrets + một file TOML**.
- Cần phân biệt rõ “service có thể tắt” và “service bắt buộc”; optional service phải được tắt bằng một profile, không phải comment YAML.

### 2.2. Appwrite self-hosted

**Quan sát:**

- Có installer một lệnh bằng Docker, trải nghiệm ban đầu tốt; tạo file compose + `.env` và chạy stack.
- Appwrite 2.0 mặc định khoảng **16 container**, gồm API, workers, executor, Redis, database backend, Traefik, embeddings… Tài liệu tối thiểu ghi 2 vCPU/4 GB RAM/2 GB swap; thực tế với embeddings có báo cáo cần 4 vCPU/6–8 GB.
- Chọn PostgreSQL/MariaDB/MongoDB ở thời điểm cài và không đổi được sau đó.

**Bài học:**

- Installer UX tốt (progress, wizard, một lệnh) nhưng **footprint quá lớn** cho mục tiêu single-VPS 2 GB.
- Việc chọn backend DB phức tạp không cần thiết với Doctbase: PostgreSQL là quyết định đã chốt, không đưa ra lựa chọn.
- Càng nhiều container càng nhiều healthcheck, dependency và thời gian debug. Doctbase nên **giảm số process biên** bằng UDS và gom dashboard vào management.

### 2.3. PocketBase

**Quan sát:**

- Một binary duy nhất, SQLite nhúng, admin dashboard, auth, storage, realtime; chạy `./pocketbase serve` là xong.
- Không cần Docker, không cần database server, không cần cấu hình.
- Đánh đổi: SQLite, single-node, không phải PostgreSQL, không có mô hình microservices, không phù hợp để làm nền tảng BaaS đa project cần Postgres native.

**Bài học:**

- Đây là **chuẩn vàng của first-run experience**: một file, một lệnh, một URL.
- Doctbase không thể đạt “một binary” vì kiến trúc đã chốt, nhưng có thể đạt **“một CLI, một file cấu hình, một lệnh”** — tức là cùng trải nghiệm cảm nhận, khác kiến trúc bên dưới.
- Bài học lớn nhất: **đừng bắt người dùng hiểu kiến trúc trước khi sản phẩm chạy**.

### 2.4. Coolify và Dokploy

**Quan sát:**

- Cả hai cài bằng một lệnh `curl | sh`, mất khoảng 3–5 phút, tự cài Docker, proxy và dashboard.
- Coolify tối thiểu 2 core/2 GB/10 GB; Dokploy tối thiểu 2 GB RAM/30 GB disk.
- Điểm mạnh: progress rõ, tự động cài dependency, kết thúc bằng URL dashboard.
- Điểm yếu: phụ thuộc Docker, generated state khó kiểm tra, và Docker socket là bề mặt tấn công lớn.

**Bài học:**

- **Một lệnh + progress + URL cuối** là mô hình UX đúng.
- Không nên giao toàn bộ quyền Docker socket cho dashboard theo mặc định.
- Nên có `--dry-run` và log cài đặt rõ ràng, vì người dùng phải tin được installer đang làm gì trên VPS.

### 2.5. Caddy, PgBouncer, PostgreSQL, systemd

- **Caddy** tự động HTTPS, tự redirect HTTP→HTTPS, tự renew; admin API mặc định `localhost:2019`; có thể reload Caddyfile qua `POST /load` với `Content-Type: text/caddyfile`, lỗi thì giữ config cũ. Đây là lựa chọn rất tốt để Doctbase không phải tự viết ACME/TLS.
- **PgBouncer** hỗ trợ `pool_mode = transaction`, `auth_query` để lấy SCRAM verifier động, và entry `*` làm fallback database. `auth_query` chạy trong database đích, nên function phải có trong từng project DB — có thể đưa vào template database.
- **PostgreSQL RLS** mặc định default-deny khi bật; table owner thường bypass trừ khi `FORCE ROW LEVEL SECURITY`; role có `BYPASSRLS` luôn bypass. Đây là công cụ đúng cho quyền end-user trong từng project, nhưng không thay thế cô lập database.
- **systemd credentials** (`LoadCredential=`) cho phép truyền secret qua file tạm chỉ service đọc được, tốt hơn `.env` hoặc environment variable.
- **Docker Compose profiles** cho phép bật/tắt optional service bằng `--profile`, phù hợp để giữ một compose file duy nhất.

### 2.6. Bảng so sánh rút gọn

| Hệ | Cài đặt | Số thành phần nền | PostgreSQL native | Multi-project | Điểm mạnh | Điểm yếu |
|----|--------|-------------------|-------------------|---------------|-----------|----------|
| Supabase | Docker Compose + `.env` | ~11 (+ optional) | Có | Có (theo hướng cloud) | Feature rất đầy đủ | Nhiều secret/service, nặng, tự vận hành |
| Appwrite | Installer một lệnh | ~16 | Chọn được | Có | UX cài tốt | Rất nặng, nhiều container |
| PocketBase | Một binary | 1 | Không (SQLite) | Hạn chế | Cực dễ | Không hợp Postgres/microservices |
| Coolify/Dokploy | Một lệnh | Docker + proxy + dashboard | Không trực tiếp | Theo app | UX cài rất tốt | Phụ thuộc Docker, socket |
| **Doctbase (đề xuất)** | **Một CLI + systemd/Compose** | **3 hạ tầng + 8 app process** | **Có** | **Có, DB-per-project** | **Cân bằng ease + Postgres + microservices** | **Phải giấu độ phức tạp bằng CLI/defaults** |

### 2.7. Khoảng trống Doctbase có thể lấp

- Supabase/Appwrite mạnh nhưng **quá nặng cho VPS 2 GB**.
- PocketBase dễ nhưng **không dùng PostgreSQL** và không có kiến trúc microservices.
- Chưa có sản phẩm nào vừa **Postgres-native**, vừa **microservices**, vừa **cài một lệnh trên một VPS nhỏ**.

Định vị đề xuất:

> **Doctbase = trải nghiệm cài đặt kiểu PocketBase, năng lực kiểu Supabase, lõi PostgreSQL nguyên bản, chạy gọn trên một VPS.**

---

## 3. Nguyên tắc thiết kế cài đặt & cấu hình

1. **Defaults over decisions.** Tự động phát hiện RAM/CPU/disk, tự chọn thông số PostgreSQL, tự sinh secrets, tự chọn socket/port nội bộ. Người dùng chỉ quyết định những gì thực sự thuộc về họ: domain, email, project.
2. **Một cách làm rõ ràng.** Một định dạng config (TOML), một CLI, một layout thư mục, một cách reload. Không có “cách 2” trong quickstart.
3. **Progressive disclosure.** File cấu hình tối giản; advanced keys có tài liệu và `doctbase config explain`. Không đưa 200 biến vào mặt tiền.
4. **Generated files không được sửa tay.** Caddyfile, `pgbouncer.ini`, systemd units, `projects.json` đều có header cảnh báo và bị ghi đè bởi `doctbase apply`.
5. **Fail closed, fail early.** Config sai thì không apply; preflight fail thì không cài; migration fail thì rollback. Không để trạng thái nửa vời.
6. **Mọi thứ quan sát được.** `status`, `doctor`, `logs`, `config diff`, `support bundle`. Không có lỗi “internal error” trần trụi.
7. **Idempotent và reversible.** Cài lại, apply lại, upgrade, uninstall đều có semantics rõ. Luôn có backup trước thay đổi lớn.
8. **Security by default, không phải security by checklist.** Secrets sinh tự động, DB không public, TLS auto, UDS permissions, RLS default-deny, admin tách khỏi data plane.
9. **Không phá hệ thống sẵn có.** Cluster PostgreSQL riêng, unit systemd riêng, config riêng. Không chiếm 5432/6432/80/443 một cách mù quáng.
10. **Escape hatch có kiểm soát.** Hỗ trợ external PostgreSQL, external reverse proxy, custom certificate, S3 storage; nhưng đây là đường advanced, không phải đường mặc định.

---

## 4. Kiến trúc cài đặt & vận hành đề xuất

### 4.1. Các chế độ triển khai và ma trận hỗ trợ

| Chế độ | Mục đích | Yêu cầu | Mức hỗ trợ V1 |
|--------|----------|---------|----------------|
| Native | Production trên VPS, tối ưu tài nguyên | Debian 13 / Ubuntu 24.04, 26.04 LTS; systemd; x86_64/arm64 | **Chính thức, khuyến nghị** |
| Docker | Production/portability, dev đồng nhất | Docker Engine + Compose v2; ≥ 4 GB RAM khuyến nghị | Chính thức, optional |
| Dev | Phát triển local | macOS/Linux; PostgreSQL local hoặc Docker; không cần root | Chính thức |
| Offline bundle | Air-gapped | Bundle binary + package/image | Phase 6 |
| Kubernetes/HA | Nhiều node | — | Không thuộc V1 |

**Không hỗ trợ production V1:** Windows native, macOS server, RHEL/Rocky (có thể bổ sung sau), kiến trúc HA nhiều node.

### 4.2. Layout thư mục và quy ước

```text
/usr/local/bin/doctbase                         # symlink -> current/bin/doctbase
/usr/local/lib/doctbase/
├── versions/<version>/bin/                     # binary bất biến theo version
│   ├── doctbase
│   ├── doctbase-gateway
│   ├── doctbase-management
│   ├── doctbase-auth
│   ├── doctbase-rest
│   ├── doctbase-realtime
│   ├── doctbase-storage
│   ├── doctbase-image-proxy
│   └── doctbase-pg-meta
└── current -> versions/<version>               # symlink đổi khi upgrade

/etc/doctbase/
├── doctbase.toml                               # file DUY NHẤT người dùng sửa
├── secrets/                                    # 0700 root:doctbase, files 0600
│   ├── postgres_admin
│   ├── pgbouncer_auth
│   ├── internal_token
│   └── admin_setup_token
└── generated/                                  # 0750 root:doctbase; do not edit
    ├── Caddyfile
    ├── pgbouncer.ini
    ├── projects.json
    └── services.env                             # biến runtime không nhạy cảm

/var/lib/doctbase/
├── state.json                                  # version, components, ports, checksums
├── auth/keys/<project_id>.key                  # 0600 doctbase-auth; JWT private key
├── pgbouncer/users.txt                         # 0600 doctbase-pgbouncer; SCRAM verifier
├── projects/<project_id>/storage/              # storage local
├── cache/images/                               # image proxy cache
├── caddy/                                      # cert/key do Caddy quản lý
└── backups/                                    # backup local

/run/doctbase/
├── gateway.sock
├── management.sock
├── auth.sock
├── rest.sock
├── realtime.sock
├── storage.sock
├── image-proxy.sock
├── pg-meta.sock
└── pgbouncer.sock                              # PgBouncer Unix socket

/var/lib/postgresql/18/doctbase/                # cluster riêng (Debian layout)
/etc/postgresql/18/doctbase/                    # config cluster riêng
/var/log/doctbase/                              # chỉ dùng cho install log / backup log
```

**Quy ước quan trọng:**

- PostgreSQL dùng **cluster riêng** tên `doctbase`, không dùng cluster mặc định trên 5432.
- PostgreSQL **không nghe TCP** (`listen_addresses = ''`), chỉ Unix socket.
- PgBouncer **không nghe TCP**, chỉ Unix socket tại `/run/doctbase/pgbouncer.sock`.
- Các service Zig chỉ nghe Unix socket; không có port nội bộ nào mở ra host.
- Caddy là thành phần duy nhất bind 80/443.
- Mọi file generated có header:
  ```text
  # Generated by doctbase <version>. DO NOT EDIT.
  # Source: /etc/doctbase/doctbase.toml + control database.
  # Apply:  sudo doctbase apply
  ```

### 4.3. Luồng cài native (fresh VPS)

Mục tiêu: một lệnh, có progress, có thể dry-run, có rollback.

```text
Người dùng
   │
   ▼
install.sh (bootstrap nhỏ, POSIX, có kiểm tra chữ ký)
   │  tải manifest + binary đã ký
   ▼
doctbase install
   ├─ 1. Preflight
   ├─ 2. Lập kế hoạch + hiển thị thay đổi
   ├─ 3. Cài package hệ thống (PostgreSQL 18, PgBouncer, Caddy)
   ├─ 4. Tạo user/group/thư mục
   ├─ 5. Sinh secrets
   ├─ 6. Tạo cluster PostgreSQL riêng + role/database/template
   ├─ 7. Cấu hình PgBouncer (UDS, auth_query)
   ├─ 8. Cấu hình Caddy + TLS
   ├─ 9. Cài binary + systemd units + start target
   ├─ 10. Bootstrap admin + health check
   └─ 11. In summary + setup URL
```

#### Bước 1 — Preflight

Kiểm tra và báo lỗi sớm:

- Root/sudo, OS/arch, systemd, kernel.
- RAM: tối thiểu 1.5 GB (cảnh báo), khuyến nghị 2 GB; disk trống ≥ 10 GB (cảnh báo), ≥ 5 GB (fail).
- Port 80/443 còn trống; nếu bận, đề xuất `--proxy=external` hoặc dừng dịch vụ đang chiếm (không tự dừng).
- DNS: nếu có domain, kiểm tra A/AAAA; nếu sai, hiển thị bản ghi cần tạo và cho phép `--skip-dns-check`.
- Clock sync (ACME cần đúng giờ).
- PostgreSQL/Caddy/PgBouncer đã tồn tại: phát hiện, không xóa; dùng cluster/unit riêng.
- Kiểm tra lock `/run/doctbase/install.lock` để tránh hai installer chạy song song.
- Kiểm tra phiên bản OS nằm trong ma trận hỗ trợ.

#### Bước 2 — Plan và dry-run

`doctbase install --dry-run` in ra:

- Package sẽ cài, dung lượng ước tính.
- User/group/thư mục sẽ tạo.
- Cluster/port/socket sẽ dùng.
- File sẽ ghi.
- Service sẽ bật.
- Thay đổi firewall (nếu có `--firewall`).
- Cảnh báo nếu có thành phần sẵn có bị ảnh hưởng.

Mặc định **không** tự sửa firewall, SSH, DNS, sysctl. Nếu người dùng chọn `--firewall`, installer mới cấu hình UFW (22/80/443).

#### Bước 3 — Cài package

- Thêm PGDG repo chính thức và cài `postgresql-18`, `postgresql-client-18`.
- Cài `pgbouncer`, `caddy` từ repo chính thức; pin major version, không pin cứng patch để còn nhận security update.
- Không dùng unit mặc định của distro cho Caddy/PgBouncer; nếu đã có, `disable` (không xóa) và dùng `doctbase-caddy.service` / `doctbase-pgbouncer.service` để tránh chiếm port/config.
- Cài `ca-certificates`, `curl`, `xz-utils`, `psql`; chỉ cài `libvips42` nếu bật image proxy.
- Không cài Docker ở chế độ native.
- Không `apt-mark hold`; ghi lại version vào `state.json` để `doctor` kiểm tra.

#### Bước 4 — User/group/thư mục

Tạo system user/group:

```text
doctbase              # group chung, không login
doctbase-gateway
doctbase-management
doctbase-auth
doctbase-rest
doctbase-realtime
doctbase-storage
doctbase-image
doctbase-meta
doctbase-caddy
doctbase-pgbouncer
doctbase-backup
```

Mỗi service chạy user riêng, group chung `doctbase`; UDS `0660` owner service:group `doctbase`. Storage/cache dùng `ReadWritePaths` riêng. Đây là lợi ích lớn của việc dùng systemd thay vì một supervisor tự viết.

Tạo thư mục với mode:

```text
/etc/doctbase                 0750 root:doctbase
/etc/doctbase/secrets         0700 root:doctbase
/etc/doctbase/generated       0750 doctbase-management:doctbase
/var/lib/doctbase             0750 root:doctbase
/var/lib/doctbase/projects    0770 doctbase-management:doctbase
/var/lib/doctbase/auth        0700 doctbase-auth:doctbase
/var/lib/doctbase/cache       0770 doctbase-image:doctbase
/var/lib/doctbase/caddy       0700 doctbase-caddy:doctbase
/var/lib/doctbase/backups     0770 doctbase-backup:doctbase
/run/doctbase                 0770 root:doctbase     (tmpfiles.d)
/var/log/doctbase             0750 root:doctbase
```

Các thư mục con có owner riêng để giảm quyền: auth sở hữu key, storage ghi trong project storage qua group, Caddy sở hữu cert, backup sở hữu backup. Installer tạo đúng owner/mode; `doctor` kiểm tra lại.

#### Bước 5 — Sinh secrets

Sinh bằng CSPRNG, lưu file 0600:

- `postgres_admin` — password cho role admin của Doctbase.
- `pgbouncer_auth` — password/SCRAM verifier cho role `pgbouncer_auth`.
- `internal_token` — token ký internal request giữa management/gateway/services.
- `admin_setup_token` — token dùng một lần để tạo admin dashboard (hết hạn 30 phút).

JWT private key **không** nằm trong `/etc/doctbase/secrets`. Auth service sở hữu key tại `/var/lib/doctbase/auth/keys/<project_id>.key` (0600 `doctbase-auth`); management gọi Auth internal API để tạo/rotate key và chỉ nhận public key/JWKS. Như vậy management không cần đọc private key của project.

**Không** đưa secret vào `doctbase.toml`, không in ra log, không đưa vào environment variable. Native dùng systemd `LoadCredential=`; Docker dùng Compose secrets hoặc `_FILE`.

#### Bước 6 — PostgreSQL

- Tạo cluster riêng: `pg_createcluster 18 doctbase --port 5433`.
- Cấu hình `/etc/postgresql/18/doctbase/conf.d/doctbase.conf`:
  - `listen_addresses = ''`
  - `unix_socket_directories = '/var/run/postgresql'`
  - `port = 5433`
  - `password_encryption = 'scram-sha-256'`
  - `ssl = off` (chỉ local)
  - tuning theo RAM: `shared_buffers`, `effective_cache_size`, `work_mem`, `maintenance_work_mem`
  - `max_connections = 200`
  - `shared_preload_libraries = 'pg_stat_statements'`
- `pg_hba.conf`: local dùng `scram-sha-256`; không có `host` vì không nghe TCP.
- Tạo role/database:
  - `doctbase_admin` (không phải superuser; có quyền tạo DB/role cần thiết).
  - `doctbase_meta` (quyền DDL trên project DB).
  - `pgbouncer_auth` (login, chỉ dùng cho auth_query).
  - Database `doctbase` (control plane).
  - Database template `template_doctbase` chứa extension, schema `auth`, `storage`, hàm `doctbase.pgbouncer_auth`.
- Cài extension: `pgcrypto`, `citext`, `pg_trgm`, `uuid-ossp` (tùy nhu cầu), `pg_stat_statements`.
- Chạy migration control-plane.

**Vì sao cluster riêng?**

- Không đụng PostgreSQL sẵn có của người dùng.
- Không chiếm 5432.
- Có thể backup/restore/drop toàn bộ Doctbase mà không ảnh hưởng ứng dụng khác.
- Dễ uninstall sạch.

#### Bước 7 — PgBouncer

- Config `/etc/doctbase/generated/pgbouncer.ini`, unit riêng `doctbase-pgbouncer.service`.
- Chỉ Unix socket:
  ```ini
  [pgbouncer]
  listen_addr =
  unix_socket_dir = /run/doctbase
  unix_socket_mode = 0660
  unix_socket_group = doctbase
  listen_port = 6432
  pool_mode = transaction
  auth_type = scram-sha-256
  auth_user = pgbouncer_auth
  auth_file = /var/lib/doctbase/pgbouncer/users.txt
  auth_query = SELECT * FROM doctbase.pgbouncer_auth($1)
  ```
- `[databases]` sinh entry cho từng project:
  ```ini
  doctbase_app = host=/var/run/postgresql port=5433 dbname=doctbase_app pool_size=10 max_db_connections=20
  ```
- Không dùng wildcard `*` cho V1 nếu cần giới hạn pool theo project; wildcard hữu ích cho tương lai hoặc môi trường nhiều project rất nhỏ.
- `auth_query` chạy trong database đích; hàm `doctbase.pgbouncer_auth` phải có trong `template_doctbase` để mọi project DB đều có.
- `pgbouncer_users.txt` chứa SCRAM verifier của `pgbouncer_auth`, sinh bằng SQL từ `pg_authid` với quyền superuser trong lúc bootstrap; ghi tại `/var/lib/doctbase/pgbouncer/users.txt` (0600 `doctbase-pgbouncer`).
- Reload bằng `SIGHUP` sau khi render; không restart nếu chỉ đổi pool/route.

**Lưu ý transaction pooling:**

- `SET LOCAL` an toàn trong transaction; dùng cho RLS (`SET LOCAL role` + `set_config('request.jwt.claims', ..., true)`).
- `LISTEN/NOTIFY` **không** an toàn qua transaction pooling; realtime phải kết nối trực tiếp PostgreSQL.
- Prepared statements: bật `max_prepared_statements = 200` để tương thích driver hiện đại.
- `DISCARD ALL` không chạy trong transaction mode; không dựa vào session state.

#### Bước 8 — Caddy + TLS

- Unit riêng `doctbase-caddy.service`, config `/etc/doctbase/generated/Caddyfile`, data `/var/lib/doctbase/caddy`.
- Bind 80/443 bằng `AmbientCapabilities=CAP_NET_BIND_SERVICE`, chạy user `doctbase-caddy`.
- Admin API bind Unix socket `/run/doctbase/caddy-admin.sock` (mode 0660, group `doctbase`; unit đặt `UMask=0007`); Docker dùng TCP nội bộ `caddy:2019`.
- Site block:
  - `admin.<domain>` → management UDS.
  - `<project>.<domain>` → gateway UDS; route WebSocket trực tiếp tới realtime UDS.
- Caddy tự xin cert qua HTTP-01/TLS-ALPN. Không cần DNS API cho subdomain cụ thể, miễn DNS A/AAAA trỏ đúng.
- Không dùng wildcard cert mặc định: wildcard yêu cầu DNS-01 và Caddy build có plugin DNS provider; để Phase 6.
- Reload:
  ```bash
  curl --unix-socket /run/doctbase/caddy-admin.sock \
    -X POST http://localhost/load \
    -H "Content-Type: text/caddyfile" \
    --data-binary @/etc/doctbase/generated/Caddyfile
  ```
  Caddy validate trước; nếu lỗi, config cũ vẫn chạy.

#### Bước 9 — Services + systemd

- Cài binary vào `/usr/local/lib/doctbase/versions/<version>/bin`.
- Render unit từ template; `systemctl daemon-reload`.
- `systemctl enable --now doctbase.target`.
- Thứ tự khởi động:
  - `postgresql@18-doctbase.service`
  - `doctbase-pgbouncer.service`
  - `doctbase-management.service` (migration/control plane)
  - `doctbase-auth`, `doctbase-pg-meta`, `doctbase-storage`
  - `doctbase-rest`, `doctbase-realtime`, `doctbase-image-proxy` (nếu bật)
  - `doctbase-gateway.service`
  - `doctbase-caddy.service`
- Dùng `Type=notify` + `WatchdogSec` nếu service hỗ trợ; nếu không, `Type=exec` + health check từ `doctbase apply`.
- Service retry DB với backoff; gateway trả 503 khi upstream chưa ready.

#### Bước 10 — Bootstrap admin + health check

- Tạo admin user trong control DB với password hash Argon2id.
- Sinh `admin_setup_token` dùng một lần, in URL:
  ```
  https://admin.example.com/setup#token=<one-time>
  ```
  Dùng fragment (`#`) để token không bị gửi vào access log/referrer.
- Token hết hạn sau 30 phút; `doctbase admin reset-setup` để tạo lại.
- Health check:
  - PostgreSQL `pg_isready` qua UDS.
  - PgBouncer `psql` qua UDS.
  - Caddy admin `/config/`.
  - Từng service `/readyz`.
  - Management `/api/v1/health`.
- Nếu fail: rollback có kiểm soát, giữ log, in `doctbase support bundle`.

#### Bước 11 — Summary

```text
Doctbase 1.0.0 đã sẵn sàng sau 3m 42s.

Dashboard:  https://admin.example.com/setup#token=<one-time>
API:        https://app.example.com  (sau khi tạo project)
Dữ liệu:    /var/lib/doctbase
Cấu hình:   /etc/doctbase/doctbase.toml

Bước tiếp theo:
  sudo doctbase project create myapp --services auth,storage,rest
  sudo doctbase status
```

### 4.4. Luồng cài Docker

Docker là đường phụ, nhưng phải làm tốt:

```bash
curl -fsSL https://get.doctbase.dev/docker-compose.yml -o docker-compose.yml
curl -fsSL https://get.doctbase.dev/.env.example -o .env
# Sửa .env tối thiểu: DOCTBASE_DOMAIN, DOCTBASE_EMAIL
docker compose up -d
```

Hoặc dùng CLI:

```bash
doctbase init --profile docker --domain example.com
doctbase up
```

**Đặc điểm:**

- Compose file có core services (postgres, pgbouncer, caddy, gateway, management, auth, pg-meta, storage) và optional services gắn `profiles: [rest]`, `[realtime]`, `[image-proxy]`.
- Chỉ Caddy publish 80/443; PostgreSQL/PgBouncer/management không publish.
- Trong Docker, service nói chuyện qua **TCP private network** (DNS service name), không dùng UDS bind mount — đảm bảo chạy được cả trên Docker Desktop/macOS khi dev. Native mới dùng UDS.
- Dùng bind mounts `./data`, `./config`, `./backups` thay vì named volume để dễ backup/inspect.
- Dùng Compose `secrets` cho password/keys; image chính thức của Postgres hỗ trợ `POSTGRES_PASSWORD_FILE`.
- Healthcheck + `depends_on: condition: service_healthy`.
- Container Doctbase chạy non-root, `read_only: true`, `tmpfs`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`.
- Caddy admin API bind trên network nội bộ (`0.0.0.0:2019` trong container), không publish ra host. Management gọi `http://caddy:2019/load`.
- CLI trên host ở Docker mode chạy lệnh nghiệp vụ qua `docker compose exec management doctbase ...` (hoặc `docker compose run --rm management ...`), nên không cần publish management ra host.
- Lifecycle trên Docker: CLI gọi `docker compose`; dashboard mặc định read-only cho start/stop. Nếu muốn dashboard điều khiển, bật opt-in socket proxy giới hạn (chỉ start/stop/restart container có label `doctbase`) — không mount Docker socket trực tiếp vào management.

**Vì sao không dùng một container duy nhất chứa tất cả service?**

- Vi phạm mô hình “mỗi service có vòng đời riêng”.
- Một container lớn khó scale/update từng service, khó debug, khó giới hạn tài nguyên.
- Docker Compose với 8 app container vẫn cài bằng một lệnh; đây là đánh đổi hợp lý cho optional mode.

### 4.5. Service supervisor — quyết định và lý do

Đây là một trong bốn điểm còn mở của kiến trúc. Đề xuất: **không viết supervisor production mới trong V1**.

#### So sánh phương án

| Phương án | Ưu điểm | Nhược điểm | Kết luận |
|-----------|---------|------------|----------|
| systemd per service | Ổn định, có sẵn, hardening, logging, restart, credentials, cgroups | Cần quyền lifecycle; hơi phức tạp với dashboard | **Chọn cho native** |
| Docker Compose | Chuẩn, healthcheck, profile, portability | Phụ thuộc Docker; dashboard khó điều khiển nếu không mở socket | **Chọn cho Docker** |
| Supervisor tự viết | Đồng nhất native/Docker; dashboard dễ điều khiển | Phải làm lại restart/backoff/logging/cgroups/signal; rủi ro cao; thêm binary | **Không chọn V1** |
| Chạy tất cả trong một process | Đơn giản nhất | Mất cô lập service, khó scale, một crash chết tất cả | **Không chọn** |

#### Thiết kế `LifecycleDriver`

```text
packages/service-lifecycle/
├── driver.zig          # interface: start/stop/restart/status/logs/enable/disable
├── systemd.zig         # native driver: D-Bus/systemctl + journald
├── compose.zig         # docker driver: docker compose / Engine API
└── dev.zig             # foreground child-process runner cho `doctbase dev`
```

- `SystemdDriver` gọi systemd qua D-Bus hoặc `systemctl` với allowlist unit prefix `doctbase-`.
- Quyền: management chạy user `doctbase-management`; một polkit rule chỉ cho phép thao tác trên unit `doctbase-*`:
  ```js
  polkit.addRule(function(action, subject) {
    if (subject.user !== "doctbase-management") return;
    if (action.id !== "org.freedesktop.systemd1.manage-units" &&
        action.id !== "org.freedesktop.systemd1.manage-unit-files") return;
    var unit = action.lookup("unit");
    if (unit && (unit === "doctbase.target" || unit.indexOf("doctbase-") === 0)) return polkit.Result.YES;
  });
  ```
- Logs: management user thuộc group `systemd-journal` để đọc journal; đây là quyền đọc log hệ thống, chấp nhận được trên VPS single-tenant. Nếu muốn siết hơn, dùng file log riêng + logrotate.
- `ComposeDriver` gọi `docker compose` trên host (CLI) hoặc Docker API qua socket proxy opt-in. Dashboard Docker mặc định chỉ hiển thị trạng thái.
- `DevDriver` chạy child process foreground, log prefix theo service, Ctrl-C graceful shutdown; chỉ dùng cho `doctbase dev`, không dùng production.

**Service Manager trong V1**: đây là lớp control-plane adapter gọi các driver trên, cộng registry service, health probe, cache trạng thái và operation lock. systemd/Compose vẫn là lifecycle owner; không có process supervisor mới. Chi tiết quyết định, interface và failure mode tại [research.md §15](../specs/001-doctbase-install-config/research.md#15-service-manager--control-plane-lifecycle-adapter).

#### Điều này có làm dashboard yếu?

Không. Dashboard vẫn có thể:

- Xem trạng thái, health, log, metrics.
- Restart service (native qua polkit).
- Bật/tắt optional service (native qua systemd).
- Apply config, rotate key, backup.
- Với Docker, hiển thị lệnh tương ứng hoặc yêu cầu bật socket proxy nếu muốn thao tác trực tiếp.

Đây là đánh đổi có chủ đích: **không đánh đổi độ ổn định của hệ thống lấy một nút bấm trong dashboard**.

### 4.6. Network, port và Unix socket

Bảng dưới đây mô tả **chế độ native**. Ở chế độ Docker, các service dùng TCP trong private network (`gateway:8080`, `management:8080`, …) và service discovery bằng DNS của Compose; chỉ Caddy publish 80/443.

| Thành phần | Giao tiếp | Public? |
|------------|-----------|---------|
| Caddy | 0.0.0.0:80, 0.0.0.0:443 | Có |
| Gateway | `/run/doctbase/gateway.sock` | Không |
| Management | `/run/doctbase/management.sock` | Không (qua site `admin.<domain>`) |
| Auth | `/run/doctbase/auth.sock` | Không |
| REST | `/run/doctbase/rest.sock` | Không |
| Realtime | `/run/doctbase/realtime.sock` | Không (Caddy route WebSocket) |
| Storage | `/run/doctbase/storage.sock` | Không |
| Image Proxy | `/run/doctbase/image-proxy.sock` | Không |
| PG Meta | `/run/doctbase/pg-meta.sock` | Không |
| PgBouncer | `/run/doctbase/pgbouncer.sock` | Không |
| PostgreSQL | `/var/run/postgresql/.s.PGSQL.5433` | Không |

**Lợi ích:**

- Không có port nội bộ nào để quét hoặc xung đột.
- Service discovery đơn giản: đường dẫn cố định, không cần Consul/etcd.
- Phân quyền bằng filesystem (`0660`, group `doctbase`).
- Debug dễ: `curl --unix-socket /run/doctbase/auth.sock http://localhost/healthz`.
- Docker dùng private network + DNS service name; native dùng UDS.

**Quy tắc:** gateway strip mọi header `X-Doctbase-*` từ bên ngoài; chỉ gateway được thêm identity headers (`X-Doctbase-Project`, `X-Doctbase-User`, `X-Doctbase-Role`, `X-Doctbase-Request-Id`). Service nội bộ chỉ tin request đến từ UDS + internal token.

### 4.7. Caddy, TLS và domain

- Caddy là edge: TLS/ACME, HTTP/2/3, nén, header bảo mật, reverse proxy.
- Gateway Zig là application edge: routing theo project/host, CORS, rate limit, xác thực API key/JWT, request logging.
- **Không** để Caddy làm auth; **không** để gateway tự làm ACME.

#### Domain model

- `admin.<domain>` → Management + Dashboard.
- `<project>.<domain>` → Gateway (REST/Auth/Storage/Image Proxy).
- WebSocket `/realtime/v1/*` → Caddy route trực tiếp tới Realtime UDS; Realtime tự xác thực JWT và origin. Lý do: tránh phải viết WebSocket proxy trong gateway; Caddy đã làm rất tốt.
- Custom domain cho project: thêm site block + DNS verify; Phase 4/5.
- Không có domain: `proxy.mode = "none"`, gateway/management bind `127.0.0.1:8080`; truy cập qua SSH tunnel. Phù hợp dev/LAN, không khuyến nghị production.

#### TLS modes

| Mode | Dùng khi | Hành vi |
|------|----------|---------|
| `auto` | Production có domain public | Caddy tự xin/renew cert qua ACME |
| `internal` | Dev/local | Caddy local CA; `caddy trust` nếu muốn tin |
| `off` | Sau reverse proxy/LB khác | Caddy không làm TLS; gateway bind localhost |
| `custom` | Cert doanh nghiệp | Trỏ cert/key trong config advanced |

#### DNS

- Với mỗi host cụ thể, Caddy dùng HTTP-01/TLS-ALPN; chỉ cần bản ghi A/AAAA trỏ về VPS.
- Có thể tạo `*.example.com` A record để mọi project host resolve, nhưng Caddy vẫn xin cert cho từng host cụ thể (không cần DNS API).
- Wildcard cert (`*.example.com`) cần DNS-01 + Caddy build có plugin DNS provider; để sau.
- `doctbase domain add` kiểm tra DNS, hiển thị bản ghi cần tạo, cho phép `--skip-dns-check`.

### 4.8. PostgreSQL và PgBouncer

#### Cluster và role

- Một cluster PostgreSQL 18 riêng cho toàn bộ Doctbase.
- Control DB `doctbase`; mỗi project một DB `doctbase_<slug>_<shortid>`.
- Role toàn cluster:
  - `doctbase_admin` — quản trị control plane, tạo DB/role.
  - `doctbase_meta` — DDL trên project DB.
  - `pgbouncer_auth` — chỉ dùng cho auth_query.
  - `p_<slug>_owner` — owner schema `public` của project (NOLOGIN).
  - `p_<slug>_authenticator` — role login qua PgBouncer, `SET ROLE` sang các role con.
  - `p_<slug>_anon`, `p_<slug>_authenticated`, `p_<slug>_service`, `p_<slug>_auth`, `p_<slug>_storage`.
- Không cấp `SUPERUSER`, không cấp `BYPASSRLS` cho role ứng dụng; chỉ role service nội bộ mới có quyền cao.

#### RLS

- Bật RLS trên bảng ứng dụng; mặc định default-deny.
- `FORCE ROW LEVEL SECURITY` cho bảng nếu owner không được bypass (cẩn thận với migration).
- REST service chạy mỗi request trong transaction:
  ```sql
  BEGIN;
  SET LOCAL role = 'p_myapp_authenticated';
  SELECT set_config('request.jwt.claims', '{"sub":"...","role":"authenticated",...}', true);
  -- query
  COMMIT;
  ```
- `auth.uid()` / `auth.role()` là helper đọc `request.jwt.claims`.
- Service role key dùng role `p_<slug>_service` có quyền cao; không bao giờ phát cho client.
- Test RLS tự động: cross-project, cross-user, anonymous, service.

#### PgBouncer sizing

| Tham số | Giá trị mặc định | Ghi chú |
|---------|------------------|---------|
| `pool_mode` | `transaction` | Phù hợp API/REST; realtime dùng direct |
| `max_client_conn` | 1000 | Tăng theo tải |
| `default_pool_size` | 10 | Mỗi project/user |
| `max_db_connections` | 20/project | Tránh một project chiếm hết |
| `reserve_pool_size` | 5 | Burst |
| `query_wait_timeout` | 30s | Fail nhanh |
| `server_idle_timeout` | 300s | Giải phóng connection |
| `client_idle_timeout` | 300s | Tránh treo |
| `idle_transaction_timeout` | 60s | Tránh treo transaction |
| `max_prepared_statements` | 200 | Tương thích driver |
| `auth_type` | `scram-sha-256` | Không dùng md5/trust |

#### Ai kết nối trực tiếp PostgreSQL?

| Service | Kết nối | Lý do |
|---------|---------|-------|
| Management | PgBouncer hoặc direct | Migration/control plane; direct khi DDL |
| Auth | PgBouncer | Runtime auth; direct khi migration |
| REST | PgBouncer | Transaction pooling + `SET LOCAL` |
| Storage | PgBouncer | Metadata; file I/O local/S3 |
| PG Meta | Direct | DDL/introspection dài, tránh pool |
| Realtime | Direct | `LISTEN/NOTIFY` không hợp transaction pooling |
| Backup | Direct | `pg_dump` cần session ổn định |

### 4.9. Mô hình cấu hình

Có **4 lớp**, phân biệt rõ:

```text
1. Instance config        /etc/doctbase/doctbase.toml        (người dùng sửa)
2. Control-plane state    PostgreSQL database "doctbase"      (project, key, domain)
3. Secrets                /etc/doctbase/secrets/*             (sinh tự động)
4. Generated artifacts    /etc/doctbase/generated/*           (do not edit)
```

#### Vì sao không đưa project vào TOML?

- Project là dữ liệu động, được tạo/xóa qua CLI/API/dashboard; lưu trong DB hợp lý hơn.
- Tránh file lock khi nhiều thao tác đồng thời.
- Backup control DB là đủ; vẫn có `doctbase project export` để đưa về TOML/JSON cho GitOps.

#### Precedence

- Instance setting: **CLI flag > env > `doctbase.toml` > auto-detected default**.
- Project setting: **API/CLI > project DB > instance default**.
- Secrets: file/credential, không bao giờ từ TOML.

#### Định dạng: TOML

- Dễ đọc, có comment, không phụ thuộc indentation như YAML.
- Hỗ trợ table/array of tables, phù hợp config service.
- Có thể validate schema, báo lỗi line/column.
- Không dùng YAML vì parser Zig kém trưởng thành và lỗi indentation khó chẩn đoán.
- Không dùng JSON vì không comment/trailing comma, kém thân thiện.
- Kế hoạch: evaluate `zig-toml`; nếu chưa đủ ổn định, implement subset TOML 1.0 cần thiết trong `packages/config` với test đầy đủ. Không tự viết parser đầy đủ nếu có thể vendor.

#### Schema và migration

- `schema_version = 1`.
- Unknown key → error kèm gợi ý (Levenshtein), tránh typo âm thầm.
- `doctbase config migrate` nâng schema; backup file trước.
- `doctbase config show --resolved` in toàn bộ giá trị sau default/override.
- `doctbase config diff` in thay đổi so với trạng thái đang chạy.
- `doctbase config render` in generated artifacts ra stdout (không ghi file).
- `doctbase config explain <key>` giải thích key, default, range, ví dụ.

#### Apply pipeline

```text
doctbase apply
  ├─ load + validate config
  ├─ load control DB state
  ├─ render desired artifacts vào staging
  ├─ diff với current
  ├─ nếu không đổi: exit 0
  ├─ backup current artifacts
  ├─ atomic rename
  ├─ validate Caddyfile (caddy validate / POST /adapt)
  ├─ reload Caddy qua admin API
  ├─ reload PgBouncer (SIGHUP)
  ├─ restart service có config hash đổi
  ├─ chạy migration nếu cần
  └─ health check; fail thì rollback artifacts + reload
```

- `--dry-run` chỉ render + diff.
- `--yes` cho CI.
- `--json` cho automation.
- Mọi thao tác ghi đều có lock `/run/doctbase/apply.lock`.

### 4.10. Secrets

- Sinh tự động, không có default password.
- Lưu file 0600; native dùng systemd credentials; Docker dùng Compose secrets.
- Không đưa secret vào:
  - `doctbase.toml`
  - environment variable (trừ trường hợp `_FILE`)
  - log
  - dashboard API response
  - URL
- `doctbase secret ls` chỉ hiện tên, tuổi, service dùng.
- `doctbase secret rotate <name>`:
  - Sinh giá trị mới.
  - Với JWT key: publish new public key, sign new tokens bằng key mới, verify key cũ đến khi token cũ hết hạn.
  - Với API key: cho phép overlap 24h; dashboard hiển thị key cũ sắp hết hạn.
  - Với DB password: `ALTER ROLE ... PASSWORD`, cập nhật credential, restart service liên quan.
- `doctbase secret show --reveal` yêu cầu xác nhận và chỉ dành cho admin local.

### 4.11. Project provisioning và cô lập

#### Mô hình: database-per-project

| Tiêu chí | Database-per-project | Schema-per-project | Shared schema + project_id |
|----------|----------------------|--------------------|----------------------------|
| Cô lập bảo mật | Cao | Trung bình | Thấp, phụ thuộc RLS |
| Backup/restore riêng | Dễ | Khó | Rất khó |
| Drop project sạch | Dễ | Trung bình | Khó |
| Số connection | Nhiều hơn | Ít | Ít |
| PgBouncer | Entry/project | Một entry | Một entry |
| Phù hợp V1 | **Có** | Tương lai | Không |

Chọn **database-per-project** vì:

- Ranh giới bảo mật rõ, không có query cross-project ngoài ý muốn.
- Backup/restore/drop độc lập.
- Dễ giải thích với người dùng.
- PgBouncer hỗ trợ entry riêng + pool limit.
- Số project trên một VPS dự kiến < 100; overhead chấp nhận được.

#### Luồng `doctbase project create`

```text
1. Validate slug/domain/services
2. Insert project row (status = provisioning)
3. CREATE DATABASE ... TEMPLATE template_doctbase
4. Tạo role project + grant
5. Gọi Auth internal API sinh JWT keypair; Auth lưu private key, trả public key/JWKS cho management
6. Sinh publishable/secret API key; lưu hash
7. Tạo bucket mặc định (nếu bật storage)
8. Render PgBouncer entry + Caddy site block + projects.json
9. Reload PgBouncer/Caddy/Gateway
10. Health check: DB qua pool, auth, storage
11. status = active; in URL + key một lần
12. Audit log
```

- Mục tiêu ≤ 10 giây/project.
- Nếu fail: drop DB/role/file/config entry; status = failed; không để rác.
- `project delete` mặc định soft-delete + revoke key + tắt route; `--purge` mới drop DB, sau khi backup và xác nhận slug.
- `project export` xuất TOML/JSON không chứa secret; `project import` tạo lại, secret sinh mới hoặc cung cấp qua file.

#### Tài nguyên và noisy neighbor

- Per-project DB connection limit qua PgBouncer.
- `statement_timeout`, `idle_in_transaction_session_timeout` mặc định.
- Storage quota optional (mặc định unlimited; dashboard hiển thị usage).
- Rate limit per project (mặc định 600 req/min).
- CPU/RAM không cô lập hoàn toàn giữa project trên cùng service; V1 chấp nhận, ghi rõ. Phase 6 có thể dùng cgroup per service hoặc per project.
- Không hứa HA/multi-node trong V1.

### 4.12. Giao thức nội bộ

**Chốt:** HTTP/1.1 + JSON trên Unix socket; WebSocket cho realtime; `httpz` làm HTTP server.

| Hạng mục | Quyết định |
|----------|------------|
| Transport | Unix domain socket native; TCP private network Docker |
| Serialization | JSON (UTF-8) |
| HTTP stack | `http.zig` (httpz), pin commit tương thích Zig 0.17.1 |
| WebSocket | httpz WebSocket cho realtime; Caddy route trực tiếp |
| Service discovery | Đường dẫn UDS cố định + `projects.json`; Compose DNS |
| Internal auth | Bearer token + peer credentials; gateway strip header ngoài |
| Health | `GET /healthz`, `/readyz`, `/metrics`, `/internal/v1/info` |
| Errors | RFC 9457 Problem Details + `code`, `request_id` |
| Versioning | `/v1` public, `/internal/v1` nội bộ |
| Timeout | Gateway 30s; upload 10m; realtime ping 30s |
| Retry | Chỉ idempotent; exponential backoff có jitter |
| Tracing | `X-Request-Id`; OpenTelemetry để Phase 6 |

**Vì sao không dùng gRPC?**

- Không cần streaming hai chiều ngoài WebSocket.
- Tooling/debug với curl/JSON đơn giản hơn.
- Ít dependency và ít code generation hơn.
- HTTP/1.1 trên UDS đủ nhanh cho single-VPS.

**Vì sao không dùng message bus (NATS/Redis)?**

- Thêm service, thêm cấu hình, thêm lỗi.
- V1 single-node: `LISTEN/NOTIFY` + in-memory presence đủ.
- Khi cần multi-node, có thể thêm sau mà không đổi public API.

### 4.13. Dashboard

**Chốt:** SvelteKit + TypeScript + Tailwind + shadcn-svelte, build static, nhúng vào management binary.

| Tiêu chí | SvelteKit static | Next.js | React SPA |
|----------|------------------|---------|-----------|
| Runtime Node | Không | Có/SSR | Không |
| Bundle | Nhỏ | Lớn hơn | Trung bình |
| Nhúng binary | Dễ (`@embedFile`) | Khó hơn | Dễ |
| DX | Tốt | Tốt | Tốt |
| Hệ sinh thái component | Tốt | Rất tốt | Rất tốt |
| Phù hợp dashboard nội bộ | **Có** | Overkill | Có |

**Kiến trúc:**

- `dashboard/` build ra `dashboard/dist`; Zig build copy vào `apps/management/assets` và `@embedFile` (hoặc serve từ `/usr/share/doctbase/dashboard` nếu binary lớn).
- SPA fallback `index.html`; API client generate từ OpenAPI.
- Auth: session cookie HttpOnly/Secure/SameSite=Lax; CSRF token; không lưu JWT trong localStorage.
- Setup token dùng một lần; forced password change.
- Pages V1: Overview, Projects, Project detail (keys/domains/services/usage), Services (status/restart/logs), Database (pg-meta), Storage, Settings, Audit log.
- Logs: SSE từ management; không cần WebSocket.
- Charts: dữ liệu live + ring buffer 1h; Prometheus optional cho lịch sử dài.
- i18n: EN mặc định, VI là bản dịch đầu tiên.
- Không billing/plans.

**Vì sao nhúng vào management?**

- Không thêm service/container.
- Không cần Node runtime.
- Cùng origin với Management API → cookie/CSRF đơn giản.
- Version dashboard luôn khớp management.

### 4.14. Backup, restore và upgrade

Đây là phần dễ bị xem nhẹ khi thiết kế “cài cho dễ”, nhưng lại quyết định người dùng có dám chạy production hay không.

#### Backup gồm những gì?

| Thành phần | Cách lấy | Ghi chú |
|------------|----------|---------|
| Control DB `doctbase` | `pg_dump -Fc` qua direct connection | projects, keys hash, domains, audit |
| Từng project DB | `pg_dump -Fc` song song có giới hạn | Consistency theo từng DB |
| Storage files | `tar`/`rsync` từ `/var/lib/doctbase/projects` | Có thể dùng `--link-dest` để tiết kiệm |
| Auth JWT keys | Copy `/var/lib/doctbase/auth/keys` | Bắt buộc nếu muốn token cũ còn hiệu lực |
| Config + generated | `doctbase.toml`, `generated/*`, `state.json` | Không gồm secret mặc định |
| Secrets (optional) | `secrets/*` | Chỉ khi `--include-secrets`; nên mã hóa |
| Manifest | JSON: version, timestamp, checksums, sizes | Dùng để verify/restore |

- Mặc định backup local vào `/var/lib/doctbase/backups/<timestamp>/`.
- `doctbase backup --to <dir>` cho phép destination ngoài; V1 dùng `rclone`/`restic` nếu cần offsite.
- `--encrypt` dùng age (public key) hoặc restic; backup offsite **phải** mã hóa.
- Retention mặc định 7 daily + 4 weekly; `doctbase backup prune`.
- Schedule: systemd timer `doctbase-backup.timer` (native) hoặc cron/CLI (Docker).
- Backup trên cùng VPS **không phải** disaster recovery; docs phải nói rõ cần offsite.
- Backup cần đọc auth keys và secrets; chạy `doctbase backup` bằng `sudo` hoặc systemd unit chạy quyền đủ, không chạy bằng user thường.

#### Restore

```bash
doctbase restore /var/lib/doctbase/backups/2026-11-06T03-00-00Z
```

- Restore lên instance cùng version (hoặc version tương thích).
- Thứ tự: stop app services → restore control DB → restore project DBs → restore storage/auth keys → restore config → `doctbase apply` → start → health check.
- `--project <slug>` cho restore chọn lọc.
- Restore không tự động ghi đè nếu instance đang có data; yêu cầu `--force` + xác nhận.
- Sau restore: rotate secret nếu backup bị lộ; kiểm tra migration version; chạy `doctor`.
- Mục tiêu: RPO ≤ 24h mặc định; RTO ≤ 30 phút cho ≤ 10 GB. Test restore định kỳ.

#### Upgrade

```bash
doctbase upgrade --check
doctbase upgrade --to 1.1.0
doctbase upgrade --rollback
```

- Versioned install dirs + symlink `current`; binary cũ vẫn còn để rollback.
- Trước upgrade: backup tự động (control + project DB + storage + keys + config).
- Stop app target (không cần stop PostgreSQL/Caddy nếu không đổi major).
- Chạy migration có advisory lock; ghi `schema_migrations`.
- Swap symlink; start; health check; nếu fail: swap lại + restore backup.
- Không hứa zero-downtime trên single VPS; Caddy có thể trả trang 503 trong lúc upgrade.
- Auto-update mặc định tắt; chỉ thông báo version/security.
- Major upgrade yêu cầu `--major` và đọc release notes.

---

## 5. CLI UX

### 5.1. Command tree

```text
doctbase
├── install                 # cài hệ thống (native)
├── init                    # tạo config/dev environment
├── dev                     # chạy foreground cho phát triển
├── up | down | restart     # lifecycle
├── status                  # trạng thái tổng hợp
├── logs [service]          # xem log
├── apply                   # render + reload config
├── doctor                  # chẩn đoán + fix an toàn
├── config
│   ├── validate
│   ├── show [--resolved]
│   ├── diff
│   ├── render
│   ├── explain <key>
│   └── migrate
├── secret
│   ├── ls
│   ├── rotate <name>
│   └── show <name> --reveal
├── project
│   ├── create <slug>
│   ├── list
│   ├── show <slug>
│   ├── delete <slug> [--purge]
│   ├── rotate-key <slug>
│   ├── export [--all]
│   └── import <file>
├── domain
│   ├── add <host> --project <slug>
│   ├── remove <host>
│   └── status
├── admin
│   ├── reset-password
│   └── reset-setup
├── backup [--to <dir>]
├── restore <file>
├── upgrade [--check|--to <version>|--rollback]
├── support bundle
├── uninstall [--keep-data|--purge]
├── completion <shell>
└── version
```

### 5.2. Nguyên tắc output

- Human-readable mặc định; `--json` cho automation.
- Màu chỉ khi TTY; tôn trọng `NO_COLOR`.
- Progress từng bước, có thời gian; non-TTY in plain line.
- Không in secret trừ một lần khi tạo (API key, setup token); cảnh báo lưu ngay.
- Log cài đặt ghi `/var/log/doctbase/install.log`; màn hình chỉ hiện bước + lỗi.
- Exit code ổn định:

| Code | Ý nghĩa |
|------|---------|
| 0 | Thành công |
| 1 | Lỗi chung |
| 2 | Dùng sai CLI/config |
| 3 | Preflight fail |
| 4 | Network/download fail |
| 5 | Database fail |
| 6 | Service fail |
| 7 | Migration fail |
| 8 | Permission fail |

- Error format:
  ```text
  error[DB_CONN_REFUSED]: Không kết nối được PostgreSQL qua Unix socket.
    cause: cluster "doctbase" chưa chạy
    fix:   sudo systemctl start postgresql@18-doctbase
    docs:  https://doctbase.dev/errors/DB_CONN_REFUSED
    id:    01J...
  ```

### 5.3. First-run experience

- Nếu chưa cài:
  - `doctbase` → hướng dẫn `doctbase install`.
- Nếu đã cài:
  - `doctbase` → `status`.
- Wizard chỉ hỏi:
  1. Domain (Enter để bỏ qua, dùng local mode).
  2. Email cho TLS (Enter để bỏ qua).
  3. Xác nhận cài.
- `--yes` bỏ qua tất cả, dùng default.
- Nếu phát hiện domain hợp lệ, không hỏi lại.
- Nếu port 80/443 bận, giải thích rõ và đề xuất `--proxy=external`; không tự kill.
- Nếu RAM < 2 GB, cảnh báo và đề xuất profile minimal.

### 5.4. `doctbase status` mẫu

```text
$ doctbase status
Doctbase 1.0.0  ● healthy   uptime 2h 14m
Domain: example.com        Mode: native        Data: /var/lib/doctbase

SERVICE          STATE    HEALTH   ENDPOINT                              VERSION
postgresql       running  ready    unix:/var/run/postgresql              18.6
pgbouncer        running  ready    unix:/run/doctbase/pgbouncer.sock      1.24
caddy            running  ready    :443                                   2.10
gateway          running  ready    unix:/run/doctbase/gateway.sock
management       running  ready    https://admin.example.com
auth             running  ready    unix:/run/doctbase/auth.sock
pg-meta          running  ready    unix:/run/doctbase/pg-meta.sock
storage          running  ready    unix:/run/doctbase/storage.sock
rest             off      -        -                                      optional
realtime         off      -        -                                      optional
image-proxy      off      -        -                                      optional

PROJECTS 3   LAST BACKUP 6h ago   DISK 12.4 / 40 GB   MEM 612 MB
```

### 5.5. `doctbase doctor` mẫu

```text
$ doctbase doctor
[✓] OS/arch: Ubuntu 24.04, x86_64
[✓] systemd: 255
[✓] RAM: 2.0 GB (recommended >= 2 GB)
[✓] Disk: 31 GB free
[✓] Clock sync: yes
[✓] PostgreSQL cluster: running, 18.6
[✓] PgBouncer: running, auth_query OK
[✓] Caddy: running, admin API OK
[✓] TLS: certificate valid, expires in 89 days
[✓] Services: 8/8 ready
[✓] Config: valid, no drift
[✓] Secrets: permissions OK
[!] Backup: last backup 6 days ago
    fix: sudo doctbase backup
[✓] Firewall: 22/80/443 open

1 warning, 0 errors.
```

### 5.6. `doctbase logs`

```bash
doctbase logs                 # tất cả, 100 dòng cuối
doctbase logs -f auth         # follow auth
doctbase logs --since 15m     # lọc thời gian
doctbase logs --json          # raw JSON
```

- Native: đọc journald (`journalctl -u doctbase-auth`).
- Docker: `docker compose logs`.
- Dev: file/foreground.
- Không hiển thị secret; redact `authorization`, `apikey`, `password`, `token`.

---

## 6. Mẫu cấu hình và artifact

### 6.1. `/etc/doctbase/doctbase.toml` (mẫu tối giản)

```toml
# Mọi giá trị đều có mặc định. Chỉ sửa những gì bạn muốn.
schema_version = 1

[instance]
name = "doctbase"
domain = "example.com"          # bỏ trống => local mode (SSH tunnel)
admin_email = "admin@example.com" # optional, dùng cho ACME
timezone = "Asia/Ho_Chi_Minh"

[database]
mode = "managed"                # managed | external
max_connections = 200
# url_file = "/etc/doctbase/secrets/database_url"  # chỉ khi mode = "external"

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

**Ghi chú:**

- `domain` rỗng không làm install fail; chỉ chuyển sang local mode.
- `admin_email` rỗng vẫn dùng ACME được; chỉ không nhận email hết hạn cert.
- `[services]` chỉ bật/tắt instance-level; project-level có toggle riêng trong dashboard/API.
- `database.mode = "external"` dùng cho người đã có PostgreSQL; connection URL nằm trong secret file, không nằm trong TOML.

### 6.2. Project export (doctbase project export)

```toml
schema_version = 1
slug = "myapp"
name = "My App"
domain = "myapp.example.com"
services = ["auth", "storage", "rest"]
allowed_origins = ["https://myapp.com", "http://localhost:3000"]
```

- Không chứa secret.
- Import sẽ sinh key mới hoặc đọc key từ file được cung cấp.

### 6.3. Caddyfile generated cho native (rút gọn)

```caddyfile
{
  email admin@example.com
  admin unix//run/doctbase/caddy-admin.sock
}

admin.example.com {
  encode zstd gzip
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    Referrer-Policy "strict-origin-when-cross-origin"
  }
  reverse_proxy unix//run/doctbase/management.sock
}

myapp.example.com {
  encode zstd gzip

  @realtime path /realtime/v1/*
  reverse_proxy @realtime unix//run/doctbase/realtime.sock

  reverse_proxy unix//run/doctbase/gateway.sock
}
```

- Mỗi project một site block; `doctbase apply` render + reload.
- WebSocket route trực tiếp realtime; realtime tự xác thực JWT/origin.
- Bản Docker của Caddyfile dùng upstream TCP (`gateway:8080`, `management:8080`) và `admin 0.0.0.0:2019` trong network nội bộ; không publish 2019.
- Nếu dùng external proxy, in snippet tương đương cho Nginx/Traefik. Nếu proxy ngoài không hỗ trợ Unix socket, `proxy.mode = "external"` sẽ bind gateway/management ra `127.0.0.1` TCP để proxy chuyển tiếp.

### 6.4. PgBouncer generated (rút gọn)

```ini
[databases]
doctbase_myapp_01j = host=/var/run/postgresql port=5433 dbname=doctbase_myapp_01j pool_size=10 max_db_connections=20
doctbase_blog_01k  = host=/var/run/postgresql port=5433 dbname=doctbase_blog_01k  pool_size=10 max_db_connections=20

[pgbouncer]
listen_addr =
unix_socket_dir = /run/doctbase
unix_socket_mode = 0660
unix_socket_group = doctbase
listen_port = 6432
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 10
reserve_pool_size = 5
query_wait_timeout = 30
server_idle_timeout = 300
client_idle_timeout = 300
idle_transaction_timeout = 60
max_prepared_statements = 200
auth_type = scram-sha-256
auth_user = pgbouncer_auth
auth_file = /var/lib/doctbase/pgbouncer/users.txt
auth_query = SELECT * FROM doctbase.pgbouncer_auth($1)
```

- Mẫu trên là native (PostgreSQL qua UDS). Bản Docker dùng `host=postgres port=5432` và `listen_addr = 0.0.0.0` trong private network.

### 6.5. systemd unit mẫu

```ini
# /etc/systemd/system/doctbase-auth.service
[Unit]
Description=Doctbase Auth
After=network-online.target doctbase-pgbouncer.service
Wants=network-online.target
PartOf=doctbase.target

[Service]
Type=notify
# Nếu service chưa hỗ trợ sd_notify, đổi Type=exec và bỏ WatchdogSec.
User=doctbase-auth
Group=doctbase
ExecStart=/usr/local/lib/doctbase/current/bin/doctbase-auth --config /etc/doctbase/doctbase.toml
Restart=on-failure
RestartSec=2s
TimeoutStopSec=30s
# WatchdogSec=30s
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/run/doctbase /var/lib/doctbase/auth
LoadCredential=internal_token:/etc/doctbase/secrets/internal_token

[Install]
WantedBy=doctbase.target
```

```ini
# /etc/systemd/system/doctbase.target
[Unit]
Description=Doctbase
Wants=doctbase-gateway.service doctbase-management.service doctbase-auth.service
After=network-online.target postgresql@18-doctbase.service doctbase-pgbouncer.service

[Install]
WantedBy=multi-user.target
```

### 6.6. Docker Compose skeleton (rút gọn)

```yaml
name: doctbase

x-service: &service
  restart: unless-stopped
  read_only: true
  tmpfs: [/tmp]
  cap_drop: [ALL]
  security_opt: [no-new-privileges:true]
  networks: [backend]

services:
  postgres:
    image: postgres:18@sha256:...
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_admin
    secrets: [postgres_admin]
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./config/postgres.conf:/etc/postgresql/conf.d/doctbase.conf:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks: [backend]

  pgbouncer:
    build: ./deploy/docker/pgbouncer
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro
      - ./secrets/pgbouncer_users.txt:/etc/pgbouncer/userlist.txt:ro
    networks: [backend]

  caddy:
    image: caddy:2@sha256:...
    ports: ["80:80", "443:443"]
    depends_on: [gateway, management]
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data/caddy:/data
      - ./data/caddy-config:/config
    networks: [edge, control]

  gateway:
    <<: *service
    image: ghcr.io/doctbase/gateway:1.0.0
    depends_on: [pgbouncer, management]
    volumes:
      - ./config:/etc/doctbase:ro
    networks: [backend, control]

  management:
    <<: *service
    image: ghcr.io/doctbase/management:1.0.0
    depends_on:
      postgres:
        condition: service_healthy
      pgbouncer:
        condition: service_healthy
    volumes:
      - ./config:/etc/doctbase
      - ./data:/var/lib/doctbase
    secrets: [internal_token, admin_setup_token]
    networks: [backend, control]

  auth:
    <<: *service
    image: ghcr.io/doctbase/auth:1.0.0
    depends_on: [pgbouncer, management]
    volumes:
      - ./config:/etc/doctbase:ro
      - ./data:/var/lib/doctbase
    secrets: [internal_token]

  storage:
    <<: *service
    image: ghcr.io/doctbase/storage:1.0.0
    depends_on: [pgbouncer, management]
    volumes:
      - ./config:/etc/doctbase:ro
      - ./data:/var/lib/doctbase
    secrets: [internal_token]

  pg-meta:
    <<: *service
    image: ghcr.io/doctbase/pg-meta:1.0.0
    depends_on: [pgbouncer, management]
    volumes:
      - ./config:/etc/doctbase:ro
    secrets: [internal_token]

  rest:
    <<: *service
    image: ghcr.io/doctbase/rest:1.0.0
    profiles: [rest]
    depends_on: [pgbouncer, auth]

  realtime:
    <<: *service
    image: ghcr.io/doctbase/realtime:1.0.0
    profiles: [realtime]
    depends_on: [postgres, auth]

  image-proxy:
    <<: *service
    image: ghcr.io/doctbase/image-proxy:1.0.0
    profiles: [image-proxy]
    depends_on: [storage]

secrets:
  postgres_admin:
    file: ./secrets/postgres_admin
  internal_token:
    file: ./secrets/internal_token
  admin_setup_token:
    file: ./secrets/admin_setup_token

networks:
  edge: {}
  control:
    internal: true
  backend:
    internal: true
```

**Lưu ý:**

- Đây là skeleton; compose thật sinh bởi `doctbase init --profile docker`, có healthcheck/volume/UID cụ thể.
- Dùng 3 network: `edge` cho Caddy ra Internet; `control` nội bộ chỉ Caddy + gateway + management (Caddy admin API); `backend` nội bộ cho PostgreSQL/PgBouncer/app. App service không vào được `control`.
- Caddy và management nói chuyện qua `http://caddy:2019` trên `control`; app nói chuyện qua DNS service name (`gateway:8080`, `auth:8080`, …) trên `backend`.
- Không publish PostgreSQL/PgBouncer/management.
- Các optional service dùng profile `rest`, `realtime`, `image-proxy`; core không có profile.

---

## 7. Các quyết định còn mở — ADR tóm tắt

### ADR-001 — Cô lập nhiều project

- **Quyết định:** database-per-project.
- **Lý do:** cô lập, backup/drop độc lập, PgBouncer pool riêng, dễ hiểu.
- **Hệ quả:** nhiều DB/connection hơn; cần giới hạn pool; template DB chuẩn.
- **Tương lai:** có thể thêm “shared schema mode” cho hàng trăm project nhỏ, nhưng không đổi default.

### ADR-002 — Dashboard

- **Quyết định:** SvelteKit static, nhúng management binary.
- **Lý do:** không Node runtime, không container, cùng origin, bundle nhỏ.
- **Hệ quả:** build pipeline cần pnpm; dashboard version khớp management.
- **Fallback:** nếu team mạnh React, dùng React + Vite; kiến trúc không đổi.

### ADR-003 — Giao thức nội bộ

- **Quyết định:** HTTP/1.1 + JSON trên UDS, httpz; WebSocket cho realtime.
- **Lý do:** đơn giản, debug tốt, đủ nhanh, ít dependency.
- **Hệ quả:** cần tự định nghĩa service protocol/health/error; không có gRPC codegen.
- **Tương lai:** có thể thêm gRPC cho internal nếu cần streaming hiệu năng cao.

### ADR-004 — Service supervisor

- **Quyết định:** systemd native / Compose Docker; `LifecycleDriver`; dev-runner foreground.
- **Lý do:** không viết lại hạ tầng, ổn định, hardening, logging, credentials.
- **Hệ quả:** dashboard lifecycle cần polkit (native) hoặc socket proxy opt-in (Docker).
- **Tương lai:** nếu cần chạy trên non-systemd distro, viết supervisor tối giản hoặc dùng s6.

### ADR-005 — Định dạng cấu hình

- **Quyết định:** TOML 1.0, một file instance; project state trong control DB; secrets tách riêng.
- **Lý do:** dễ đọc, comment, schema rõ, không lỗi indentation.
- **Hệ quả:** cần parser TOML ổn định; generated artifacts phải atomic.
- **Tương lai:** `doctbase project export/import` cho GitOps.

### ADR-006 — Nền tảng và version

- **Quyết định:** Zig 0.17.1; PostgreSQL 18; Debian 13/Ubuntu 24.04/26.04; x86_64/arm64.
- **Lý do:** ổn định tại thời điểm V1; httpz hỗ trợ 0.17; PG18 có `search_path` tracking trong PgBouncer.
- **Hệ quả:** chưa hỗ trợ RHEL/Windows native; CI matrix giới hạn.
- **Tương lai:** nâng Zig/PG theo release cycle, test compatibility trước.

---

## 8. Lộ trình triển khai gắn với tiêu chí “dễ”

### Phase 1 — Foundation

**Deliverables:**

- `packages/config`: schema TOML, defaults, validation, `show/diff/render/explain`.
- `packages/runtime`: shared service harness — bootstrap, config hash, health/ready/info/metrics, internal auth, graceful shutdown (chi tiết tại [research.md §14](../specs/001-doctbase-install-config/research.md#14-core-runtime--shared-service-harness)).
- `packages/service-protocol`: health/ready/metrics/error envelope/request ID.
- `packages/http`: wrapper httpz, router, middleware, UDS listener, JSON.
- `packages/service-lifecycle`: `LifecycleDriver` + registry + systemd/compose/dev/fake drivers; Service Manager adapter, không supervisor (chi tiết tại [research.md §15](../specs/001-doctbase-install-config/research.md#15-service-manager--control-plane-lifecycle-adapter)).
- CLI skeleton: `install/init/dev/status/logs/doctor/config`.
- Error code registry + docs links.
- Build/release skeleton: manifest, checksum, minisign.
- `doctbase.toml` sample + generated file headers.

**Gate:**

- `doctbase init` tạo config; `doctbase dev` chạy ít nhất 2 service qua UDS; `doctbase config validate/show/render` hoạt động; test schema.
- Runtime health/ready/info đúng; SIGTERM drain sạch; lifecycle driver test với fake driver; không có supervisor mới.

### Phase 2 — Infrastructure

**Deliverables:**

- Native installer (preflight, packages, users, dirs, secrets).
- PostgreSQL cluster riêng + tuning + template DB.
- PgBouncer UDS + auth_query + project entries.
- Caddy unit + Caddyfile render + reload API.
- systemd units/target + polkit rule + journald logs.
- `doctbase doctor` bản đầu.
- Backup/restore local.
- State file + uninstall.

**Gate:**

- Fresh Ubuntu 24.04 2 GB: một lệnh cài, health OK, ≤ 5 phút.
- Re-run install idempotent.
- Uninstall `--keep-data`/`--purge` sạch.
- Không đụng PostgreSQL 5432 sẵn có.

### Phase 3 — Management

**Deliverables:**

- Control DB schema + migrations.
- Management API (projects, services, config, logs, health, backup).
- Render pipeline `doctbase apply`.
- Dashboard shell + setup flow + auth session.
- Service lifecycle native (polkit) + status/logs.
- Project CRUD + rendered `projects.json` + Caddy/PgBouncer reload.
- Audit log.

**Gate:**

- Tạo project qua CLI và dashboard; project URL hoạt động.
- Restart service từ dashboard (native).
- Apply config invalid → không thay đổi; rollback.
- Logs stream hoạt động; audit log ghi nhận.

### Phase 4 — Core BaaS

**Deliverables:**

- Auth: JWT Ed25519/JWKS, Argon2id, sessions, API keys, OAuth optional.
- PG Meta: introspect/DDL an toàn, policies.
- Storage: local backend, bucket policy, signed URL, upload streaming.
- Project template: auth/storage schema, RLS helper, pgbouncer_auth function.
- REST optional skeleton (nếu kịp) hoặc Phase 5.
- RLS test suite.

**Gate:**

- Sample app: signup/login, CRUD có RLS, upload/download.
- Cross-project access denied.
- JWT key rotation hoạt động.
- Backup/restore project DB + storage.

### Phase 5 — Optional services

**Deliverables:**

- REST auto API + OpenAPI per project.
- Realtime WebSocket + LISTEN/NOTIFY + presence + broadcast.
- Image proxy (libvips) + cache + signed URL.
- Profiles `minimal/standard/full`; installer auto-select theo RAM.
- Dashboard bật/tắt optional service.

**Gate:**

- Bật/tắt service không ảnh hưởng core.
- Realtime 1k connection local; REST p95 acceptable; image cache hit.
- Resource usage trong ngân sách.

### Phase 6 — Deployment & Hardening

**Deliverables:**

- Docker Compose đầy đủ + profiles + healthcheck.
- Offline bundle native/Docker.
- Upgrade/rollback + migration backup.
- Security hardening: headers, rate limit, IP allowlist, secret rotation, SBOM, signed release.
- Test matrix VM + fault injection + restore drill.
- Docs: quickstart, config reference, troubleshooting, upgrade, security.

**Gate:**

- V1 release checklist pass.
- Install ≤ 5 phút; upgrade N-1 ≤ 3 phút downtime; restore ≤ 30 phút/10 GB.
- Không có secret trong log/config public; DB không public; TLS auto.

### “Installability budget” cho mọi phase

Mỗi feature mới phải trả lời:

- Có thêm **config key bắt buộc** không? Nếu có → phải có default.
- Có thêm **public port** không? Nếu có → phải qua Caddy, không mở trực tiếp.
- Có thêm **service bắt buộc** không? Nếu có → phải justify; optional phải có profile.
- Có thêm **secret** không? Nếu có → sinh tự động, có rotate.
- Có làm **first-run** chậm hơn 5 phút không? Nếu có → tối ưu hoặc tách optional.

---

## 9. Test và acceptance matrix

| # | Kịch bản | Môi trường | Kỳ vọng | Gate |
|---|----------|------------|---------|------|
| 1 | Fresh install có domain | Ubuntu 24.04, 2 vCPU/2 GB | Thành công ≤ 5 phút; dashboard TLS OK | C1/C2/C12 |
| 2 | Fresh install không domain | Ubuntu 24.04 | Local mode; SSH tunnel; không fail | C3 |
| 3 | Fresh install arm64 | Debian 13 arm64 | Thành công | Matrix |
| 4 | PostgreSQL sẵn có 5432 | Ubuntu 24.04 | Dùng cluster riêng 5433; không đụng dữ liệu cũ | C15 |
| 5 | Caddy/port 80 bận | Ubuntu 24.04 | Fail sớm, gợi ý `--proxy=external`/dừng service | C8 |
| 6 | DNS sai | Ubuntu 24.04 | Cảnh báo, in bản ghi; `--skip-dns-check` | C8 |
| 7 | RAM 1 GB | VM 1 GB | Cảnh báo/fail có hướng dẫn; không OOM | C14 |
| 8 | Disk 5 GB | VM | Fail sớm; không cài nửa vời | C8 |
| 9 | Chạy lại install 3 lần | VM | Idempotent; không mất dữ liệu | C6 |
| 10 | Upgrade N-1 → N | VM có data | Thành công; rollback khi inject fail | C10 |
| 11 | Restore backup | VM mới | DB + storage + config khôi phục | C10 |
| 12 | Uninstall keep-data | VM | Data còn; service/config sạch | C7 |
| 13 | Uninstall purge | VM | Không còn file/DB/user Doctbase | C7 |
| 14 | Docker compose fresh | 4 GB | Tất cả healthcheck pass ≤ 5 phút | Docker |
| 15 | Offline bundle | Air-gapped | Cài không cần Internet | C9 |
| 16 | Tạo 10 project | Native | ≤ 2 phút; không lỗi pool/role | C11 |
| 17 | Cross-project access | Native | 403/404; không rò dữ liệu | Security |
| 18 | RLS anonymous/user/service | Native | Đúng policy; service bypass có kiểm soát | Security |
| 19 | Kill auth service | Native | systemd restart; gateway 503 tạm; recovery | Resilience |
| 20 | PostgreSQL down | Native | Health degraded; không mất data; recovery | Resilience |
| 21 | Caddy reload invalid | Native | Config cũ tiếp tục chạy | Safety |
| 22 | Disk full | Native | Lỗi rõ; không corrupt DB | Safety |
| 23 | Config invalid | Native | Không apply; báo line/column | C8 |
| 24 | Secret rotate | Native | Token cũ hết hạn đúng; không downtime | Security |
| 25 | Realtime 1k conn | Native 2 GB | Ổn định; RAM trong ngân sách | Perf |
| 26 | Backup age warning | Native | Doctor cảnh báo | C8 |
| 27 | Log redaction | Native | Không lộ secret/token | Security |
| 28 | Port scan | Native | Chỉ 22/80/443 public | Security |

### 9.1. Test tự động

- **Unit:** config parser/schema, error mapping, render functions, URL signing, JWT, RLS SQL builders.
- **Integration:** Postgres + PgBouncer + Caddy + services trong Docker Compose; test migration/rollback.
- **E2E VM:** QEMU/Incus/Multipass hoặc cloud VM; chạy installer thật; đo thời gian.
- **Fault injection:** kill process, full disk, invalid DNS, port busy, DB auth fail, Caddy invalid config.
- **Security:** cross-project, JWT forgery, path traversal, SSRF image proxy, rate limit, header injection.
- **Restore drill:** định kỳ; đo RTO/RPO.
- **Performance baseline:** gateway overhead, req/s trên 2 vCPU, WS connections, upload throughput.

---

## 10. Rủi ro và cách giảm thiểu

| Rủi ro | Mức | Giảm thiểu |
|--------|-----|------------|
| Tự viết supervisor phức tạp | Cao | Không viết; dùng systemd/Compose; dev-runner đơn giản |
| Zig/httpz API churn | Trung bình | Pin Zig 0.17.1 + httpz commit; test compatibility trước upgrade |
| TOML parser chưa trưởng thành | Trung bình | Vendor/evaluate; test schema; fallback subset parser |
| PgBouncer transaction pooling gây lỗi session | Trung bình | Direct connection cho realtime/backup/pg-meta; test `SET LOCAL` |
| Database-per-project tốn connection | Trung bình | Pool limit/project; `max_connections`; monitor; future shared mode |
| Caddy wildcard/DNS plugin | Thấp | Dùng per-host cert; wildcard Phase 6 |
| Installer phá hệ thống sẵn có | Cao | Cluster/unit riêng; dry-run; không tự xóa; backup |
| Package version drift | Trung bình | PGDG/Caddy repo chính thức; state.json; doctor; Docker image pin digest |
| Dashboard scope creep | Trung bình | V1 pages cố định; không billing; optional metrics |
| Docker socket security | Cao | Không mount mặc định; socket proxy opt-in có allowlist |
| Single VPS failure | Cao | Backup/restore; không hứa HA; docs RTO/RPO |
| Image proxy C dependency | Thấp | Optional; libvips package; fallback external imgproxy |
| ACME rate limit | Thấp | Staging test; per-host cert; Caddy backoff |
| Secret leak qua log | Cao | Redaction; không log header/body nhạy cảm; test |
| RLS bypass do owner | Trung bình | `FORCE RLS`; test; role riêng; không dùng owner cho runtime |
| Upgrade migration fail | Cao | Backup + rollback; migration test; advisory lock |
| Multi-tenant noisy neighbor | Trung bình | Rate limit, pool limit, statement timeout; docs; future cgroups |

---

## 11. Kết luận và bước tiếp theo

### 11.1. Kết luận

- Doctbase có thể đạt trải nghiệm cài đặt gần PocketBase **mà vẫn giữ PostgreSQL nguyên bản và microservices**, bằng cách:
  - Ẩn hạ tầng sau một CLI.
  - Dùng Unix socket thay vì mở port nội bộ.
  - Sinh secrets và generated config tự động.
  - Dùng systemd/Compose thay vì viết lại supervisor.
  - Database-per-project để cô lập và dễ backup/drop.
  - Dashboard static nhúng, không thêm runtime.
- “Dễ” phải là **acceptance test**, không chỉ là tài liệu: ≤ 5 phút cài, ≤ 60 giây đến API đầu tiên, 0 file bắt buộc phải sửa, 1 lệnh/project.

### 11.2. Việc cần làm ngay trong Foundation

1. Chốt 6 ADR ở mục 7 và ghi vào repo `docs/adr/`.
2. Dựng spike:
   - `doctbase install --dry-run` trên Ubuntu 24.04.
   - `doctbase init` + `doctbase dev` với ≥ 2 service UDS, health/ready và graceful shutdown.
   - `doctbase config validate/show/render`.
   - `doctbase project create` tạo DB + role + PgBouncer entry + Caddy site.
   - Service Manager: status/restart qua `SystemdDriver` trên VM và `FakeDriver` trong test; không supervisor mới.
3. Đo thời gian thật trên VPS 2 GB; nếu > 5 phút, cắt bớt bước/package.
4. Viết test matrix Phase 1–2 trước khi làm dashboard.
5. Tạo `docs/quickstart.md` một trang và dùng nó làm acceptance test cho người mới.

### 11.3. Tiêu chí “không được phá”

- Không thêm public port ngoài 80/443.
- Không có mật khẩu mặc định.
- Không có config bắt buộc ngoài domain tùy chọn.
- Không có service optional bật mặc định.
- Không có process supervisor mới ngoài systemd/Compose.
- Không có thao tác phá hủy mà không backup/xác nhận.
- Không có “internal error” không có mã lỗi.

---

## 12. Nguồn tham khảo

Truy cập ngày 06/11/2026.

1. Supabase — Self-Hosting with Docker: https://supabase.com/docs/guides/self-hosting/docker  
2. Supabase — Docker Compose chính thức (2026.11.02): https://github.com/supabase/supabase/blob/master/docker/docker-compose.yml  
3. Supabase — Self-Hosting overview: https://supabase.com/docs/guides/self-hosting  
4. Appwrite — Installation (self-hosting): https://appwrite.io/docs/advanced/self-hosting/installation  
5. Appwrite — Appwrite 2.0 self-hosting: https://appwrite.io/blog/post/appwrite-2-self-hosted  
6. PocketBase — GitHub: https://github.com/pocketbase/pocketbase  
7. PocketBase — FAQ (single server, 10k realtime connections): https://pocketbase.io/faq  
8. Coolify — So sánh và yêu cầu: https://coolify.io/compare/coolify-vs-dokploy  
9. Dokploy — Installation: https://docs.dokploy.com/docs/core/installation  
10. Caddy — Automatic HTTPS: https://caddyserver.com/docs/automatic-https  
11. Caddy — Admin API: https://caddyserver.com/docs/api  
12. Caddy — Caddyfile: https://caddyserver.com/docs/caddyfile  
13. PgBouncer — Configuration: https://www.pgbouncer.org/config.html  
14. PostgreSQL 18 — Row Security Policies: https://www.postgresql.org/docs/current/ddl-rowsecurity.html  
15. systemd — Credentials: https://systemd.io/CREDENTIALS  
16. Docker Compose — Profiles: https://docs.docker.com/compose/how-tos/profiles/  
17. Zig — Download (0.17.1 stable, 2026-11-02): https://ziglang.org/download/  
18. http.zig — HTTP/1.1 server cho Zig 0.17: https://github.com/karlseguin/http.zig  
19. RFC 9457 — Problem Details for HTTP APIs: https://www.rfc-editor.org/rfc/rfc9457  
20. OpenAPI 3.1: https://spec.openapis.org/oas/v3.1.0  
21. OWASP ASVS: https://owasp.org/www-project-application-security-verification-standard/  
22. The Twelve-Factor App — Config: https://12factor.net/config  

---

## Phụ lục A — Checklist cài đặt một trang

```text
[ ] VPS: Debian 13 / Ubuntu 24.04 hoặc 26.04, x86_64/arm64
[ ] RAM >= 2 GB, disk >= 20 GB, swap 2 GB (khuyến nghị)
[ ] DNS: A admin.example.com -> IP; A *.example.com -> IP (hoặc từng project)
[ ] Port 80/443 trống
[ ] Chạy: curl -fsSL https://get.doctbase.dev | sudo sh -s -- --domain example.com --email admin@example.com --yes
    (hoặc audited: tải install.sh, xem, rồi sudo sh install.sh --domain ... --yes)
[ ] Mở setup URL, tạo admin
[ ] sudo doctbase project create myapp --services auth,storage,rest
[ ] Copy API URL + publishable key
[ ] curl https://myapp.example.com/auth/v1/health
[ ] sudo doctbase doctor
[ ] sudo doctbase backup
```

## Phụ lục B — Mã lỗi đề xuất

| Mã | Ý nghĩa | Hành động |
|----|--------|-----------|
| `PREFLIGHT_OS_UNSUPPORTED` | OS/arch ngoài matrix | Dùng Ubuntu/Debian hỗ trợ hoặc Docker |
| `PREFLIGHT_PORT_BUSY` | 80/443 bị chiếm | Dừng service hoặc `--proxy=external` |
| `PREFLIGHT_DNS_MISMATCH` | DNS không trỏ đúng | Sửa A/AAAA hoặc `--skip-dns-check` |
| `PREFLIGHT_DISK_LOW` | Disk thấp | Giải phóng dung lượng |
| `PREFLIGHT_RAM_LOW` | RAM thấp | Tăng RAM/swap hoặc profile minimal |
| `PKG_INSTALL_FAILED` | apt/repo lỗi | Xem install log; kiểm tra network/repo |
| `DB_CLUSTER_FAILED` | Tạo/khởi động cluster lỗi | Xem PostgreSQL log; `doctor` |
| `DB_AUTH_FAILED` | Sai password/role | Kiểm tra secret; rotate |
| `PGBOUNCER_AUTH_FAILED` | auth_query/lỗi SCRAM | Kiểm tra function/userlist |
| `CADDY_CONFIG_INVALID` | Caddyfile lỗi | `doctbase config render`; sửa TOML |
| `CADDY_ACME_FAILED` | Xin cert lỗi | Kiểm tra DNS/port 80/443/clock |
| `SERVICE_NOT_READY` | Service không ready | `doctbase logs <service>` |
| `CONFIG_INVALID` | Config sai schema/giá trị | Sửa theo line/column |
| `CONFIG_DRIFT` | Generated file bị sửa tay | `doctbase apply` |
| `MIGRATION_FAILED` | Migration lỗi | Restore backup; xem log |
| `SECRET_PERMISSION` | Secret sai quyền | `doctbase doctor --fix` |
| `DISK_FULL` | Hết disk | Giải phóng; kiểm tra backup/cache |
| `BACKUP_FAILED` | Backup lỗi | Kiểm tra quyền/destination |
| `RESTORE_FAILED` | Restore lỗi | Kiểm tra version/manifest |
| `UPGRADE_ROLLBACK` | Upgrade fail, đã rollback | Xem support bundle |
| `DOCKER_NOT_AVAILABLE` | Docker/Compose thiếu | Cài Docker hoặc dùng native |
| `DOCKER_PERMISSION` | Không có quyền Docker | Thêm user vào group hoặc dùng sudo |

## Phụ lục C — Cấu trúc repo đề xuất (bổ sung)

```text
doctbase/
├── apps/
│   ├── gateway/
│   ├── management/
│   │   └── assets/              # dashboard build (generated)
│   ├── auth/
│   ├── rest/
│   ├── realtime/
│   ├── storage/
│   ├── image-proxy/
│   └── pg-meta/
├── packages/
│   ├── core/
│   ├── http/
│   ├── postgres/
│   ├── config/
│   ├── security/
│   ├── telemetry/
│   ├── service-protocol/
│   ├── service-lifecycle/       # systemd/compose/dev drivers
│   ├── migrations/              # SQL embedded
│   └── imaging/                 # libvips FFI (optional)
├── dashboard/                   # SvelteKit source
├── infrastructure/
│   ├── postgres/
│   ├── pgbouncer/
│   └── caddy/
├── deploy/
│   ├── native/
│   │   ├── install.sh
│   │   ├── units/
│   │   └── polkit/
│   └── docker/
│       ├── compose.yml
│       └── pgbouncer/Dockerfile
├── docs/
│   ├── quickstart.md
│   ├── config-reference.md
│   ├── upgrade.md
│   ├── backup-restore.md
│   ├── troubleshooting.md
│   └── adr/
├── tests/
│   ├── integration/
│   ├── e2e/
│   └── fixtures/
├── tools/
│   ├── release.zig
│   └── manifest.zig
├── build.zig
└── build.zig.zon
```

---

*Tài liệu này là đề xuất nghiên cứu, không phải cam kết cuối cùng. Các con số thời gian/RAM là mục tiêu acceptance, cần được đo lại trên VPS thật trước khi chốt V1.*
