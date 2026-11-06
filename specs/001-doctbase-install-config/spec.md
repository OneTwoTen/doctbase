# Feature Specification: Doctbase V1 Foundation — Cài đặt, cấu hình và vận hành dễ dàng

**Feature Branch**: `001-doctbase-install-config`

**Created**: 2026-11-06

**Status**: Draft

**Input**: Yêu cầu bổ sung cho kiến trúc Doctbase V1: tiêu chí cài đặt và cấu hình phải dễ dàng; người vận hành phải có thể cài trên một VPS trống, tạo project đầu tiên và vận hành hệ thống mà không cần hiểu toàn bộ kiến trúc microservices bên dưới.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Cài Doctbase trên VPS trống bằng một lệnh (Priority: P1)

Một quản trị viên có VPS mới, chưa cài gì ngoài hệ điều hành. Họ chạy một lệnh cài đặt, trả lời tối đa hai câu hỏi tùy chọn (domain và email), và nhận được một instance Doctbase khỏe mạnh cùng URL dashboard.

**Why this priority**: Đây là điểm chạm đầu tiên và là điều kiện để mọi tính năng khác có thể được sử dụng. Nếu cài đặt thất bại hoặc quá phức tạp, các phần còn lại không có giá trị với người dùng single-VPS.

**Independent Test**: Trên một VM sạch thuộc hệ điều hành được hỗ trợ, chạy đúng một lệnh cài đặt với domain và email; xác nhận dashboard mở được, trạng thái hệ thống là healthy, và không có bước sửa file thủ công nào.

**Acceptance Scenarios**:

1. **Given** một VPS sạch có 2 vCPU/2 GB RAM, **When** quản trị viên chạy lệnh cài đặt với domain hợp lệ, **Then** hệ thống hoàn tất trong vòng 5 phút và dashboard truy cập được qua HTTPS.
2. **Given** một VPS sạch không có domain, **When** quản trị viên chạy lệnh cài đặt và bỏ qua domain, **Then** hệ thống vẫn cài đặt thành công ở chế độ chỉ truy cập cục bộ/SSH tunnel, không báo lỗi và không yêu cầu cấu hình thủ công.
3. **Given** một VPS đã có database server hoặc web server đang dùng cổng mặc định, **When** quản trị viên chạy cài đặt, **Then** hệ thống không phá dữ liệu/dịch vụ sẵn có, phát hiện xung đột trước khi thay đổi và đưa ra lựa chọn phù hợp.
4. **Given** một lần cài đặt bị gián đoạn, **When** quản trị viên chạy lại lệnh cài đặt, **Then** hệ thống tiếp tục hoặc hoàn tất mà không tạo trạng thái nửa vời và không mất dữ liệu đã có.

---

### User Story 2 - Tạo project đầu tiên và gọi API ngay (Priority: P1)

Sau khi cài đặt, quản trị viên tạo project đầu tiên bằng một lệnh. Hệ thống tự tạo database, quyền truy cập, khóa API, domain và cấu hình dịch vụ cần thiết; trả về URL, khóa công khai và khóa bí mật dùng một lần.

**Why this priority**: Giá trị cốt lõi của một BaaS là tạo ra một backend sử dụng được ngay. Nếu tạo project vẫn cần thao tác database/role/domain thủ công thì yêu cầu “dễ” chưa được đáp ứng.

**Independent Test**: Từ một instance đã cài, chạy một lệnh tạo project; dùng thông tin trả về để gọi một endpoint health/CRUD đơn giản thành công mà không mở database client hay sửa file cấu hình.

**Acceptance Scenarios**:

1. **Given** một instance Doctbase healthy, **When** quản trị viên tạo project `myapp` với các dịch vụ auth, storage và REST, **Then** project được tạo trong vòng 10 giây, URL và khóa API được in ra, và endpoint health của project trả về thành công.
2. **Given** một project đã tồn tại, **When** quản trị viên tạo project khác, **Then** hai project có dữ liệu, khóa và quyền truy cập tách biệt; truy cập chéo bị từ chối.
3. **Given** một project được tạo nhưng bước kiểm tra sức khỏe thất bại, **When** quản trị viên xem trạng thái, **Then** project ở trạng thái failed/rõ ràng và không để lại database/role/config rác.

