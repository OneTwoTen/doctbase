# Feature Specification: Triển khai Doctbase như một Coolify resource

**Feature Branch**: `002-coolify-resource`

**Created**: 2026-11-06

**Status**: Draft

**Input**: Người dùng muốn cài Doctbase theo cơ chế resource của Coolify: chọn repo GitHub như một project bình thường, deploy một lần, nhận instance healthy; đồng thời giữ đường cài native/systemd hiện có.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cài Doctbase từ GitHub thành một Coolify resource (Priority: P1)

Một quản trị viên đã có server chạy Coolify. Họ tạo resource mới, chọn repo Doctbase từ GitHub, khai báo domain cho API và dashboard, bấm deploy. Sau vài phút họ có một instance Doctbase healthy, truy cập được qua HTTPS bằng proxy/TLS do Coolify quản lý, và không phải sửa file cấu hình nào trên server.

**Why this priority**: Đây là toàn bộ mục tiêu của tính năng. Nếu không cài được từ GitHub bằng một resource thì người dùng Coolify không thể dùng Doctbase dù native install đã hoạt động.

**Independent Test**: Trên một Coolify instance sạch, tạo resource từ repo, đặt hai domain, deploy; xác nhận dashboard mở được, health của API trả về thành công, và không có container nào publish cổng nội bộ ra ngoài.

**Acceptance Scenarios**:

1. **Given** một Coolify instance sạch và repo Doctbase, **When** quản trị viên tạo resource kiểu Docker Compose từ repo và deploy, **Then** resource chuyển sang healthy trong vòng 10 phút mà không cần build command hay file cấu hình thủ công.
2. **Given** resource đã deploy, **When** quản trị viên mở domain API và domain dashboard, **Then** cả hai phản hồi qua HTTPS do proxy của Coolify cung cấp, không có lớp edge thứ hai trong resource.
3. **Given** resource đang chạy, **When** quản trị viên xem chi tiết resource, **Then** mỗi service là một container riêng với health check, log và trạng thái riêng; không có tiến trình supervisor tự viết bên trong container.
4. **Given** resource đã deploy không có domain, **When** quản trị viên chỉ dùng địa chỉ do Coolify cấp, **Then** hệ thống vẫn healthy và không báo lỗi cấu hình.

---

### User Story 2 - Chọn database đi kèm hoặc database sẵn có (Priority: P1)

Quản trị viên muốn Doctbase tự chạy database trong resource khi chưa có gì, hoặc trỏ vào PostgreSQL đã có (do Coolify quản lý hoặc server ngoài) khi muốn tách dữ liệu. Họ đổi lựa chọn bằng cấu hình của resource, không sửa file compose hay image.

**Why this priority**: Cùng một resource phải phục vụ cả người dùng mới (muốn một cú bấm) và người đã có hạ tầng dữ liệu; nếu thiếu, một nửa đối tượng phải cài tay.

**Independent Test**: Deploy resource ở chế độ database đi kèm và ở chế độ database ngoài; cả hai cho health check xanh và dữ liệu tồn tại sau khi redeploy.

**Acceptance Scenarios**:

1. **Given** resource ở chế độ database đi kèm, **When** deploy lần đầu, **Then** database và pooler được tạo trong resource với volume bền vững, và Doctbase kết nối được.
2. **Given** resource ở chế độ database ngoài, **When** deploy với thông tin kết nối hợp lệ, **Then** không có container database nào được tạo và hệ thống vẫn healthy.
3. **Given** resource đang dùng database đi kèm, **When** quản trị viên redeploy, **Then** dữ liệu và mật khẩu cũ được giữ nguyên, không khởi tạo lại database.
4. **Given** thông tin database ngoài sai hoặc không tới được, **When** deploy, **Then** resource báo unhealthy với lý do rõ ràng thay vì chạy ở trạng thái nửa vời.

---

### User Story 3 - Nâng cấp, rollback và vận hành trên Coolify (Priority: P2)

Quản trị viên cập nhật Doctbase bằng cách deploy commit mới hoặc rollback về bản trước trong Coolify. Dữ liệu, secret và domain được giữ nguyên; nếu bản mới không healthy, họ quay lại bản cũ mà không mất dữ liệu.

**Why this priority**: Deploy được lần đầu chưa đủ; người vận hành cần đường lùi an toàn để dám chạy thật.

