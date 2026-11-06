# Amendment đề xuất: External managed proxy (Coolify/Traefik) cho Docker mode

**Ngày đề xuất**: 2026-11-06

**Feature**: [`specs/002-coolify-resource`](../../../specs/002-coolify-resource/spec.md)

**Trạng thái**: Đề xuất — chờ duyệt

**Phiên bản đề xuất**: 1.0.0 → **1.1.0** (MINOR: mở rộng guidance về topology triển khai, không đổi principle)

## Bối cảnh

Constitution hiện quy định:

- Principle III: *"Docker MUST remain an optional deployment path"*, default native trên một VPS.
- Technical Constraints: *"Docker: optional; Docker Compose v2; only Caddy publishes 80/443"*.
- Principle IV: người dùng *"MUST edit exactly one configuration file: `/etc/doctbase/doctbase.toml`"*.

Người dùng muốn cài Doctbase như một **Coolify resource**: chọn repo GitHub, deploy một lần, Coolify/Traefik quản lý domain và TLS. Trong mô hình này, Caddy không thể giữ 80/443 vì proxy của Coolify đã dùng hai cổng đó.

## Nội dung amendment

### A1. External managed proxy trong Docker mode

Trong **Docker deployment mode tùy chọn**, khi Doctbase được triển khai sau một reverse proxy do nền tảng quản lý (ví dụ Coolify/Traefik), proxy đó **MAY** sở hữu cổng 80/443 và TLS; Caddy tích hợp **MUST** tắt trong mode này.

Ràng buộc giữ nguyên:

- Native/systemd mode **MUST** tiếp tục dùng Caddy và chỉ Caddy publish 80/443.
- Resource Docker **MUST NOT** publish cổng nội bộ (database, pooler, service nội bộ) ra ngoài.
- Việc chọn external proxy **MUST** là tường minh trong cấu hình triển khai, không tự phát hiện và không bật mặc định.
- Không được thêm proxy thứ hai lồng nhau trong cùng resource.

### A2. Config surface trong platform-managed mode

Trong mode do nền tảng quản lý (Coolify), biến môi trường của nền tảng **MAY** là config surface chính. Service **MUST** vẫn đọc một file `doctbase.toml` được sinh tự động từ biến môi trường lúc khởi động; file này là generated artifact, không yêu cầu chỉnh tay.

Ràng buộc giữ nguyên:

- Native mode vẫn dùng đúng một file `/etc/doctbase/doctbase.toml` do người dùng sửa.
- Mọi biến môi trường **MUST** có default hợp lý, trừ thông tin database ngoài và domain.
- Secret **MUST** được sinh/persist bởi nền tảng hoặc người dùng, không nằm trong image.

## Lý do

- Cho phép người dùng đã vận hành Coolify dùng Doctbase mà không phải dựng thêm edge proxy hoặc tắt proxy sẵn có.
- Giữ native-first: không thay đổi mặc định, không thêm thành phần bắt buộc, không thêm public port mới ngoài proxy.
- Tránh vi phạm ngầm: nếu không amendment, mọi PR Coolify đều vi phạm rule "only Caddy publishes 80/443".

## Tác động

- **Vận hành**: TLS/domain/routing do nền tảng quản lý; log proxy nằm ngoài Doctbase; rollback phụ thuộc Coolify.
- **Bảo mật**: giảm một edge proxy trong container; bề mặt tấn công chuyển sang proxy của Coolify. Yêu cầu mới: management phải có auth và không public nếu chưa gán domain.
- **Tài liệu**: thêm `docs/coolify.md`, ghi rõ mode này là optional và không hỗ trợ HA.
- **Test**: thêm test TCP listener, smoke test compose, kiểm tra không publish cổng nội bộ.
- **Không đổi**: contract CLI/HTTP/service protocol, schema database, native install.

## Rollback

- Tắt resource Coolify và deploy lại bằng native installer (Caddy giữ 80/443) hoặc Docker Compose có Caddy.
- Dữ liệu nằm trong volume `doctbase-data`/`postgres-data`; backup theo feature 001 trước khi chuyển.
- Không có migration schema mới do amendment này.

## Không nằm trong amendment

- Không cho phép bỏ Caddy ở native mode.
- Không cho phép publish trực tiếp cổng nội bộ.
- Không thay đổi Principle III (native vẫn là golden path, 2 vCPU/2 GB).
