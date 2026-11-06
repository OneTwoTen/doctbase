# Doctbase — Quy tắc làm việc cho agent

Áp dụng cho Codex, OpenCode và các agent khác trong repo. Đây là hướng dẫn dùng chung; constitution và các đặc tả của dự án là nguồn chuẩn cho yêu cầu sản phẩm, kỹ thuật và kiến trúc.

## Trước khi thay đổi

- Đọc `.specify/memory/constitution.md` trước khi bắt đầu mọi công việc phát triển.
- Tìm và đọc đặc tả liên quan trong `specs/` trước khi sửa; xem cả `spec.md`, `plan.md`, `tasks.md`, contract, research và tài liệu/code/test liên quan nếu chúng tồn tại.
- Ưu tiên tiếp tục hoặc cập nhật đặc tả hiện có thay vì tạo tài liệu, cấu hình hay workflow trùng lặp. Không giả định rằng một yêu cầu mới chưa có đặc tả.
- Tóm tắt ngắn cho người dùng liệu yêu cầu cần Spec Kit hay có thể xử lý trực tiếp, cùng lý do.

## Chọn quy trình

- Chủ động dùng đầy đủ Spec Kit cho tính năng lớn/liên quan nhiều thành phần, service mới, thay đổi API hoặc schema/protocol, bảo mật, vòng đời cài đặt/vận hành, hay quyết định ảnh hưởng kiến trúc.
- Có thể xử lý trực tiếp bug nhỏ, sửa lỗi cục bộ, thay đổi tài liệu, refactor hẹp hoặc cấu hình đơn giản khi không phát sinh hành vi sản phẩm, contract hay rủi ro kiến trúc mới. Đọc spec/test hiện có và cập nhật chúng nếu cần; không tạo bộ tài liệu lớn cho thay đổi nhỏ.
- Nếu thay đổi nhỏ vẫn là tính năng mới, tuân thủ yêu cầu “spec first” của constitution; giữ artifact ngắn gọn và chỉ tạo/cập nhật những gì cần thiết. Constitution luôn ưu tiên khi có xung đột với hướng dẫn rút gọn này.
- Khi chưa rõ phạm vi hoặc có nhiều cách hiểu ảnh hưởng đáng kể đến kết quả, hỏi câu hỏi tập trung trước khi chốt spec/plan. Không hỏi người dùng tự chạy hoặc nhập lệnh Spec Kit.

## Spec Kit: thứ tự và entrypoint

Khi chọn Spec Kit, đi theo thứ tự dưới đây; chỉ bỏ qua bước Clarify khi không còn điểm mơ hồ cần giải quyết:

1. **Specify** — tạo hoặc cập nhật `specs/<feature>/spec.md` từ yêu cầu.
2. **Clarify** — hỏi và ghi nhận câu trả lời cho các yêu cầu chưa rõ; chờ người dùng trả lời trước khi quyết định thay họ.
3. **Plan** — lập phương án kỹ thuật, kiểm tra constitution và nêu rõ các quyết định/đánh đổi quan trọng.
4. **Xin duyệt khi cần** — trình bày ngắn gọn quyết định có ảnh hưởng đáng kể (đặc biệt API/schema, bảo mật, vận hành/triển khai hoặc kiến trúc lõi) và chờ người dùng duyệt trước khi tiếp tục phần bị ảnh hưởng. Không cần xin duyệt từng chi tiết triển khai nhỏ.
5. **Tasks** — sau khi các quyết định cần duyệt đã được chấp thuận, chia việc thành task có thứ tự phụ thuộc, đường dẫn file và kỳ vọng kiểm thử.
6. **Implement** — thực hiện task theo plan; cập nhật tài liệu và đặc tả bị ảnh hưởng.
7. **Verify** — chạy kiểm thử phù hợp, bắt đầu từ phạm vi hẹp rồi mở rộng; báo rõ kết quả và phần chưa thể kiểm chứng.

- Tuân thủ các review gate được định nghĩa trong `.specify/workflows/speckit/workflow.yml` khi workflow đó được dùng.
- **Codex:** dùng các skill Spec Kit đã cài trong `.agents/skills/speckit-*/SKILL.md`.
- **OpenCode:** dùng các command Spec Kit đã cài trong `.opencode/commands/speckit.*.md`.
- Dùng `specs/` và `.specify/` làm artifact dùng chung; chọn entrypoint tương ứng với agent đang chạy. Không tạo command/skill thay thế, không sửa manifest hay integration config chỉ để gọi workflow, và không yêu cầu người dùng tự điều phối các bước.
- Có thể dùng `speckit.analyze` để rà tính nhất quán và `speckit.checklist` khi phù hợp; đây không phải lý do để tạo thêm tài liệu cho bug nhỏ.

## Duyệt quyết định và giới hạn thay đổi

- Khi có lựa chọn kiến trúc quan trọng hoặc yêu cầu xung đột với constitution/spec hiện hữu, nêu vấn đề, các lựa chọn và tác động; chờ người dùng quyết định trước khi thực hiện phần phụ thuộc vào quyết định đó.
- Không tự ý thay đổi kiến trúc lõi, nới lỏng constitution, hoặc làm thay đổi contract/hành vi ngoài phạm vi được yêu cầu. Mọi thay đổi cần sửa constitution phải được đề xuất như một amendment có lý do và tác động, không âm thầm cập nhật.
- Không tự ý commit, merge, rebase hoặc push. Chỉ thực hiện các thao tác Git đó khi người dùng yêu cầu rõ ràng.
- Giữ thay đổi tập trung; không sửa việc không liên quan. Bảo toàn thay đổi có sẵn của người dùng.

## Chất lượng hoàn tất

- Tuân thủ các quality gate của constitution: test-first hoặc viết test cùng lúc với implementation, kiểm tra contract/compatibility khi contract đổi, cập nhật tài liệu người dùng khi hành vi thay đổi, và ghi nhận cách rollback cho thay đổi schema/cấu hình/triển khai.
- Với thay đổi liên quan auth, quyền, secret, networking, upload hoặc management plane, thực hiện rà soát bảo mật rõ ràng.
- Chỉ kết luận hoàn tất khi acceptance criteria và kiểm thử phù hợp đã đạt; nếu môi trường thiếu công cụ/dependency, nêu chính xác điều chưa chạy được.