---

### User Story 3 - Vận hành, chẩn đoán và xem trạng thái (Priority: P2)

Quản trị viên cần biết hệ thống đang chạy hay không, dịch vụ nào lỗi, log ở đâu, cấu hình có bị lệch không, và làm sao sửa. Họ dùng các lệnh quen thuộc thay vì nhớ từng daemon/công cụ hệ thống.

**Why this priority**: Một hệ thống “dễ cài” nhưng khó chẩn đoán sẽ nhanh chóng trở thành gánh nặng vận hành. Đây là điều kiện để người dùng dám chạy production.

**Independent Test**: Trên một instance đang chạy, dừng một dịch vụ, kiểm tra `status` và `doctor`; xác nhận lỗi được chỉ rõ, có gợi ý sửa, và `logs` hiển thị log liên quan mà không lộ secret.

**Acceptance Scenarios**:

1. **Given** một dịch vụ bị dừng ngoài ý muốn, **When** quản trị viên chạy lệnh trạng thái, **Then** hệ thống hiển thị dịch vụ đó là down/unhealthy và gợi ý hành động.
2. **Given** cấu hình hợp lệ nhưng file generated bị sửa tay, **When** quản trị viên chạy kiểm tra, **Then** hệ thống phát hiện drift và hướng dẫn apply lại.
3. **Given** một lỗi cài đặt hoặc kết nối, **When** quản trị viên đọc thông báo, **Then** thông báo có mã lỗi, nguyên nhân, cách sửa và liên kết tài liệu; không chỉ có “internal error”.
4. **Given** một app service đang chạy, **When** quản trị viên restart service qua CLI hoặc dashboard, **Then** service trở lại ready trong **15 giây hoặc ít hơn**, audit event được ghi, và viewer hoặc yêu cầu restart infra bị từ chối đúng policy.

---

### User Story 4 - Sao lưu, phục hồi và nâng cấp an toàn (Priority: P2)

Trước khi nâng cấp hoặc thay đổi lớn, quản trị viên tạo bản sao lưu; nếu nâng cấp thất bại, hệ thống tự rollback. Khi cần, họ phục hồi được dữ liệu, cấu hình và khóa ký.

**Why this priority**: Không có backup/restore/upgrade an toàn thì người dùng không thể vận hành lâu dài; “dễ” sẽ biến thành “dễ mất dữ liệu”.

**Independent Test**: Tạo dữ liệu mẫu, chạy backup, phá instance thử nghiệm, chạy restore trên instance sạch cùng version; xác nhận dữ liệu, cấu hình, khóa và project hoạt động trở lại.

**Acceptance Scenarios**:

1. **Given** một instance có project và dữ liệu, **When** quản trị viên chạy backup, **Then** bản backup có manifest, checksum và có thể dùng để restore.
2. **Given** một bản backup hợp lệ, **When** quản trị viên restore lên instance sạch cùng version, **Then** project, dữ liệu, cấu hình và khóa được khôi phục; health check thành công.
3. **Given** một bản nâng cấp bị lỗi migration hoặc health check, **When** quản trị viên chạy upgrade, **Then** hệ thống tự động quay lại version và dữ liệu trước đó, hoặc cung cấp quy trình rollback rõ ràng.

---

### User Story 5 - Cấu hình nâng cao mà không phá mặc định (Priority: P3)

Quản trị viên có nhu cầu cao hơn muốn đổi domain, bật dịch vụ tùy chọn, dùng database bên ngoài, hoặc dùng reverse proxy sẵn có. Họ có thể làm điều đó qua một file cấu hình và các lệnh có kiểm tra, mà không phải sửa file generated.