**Independent Test**: Deploy bản A, tạo dữ liệu, deploy bản B, rollback về A; xác nhận dữ liệu và secret không đổi, thời gian rollback dưới 5 phút.

**Acceptance Scenarios**:

1. **Given** resource healthy ở phiên bản A, **When** deploy phiên bản B, **Then** migration chạy một lần, health check xanh, và dữ liệu cũ còn nguyên.
2. **Given** phiên bản B không healthy, **When** quản trị viên rollback về A, **Then** resource healthy trở lại trong vòng 5 phút và dữ liệu không mất.
3. **Given** resource bị restart bởi Coolify, **When** container khởi động lại, **Then** secret, domain và cấu hình vẫn như trước, không cần thao tác tay.
4. **Given** resource đang chạy, **When** quản trị viên xem log của từng service, **Then** log có cấu trúc, có request ID, và không lộ secret.

---

### User Story 4 - Bật thêm service sau khi cài (Priority: P3)

Sau khi instance cơ bản chạy, quản trị viên bật thêm các service tùy chọn (REST, realtime, storage, image proxy, metadata) mà không phải deploy lại từ đầu hay đổi domain.

**Why this priority**: Giữ resource đầu tiên nhẹ và nhanh; nhu cầu mở rộng đến sau, nhưng phải có đường đi rõ ràng.

**Independent Test**: Từ resource chỉ có gateway + management, bật thêm một service tùy chọn bằng cấu hình; xác nhận container mới healthy và không ảnh hưởng service đang chạy.

**Acceptance Scenarios**:

1. **Given** resource chỉ chạy gateway + management, **When** quản trị viên bật một service tùy chọn, **Then** service đó có container và health check riêng, còn các service khác không bị gián đoạn.
2. **Given** service tùy chọn đang tắt, **When** resource deploy, **Then** không container nào cho service đó được tạo và không có cổng hay tài nguyên bị chiếm.

---

### Edge Cases

- **Proxy/TLS do nền tảng tắt:** resource vẫn phải deploy được và truy cập qua địa chỉ do nền tảng cấp, không tự mở cổng 80/443.
- **Domain trùng hoặc chưa trỏ DNS:** resource vẫn healthy ở lớp container; lỗi DNS/TLS được báo ở lớp proxy với thông điệp rõ ràng, không rollback dữ liệu.
- **Hai bản deploy chạy song song trong lúc cập nhật:** không được ghi đè volume, không chạy migration hai lần, không mất secret.
- **Database đi kèm nhưng volume đã có dữ liệu cũ:** khởi động lại phải dùng dữ liệu đó, không khởi tạo mới.
- **Database ngoài không tới được:** health check của service phụ thuộc database chuyển unhealthy; gateway trả lỗi có mã thay vì treo.
- **Secret bị thiếu khi redeploy:** resource phải từ chối deploy và chỉ rõ secret nào thiếu, không dùng giá trị mặc định.
- **Tài nguyên thấp (4 GB RAM):** resource cơ bản phải chạy được mà không cần tăng RAM.
- **Người dùng nâng cấp từ mode native sang Coolify:** không có di trú dữ liệu tự động trong phạm vi này; tài liệu phải nói rõ.
- **Realtime/WebSocket qua proxy:** kết nối phải hoạt động khi service realtime được bật.
- **Nhiều replica:** V1 chỉ hỗ trợ một replica mỗi service; cấu hình nhiều replica phải bị từ chối hoặc ghi rõ không hỗ trợ.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Repo MUST deploy được như một resource của Coolify bằng cách chọn repo GitHub và file compose có sẵn; không yêu cầu build command, Dockerfile path hay file cấu hình tự viết.
- **FR-002**: Resource MUST tạo nhiều container độc lập cho từng service; lifecycle do nền tảng quản lý, không dùng supervisor tự viết.
- **FR-003**: Resource MUST công bố tối thiểu hai điểm vào công khai: API gateway và management/dashboard; các service nội bộ MUST NOT publish cổng ra ngoài.
- **FR-004**: Trong chế độ Coolify, TLS và domain MUST do proxy của nền tảng đảm nhiệm; resource MUST NOT chạy edge proxy thứ hai chiếm 80/443.
- **FR-005**: Giao tiếp giữa các service trong resource MUST đi qua mạng riêng của resource, có xác thực nội bộ; không phụ thuộc filesystem dùng chung hay socket của host.
- **FR-006**: Người dùng MUST chọn được database đi kèm hoặc database ngoài bằng cấu hình của resource, không sửa image hay file compose.
- **FR-007**: Secret MUST được sinh hoặc khai báo ngoài image, tồn tại qua redeploy/restart, và không có mật khẩu mặc định.
- **FR-008**: Mỗi service MUST có health check để nền tảng đánh giá healthy/unhealthy độc lập.
- **FR-009**: Resource MUST idempotent: deploy lại không mất dữ liệu, không tạo secret mới ngoài ý muốn, không chạy migration hai lần.
- **FR-010**: Người dùng MUST rollback được về phiên bản trước trong thời gian cam kết mà không mất dữ liệu.
- **FR-011**: Cấu hình MUST giới hạn trong một tập biến môi trường có tài liệu, có giá trị mặc định hợp lý; không có biến bắt buộc nào không có mặc định, trừ thông tin database ngoài và domain.
- **FR-012**: Các service tùy chọn (REST, realtime, storage, image proxy, metadata) MUST tắt mặc định và bật được độc lập sau khi cài.
- **FR-013**: Image MUST chạy dưới user không phải root, không cần quyền đặc biệt, và không chứa secret.
- **FR-014**: Log MUST có cấu trúc, có request ID và che secret; người vận hành xem được theo từng service qua nền tảng.
- **FR-015**: Management/dashboard MUST yêu cầu xác thực và MUST NOT lộ ra ngoài nếu người dùng chưa gán domain hoặc allowlist.
- **FR-016**: Resource MUST chạy được trên máy 4 GB RAM cho cấu hình cơ bản (gateway + management + database đi kèm).
- **FR-017**: Tài liệu MUST mô tả các bước tạo resource trên Coolify, danh sách biến môi trường, cách chọn database, cách rollback và giới hạn V1 (một replica, không di trú từ native).
- **FR-018**: Thay đổi này MUST NOT làm hỏng đường cài native/systemd hiện có; native vẫn là golden path.
- **FR-019**: Việc bổ sung chế độ này MUST được ghi nhận là amendment constitution cho quy tắc "chỉ Caddy publish 80/443", kèm lý do và đường rollback.

