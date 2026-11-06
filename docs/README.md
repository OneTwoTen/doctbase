# Doctbase Docs

Tài liệu cho Doctbase V1, được tổ chức theo **Spec Kit**. Các artifact trong `specs/` và `.specify/memory/constitution.md` là nguồn chuẩn; tài liệu nghiên cứu là tài liệu tham chiếu.

## Nguồn chuẩn (Spec Kit)

- [Constitution](../.specify/memory/constitution.md) — 7 nguyên tắc dự án, ràng buộc kỹ thuật và governance.
- [Feature 001 — Spec](../specs/001-doctbase-install-config/spec.md) — user stories, yêu cầu, success criteria.
- [Feature 001 — Plan](../specs/001-doctbase-install-config/plan.md) — technical context, Constitution Check, cấu trúc, phase.
- [Feature 001 — Tasks](../specs/001-doctbase-install-config/tasks.md) — 165 task theo user story, có đường dẫn file, gồm Phase 2B cho Core Runtime + Service Manager.
- [Feature 001 — Research](../specs/001-doctbase-install-config/research.md) — quyết định kỹ thuật, lý do, phương án thay thế.
- [Feature 001 — Data model](../specs/001-doctbase-install-config/data-model.md) — entity, quan hệ, state transition.
- [Feature 001 — Contracts](../specs/001-doctbase-install-config/contracts/) — CLI, config, Management API, service protocol.
- [Feature 001 — Quickstart](../specs/001-doctbase-install-config/quickstart.md) — kịch bản validate end-to-end.
- [Feature 002 — Spec](../specs/002-coolify-resource/spec.md) · [Plan](../specs/002-coolify-resource/plan.md) · [Tasks](../specs/002-coolify-resource/tasks.md) — triển khai như một Coolify resource.
- [Amendment 1.1.0](../.specify/memory/amendments/2026-11-06-external-proxy-coolify.md) — external managed proxy và config surface trong Docker mode.

## Tài liệu nghiên cứu tham chiếu

- [Quickstart](quickstart.md) — cách chạy hiện tại trong môi trường phát triển; hướng dẫn cài production sẽ được hoàn thiện cùng installer.
- [Configuration reference](config-reference.md) — trạng thái hiện tại và contract TOML.
- [Upgrade](upgrade.md) · [Backup and restore](backup-restore.md) · [Troubleshooting](troubleshooting.md).
- [Nghiên cứu cài đặt & cấu hình dễ dàng](nghien-cuu-cai-dat-cau-hinh.md) — phân tích Supabase/Appwrite/PocketBase/Coolify/Dokploy, luồng cài native, mẫu cấu hình, backup/upgrade, test matrix, nguồn tham khảo.
- [Core Runtime + Service Manager](runtime-service-manager.md) — trạng thái implementation, cách chạy gateway, endpoint và các slice tiếp theo.
- [Phát triển, build và test](development.md) — build native, Docker toolchain (`deploy/dev`) và GitHub Actions CI.
- [Triển khai trên Coolify](coolify.md) — resource Docker Compose, domain/TLS qua proxy nền tảng, database profile, rollback.

## Quy ước

- Thay đổi yêu cầu/spec → cập nhật `specs/001-doctbase-install-config/spec.md` trước.
- Thay đổi kỹ thuật → cập nhật `plan.md` + `research.md` nếu cần.
- Thay đổi implementation → cập nhật `tasks.md` và checklist tương ứng.
- Không sửa generated artifacts; dùng `doctbase apply`.
- Khi tài liệu mâu thuẫn: **Constitution → Spec → Plan → Tasks → Research**.