**Why this priority**: Người dùng đơn giản cần mặc định; người dùng nâng cao cần escape hatch. Cả hai phải dùng chung một mô hình cấu hình để tránh hai hệ thống vận hành.

**Independent Test**: Thay đổi một giá trị cấu hình nâng cao, chạy `apply` ở chế độ dry-run, xác nhận diff rõ ràng; sau đó apply và kiểm tra dịch vụ liên quan được reload/restart đúng, dịch vụ không liên quan không bị ảnh hưởng.

**Acceptance Scenarios**:

1. **Given** một cấu hình hợp lệ đang chạy, **When** quản trị viên đổi domain và chạy dry-run, **Then** hệ thống hiển thị chính xác thay đổi trước khi áp dụng.
2. **Given** một cấu hình sai, **When** quản trị viên chạy apply, **Then** hệ thống từ chối áp dụng, chỉ ra vị trí/giá trị sai và giữ nguyên trạng thái đang chạy.
3. **Given** một dịch vụ tùy chọn đang tắt, **When** quản trị viên bật nó, **Then** dịch vụ được khởi động và route tương ứng hoạt động; khi tắt lại, route bị đóng và tài nguyên được giải phóng.

---

### Edge Cases

- Đĩa còn ít hơn dung lượng tối thiểu: cài đặt phải dừng trước khi ghi dữ liệu, thông báo dung lượng cần thiết.
- RAM thấp hơn khuyến nghị: hệ thống cảnh báo và đề xuất cấu hình tối giản thay vì hết bộ nhớ giữa chừng.
- Cổng 80/443 đang bị chiếm: không tự dừng dịch vụ khác; đề xuất dùng reverse proxy bên ngoài hoặc giải phóng cổng.
- DNS chưa trỏ đúng hoặc chưa lan truyền: cài đặt vẫn có thể hoàn tất ở chế độ phù hợp; TLS được báo là chưa sẵn sàng thay vì treo vô hạn.
- Không có domain: hệ thống vẫn cài đặt và vận hành cục bộ; hướng dẫn thêm domain sau.
- Đồng hồ hệ thống lệch nhiều: phát hiện trước khi xin chứng chỉ TLS và hướng dẫn đồng bộ.
- Mất kết nối mạng giữa lúc tải gói: cài đặt dừng an toàn, có thể chạy lại.
- Docker không có hoặc không đủ quyền: chế độ native vẫn là mặc định; Docker mode báo lỗi rõ.
- Project trùng tên hoặc domain trùng: từ chối với gợi ý tên/domain khác, không ghi đè.
- Xóa project: mặc định vô hiệu hóa và giữ dữ liệu; xóa vĩnh viễn yêu cầu xác nhận và backup.
- Backup bị thiếu file/checksum sai: restore từ chối trước khi ghi đè.
- Nâng cấp bị mất điện giữa migration: lần chạy sau phát hiện trạng thái và hướng dẫn/rollback.
- Secret bị sai quyền: `doctor` phát hiện và đề xuất sửa, không tự đổi secret.
- Log có chứa token/password: hệ thống redact trước khi hiển thị hoặc đóng gói support bundle.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Hệ thống MUST cung cấp một lệnh cài đặt duy nhất cho các nền tảng được hỗ trợ (one-line install), thực hiện kiểm tra tiền đề, cài thành phần cần thiết, cấu hình và kiểm tra sức khỏe mà không cần thao tác thủ công. Phiên bản hai bước có audit script MUST được hỗ trợ như lựa chọn thay thế an toàn.
- **FR-002**: Hệ thống MUST cho phép bỏ qua domain và email TLS; cả hai MUST là tùy chọn, không phải điều kiện để cài đặt thành công.
- **FR-003**: Hệ thống MUST sinh toàn bộ secret cần thiết bằng nguồn ngẫu nhiên an toàn; MUST NOT có mật khẩu mặc định hoặc secret dùng chung giữa các project.
- **FR-004**: Người dùng MUST chỉ cần sửa một file cấu hình dạng văn bản; các file cấu hình generated MUST được đánh dấu không sửa tay và có thể tái tạo.
- **FR-005**: Cài đặt, apply cấu hình và các thao tác thay đổi trạng thái MUST idempotent; chạy lại khi không có thay đổi MUST không làm mất dữ liệu và không khởi động lại không cần thiết.
- **FR-006**: Hệ thống MUST hỗ trợ chế độ dry-run hiển thị thay đổi dự kiến trước khi áp dụng.
- **FR-007**: Hệ thống MUST cung cấp các lệnh nhất quán cho cài đặt, trạng thái, log, chẩn đoán, backup, restore, upgrade, uninstall và tạo project.
- **FR-008**: Hệ thống MUST tạo project bằng một lệnh, bao gồm dữ liệu, quyền truy cập, khóa API, domain và cấu hình dịch vụ cần thiết.
- **FR-009**: Hệ thống MUST hiển thị URL và khóa API của project đúng một lần khi tạo; khóa bí mật MUST không hiển thị lại đầy đủ sau đó.
- **FR-010**: Hệ thống MUST bootstrap quyền quản trị bằng token dùng một lần, hết hạn, và buộc đổi mật khẩu; MUST NOT có tài khoản admin với mật khẩu mặc định.
- **FR-011**: Hệ thống MUST cung cấp trạng thái tổng hợp và trạng thái từng dịch vụ, bao gồm health, version và uptime.
- **FR-012**: Hệ thống MUST cung cấp log có thể lọc theo dịch vụ/thời gian, có redaction cho secret và token.
- **FR-013**: Hệ thống MUST cung cấp lệnh chẩn đoán phát hiện các lỗi phổ biến về OS, tài nguyên, cổng, DNS, TLS, database, quyền file, phiên bản và backup; mỗi lỗi MUST có gợi ý sửa.
- **FR-014**: Hệ thống MUST cung cấp backup nhất quán cho dữ liệu điều khiển, dữ liệu project, storage, khóa ký, cấu hình và manifest; backup MUST có checksum.
- **FR-015**: Hệ thống MUST cung cấp restore có kiểm tra version/checksum, không ghi đè instance có dữ liệu nếu không có xác nhận rõ ràng.
- **FR-016**: Hệ thống MUST hỗ trợ upgrade có backup trước, migration có khóa, health check sau và rollback khi thất bại.
- **FR-017**: Hệ thống MUST cô lập dữ liệu và quyền truy cập giữa các project; truy cập chéo MUST bị từ chối.
- **FR-018**: Hệ thống MUST mặc định tắt các dịch vụ tùy chọn không cần thiết và cho phép bật/tắt bằng cấu hình có kiểm tra.
- **FR-019**: Hệ thống MUST không mở cổng cơ sở dữ liệu hoặc cổng quản trị nội bộ ra Internet trong chế độ native mặc định.
- **FR-020**: Hệ thống MUST cung cấp chế độ Docker tùy chọn, cài được bằng một lệnh one-line hoặc một lệnh CLI sau bootstrap, nhưng không bắt buộc Docker cho chế độ native.
- **FR-021**: Hệ thống MUST xác thực cấu hình trước khi áp dụng, từ chối khóa/giá trị không hợp lệ và chỉ rõ vị trí lỗi.
- **FR-022**: Hệ thống MUST phát hiện cấu hình generated bị sửa tay hoặc lệch so với nguồn và hướng dẫn apply lại.
- **FR-023**: Hệ thống MUST cung cấp support bundle đã redact để hỗ trợ chẩn đoán mà không lộ secret.
- **FR-024**: Hệ thống MUST ngăn thao tác phá hủy (xóa project, purge, restore ghi đè) nếu thiếu xác nhận và backup theo quy định.
- **FR-025**: Hệ thống MUST không bao gồm billing, subscription hoặc quản lý gói dịch vụ trong V1.
- **FR-026**: Hệ thống MUST cung cấp bundle offline cho native và Docker để cài đặt trên môi trường air-gapped.
- **FR-027**: Management plane MUST áp dụng rate limit cho đăng nhập/API nhạy cảm và hỗ trợ IP allowlist cho admin.
- **FR-028**: Hệ thống MUST hỗ trợ rotation secret, JWT signing key và API key mà không làm mất phiên/token còn hiệu lực trong grace period.
- **FR-029**: Release artifacts MUST có checksum và chữ ký; CI/release MUST tạo SBOM và xác minh chữ ký trước khi phát hành.
- **FR-030**: Hệ thống MUST cho phép restart 8 app service qua CLI/management với authorization, rate limit và audit; MUST NOT restart infra service mặc định, và viewer MUST NOT restart service.