### Key Entities

- **Coolify Resource**: một mục triển khai trong Coolify, gắn với repo GitHub, chứa nhiều container và một cấu hình biến môi trường.
- **Deployment Profile**: lựa chọn database đi kèm hoặc database ngoài, cùng tập service được bật.
- **Service Instance**: một container của Doctbase với health, log, phiên bản và trạng thái riêng.
- **Resource Secret**: token nội bộ, mật khẩu database, khóa ký; được sinh một lần và tái sử dụng qua các lần deploy.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Một người đã quen Coolify tạo được resource healthy từ repo trong **10 phút hoặc ít hơn**, không sửa file trên server.
- **SC-002**: **100%** acceptance scenario của User Story 1 và 2 pass trên một Coolify instance sạch.
- **SC-003**: Redeploy và rollback giữ nguyên **100%** dữ liệu, secret và domain; rollback hoàn tất trong **5 phút hoặc ít hơn**.
- **SC-004**: **0** cổng nội bộ (database, pooler, service nội bộ) truy cập được từ ngoài resource.
- **SC-005**: Cấu hình cơ bản chạy ổn định trên máy **4 GB RAM** và không vượt quá tài nguyên đó trong 24 giờ chạy thử.
- **SC-006**: Người vận hành xác định được service lỗi trong **2 phút** nhờ trạng thái và log theo từng container.

## Assumptions

- Người dùng có Coolify phiên bản hỗ trợ resource kiểu Docker Compose và Git integration; proxy/TLS mặc định của Coolify được bật.
- Mỗi service chạy một replica trong V1; scale ngang và HA ngoài phạm vi.
- Database đi kèm dùng PostgreSQL 18 + PgBouncer theo ràng buộc kỹ thuật của dự án; database ngoài phải tương thích PostgreSQL 18.
- Domain và DNS do người dùng cấu hình trong Coolify; resource không tự xin chứng chỉ.
- Việc chuyển từ cài native sang Coolify (hoặc ngược lại) không tự di trú dữ liệu trong phạm vi feature này.
- Slice đầu chỉ gồm gateway + management (+ database theo profile); các service tùy chọn làm theo User Story 4.
- Chế độ Coolify là đường triển khai **tùy chọn**; native/systemd vẫn là golden path và không bị thay đổi hành vi.