### Key Entities *(include if feature involves data)*

- **Instance**: Một cài đặt Doctbase trên một máy chủ; có version, trạng thái, domain quản trị, cấu hình và danh sách project.
- **Project**: Một backend độc lập do người dùng tạo; có định danh, tên hiển thị, domain, tập dịch vụ bật/tắt, khóa API và dữ liệu riêng.
- **Service**: Một thành phần chức năng của Doctbase (ví dụ auth, storage, REST, realtime, image proxy, metadata); có trạng thái bật/tắt, health và version.
- **Admin User**: Người dùng quản trị instance; có thông tin đăng nhập, phiên, quyền và lịch sử thao tác.
- **Domain**: Tên miền gắn với instance hoặc project; có trạng thái xác minh DNS/TLS.
- **Credential / Secret**: Khóa hoặc mật khẩu dùng cho database, khóa ký token, API key, nội bộ; có vòng đời, quyền truy cập và trạng thái rotation.
- **Backup**: Bản sao lưu có manifest, checksum, version, thời điểm và phạm vi dữ liệu.
- **Audit Event**: Bản ghi thao tác quản trị quan trọng (tạo/xóa project, rotate key, upgrade, restore, thay đổi cấu hình).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Trong ít nhất 95% lần cài đặt thử nghiệm trên ma trận nền tảng được hỗ trợ, một VPS sạch đạt trạng thái healthy trong **5 phút hoặc ít hơn** (p95).
- **SC-002**: Người dùng có thể tạo project đầu tiên và nhận phản hồi thành công từ API trong **60 giây hoặc ít hơn** sau khi cài đặt hoàn tất.
- **SC-003**: **100%** lần cài đặt mặc định không yêu cầu sửa file cấu hình hoặc tạo secret thủ công.
- **SC-004**: Chạy lại cài đặt/apply **3 lần liên tiếp** trên cùng instance không làm mất dữ liệu và không tạo thay đổi ngoài dự kiến.
- **SC-005**: Tạo một project hoàn tất trong **10 giây hoặc ít hơn** trên VPS tham chiếu 2 vCPU/2 GB.
- **SC-006**: **100%** trường hợp truy cập chéo project trong bộ kiểm thử bảo mật bị từ chối.
- **SC-007**: Restore một bản backup **10 GB hoặc nhỏ hơn** hoàn tất trong **30 phút hoặc ít hơn**, với dữ liệu và project hoạt động trở lại.
- **SC-008**: Nâng cấp từ phiên bản N-1 lên N hoàn tất với thời gian gián đoạn **3 phút hoặc ít hơn**, và rollback thành công khi kiểm thử lỗi migration/health.
- **SC-009**: Ít nhất **90%** lỗi phổ biến trong bộ kiểm thử lỗi được `doctor` phát hiện với gợi ý sửa có thể hành động.
- **SC-010**: **100%** thông báo lỗi được kiểm thử có mã lỗi, nguyên nhân, gợi ý và liên kết tài liệu; không có thông báo “internal error” không hành động được.
- **SC-011**: Chế độ Docker cài đặt thành công trên máy 4 GB RAM trong **5 phút hoặc ít hơn**, với tất cả health check đạt.
- **SC-012**: Uninstall với `--purge` không để lại dữ liệu/cấu hình Doctbase; uninstall mặc định giữ dữ liệu và có thể cài lại.
- **SC-013**: Trong kiểm thử khả dụng với **8/10** người dùng kỹ thuật chưa từng dùng Doctbase, họ hoàn thành quickstart mà không cần hỗ trợ thêm.
- **SC-014**: **0** secret hoặc token xuất hiện trong log, support bundle hoặc output mặc định trong bộ kiểm thử redaction.
- **SC-015**: Cài đặt offline từ bundle thành công trên VM air-gapped trong **10 phút hoặc ít hơn**.
- **SC-016**: **100%** endpoint đăng nhập/nhạy cảm trong bộ kiểm thử bị rate limit đúng; IP allowlist admin hoạt động.
- **SC-017**: Rotation JWT signing key/API key hoàn tất mà không làm mất token/key còn trong grace period; **0** downtime ngoài dự kiến.
- **SC-018**: **100%** release artifact được xác minh checksum/chữ ký và có SBOM trước khi phát hành.
- **SC-019**: Trong bộ kiểm thử lifecycle, **100%** app service restart qua CLI/management thành công trong **15 giây hoặc ít hơn**; **100%** yêu cầu restart infra hoặc bởi viewer bị từ chối đúng policy; **0** supervisor mới.
- **SC-020**: `doctbase dev` chạy **≥ 2 service** qua UDS, SIGTERM drain sạch trong **10 giây**, **0** process con mồ côi.

## Assumptions

- **Phạm vi feature**: Feature này triển khai lớp Foundation (cài đặt, cấu hình, lifecycle, project provisioning, backup/upgrade, dashboard khung). Việc triển khai đầy đủ auth flows, storage API, PG Meta DDL, REST auto API, realtime và image proxy là các **feature follow-on riêng**; feature này chỉ đảm bảo service skeleton, health, route/toggle và project provisioning contract cho các dịch vụ đó.
- Core Runtime là **shared library** compile vào từng service executable; Service Manager là **adapter control-plane** điều phối systemd/Compose, không phải process supervisor. systemd/Compose vẫn là lifecycle owner.

- Người dùng mục tiêu là quản trị viên kỹ thuật, có quyền root/sudo trên VPS và biết dùng terminal.
- Mỗi VPS chạy một instance Doctbase; HA nhiều node, clustering và multi-region nằm ngoài phạm vi V1.
- Hệ điều hành được hỗ trợ là Debian 13 và Ubuntu 24.04/26.04 LTS trên x86_64/arm64; macOS/Linux chỉ dùng cho phát triển.
- Người dùng tự quản lý DNS; Doctbase chỉ kiểm tra và hướng dẫn bản ghi cần tạo.
- Domain và email TLS là tùy chọn; không có domain sẽ dùng chế độ cục bộ/SSH tunnel.
- Nền tảng dùng database quan hệ theo kiến trúc đã chốt; người dùng nâng cao có thể dùng database bên ngoài nếu đáp ứng yêu cầu phiên bản.
- Docker là tùy chọn; native là chế độ khuyến nghị cho VPS 2 GB.
- Không có billing, subscription hoặc quản lý gói dịch vụ trong V1.
- Không migrate tự động từ Supabase/Appwrite/PocketBase; nhập dữ liệu nằm ngoài phạm vi.
- Backup mặc định là backup logic (dump + files + manifest), không phải khôi phục theo thời điểm (point-in-time recovery) trong V1.
- “Project” trong V1 là đơn vị cô lập dữ liệu và quyền truy cập; không phải tổ chức/team với phân quyền phức tạp.
- Các dịch vụ tùy chọn (REST, realtime, image proxy) có thể không được bật trong project đầu tiên.
- Thời gian và tài nguyên trong Success Criteria là mục tiêu acceptance trên môi trường tham chiếu, không phải cam kết SLA thương mại.
