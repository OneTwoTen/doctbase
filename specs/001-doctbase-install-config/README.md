# Feature 001 — Doctbase V1 Foundation: Cài đặt, cấu hình và vận hành dễ dàng

**Status**: Spec + Plan + Tasks complete for review (2026-11-06)  
**Feature directory**: `specs/001-doctbase-install-config/`

## Artifacts

| File | Vai trò |
|------|---------|
| [spec.md](./spec.md) | User stories, functional requirements, success criteria, assumptions |
| [plan.md](./plan.md) | Technical context, Constitution Check, project structure, phases |
| [research.md](./research.md) | Phase 0 decisions, rationale, alternatives; Core Runtime §14, Service Manager §15, acceptance §16 |
| [data-model.md](./data-model.md) | Entities, relationships, validation, state transitions |
| [quickstart.md](./quickstart.md) | End-to-end validation guide |
| [tasks.md](./tasks.md) | 165 dependency-ordered tasks, gồm Phase 2B Core Runtime + Service Manager |
| [contracts/cli.md](./contracts/cli.md) | CLI command/output/exit-code contract |
| [contracts/config.md](./contracts/config.md) | TOML configuration contract |
| [contracts/management-api.yaml](./contracts/management-api.yaml) | OpenAPI 3.1 Management API |
| [contracts/service-protocol.md](./contracts/service-protocol.md) | Internal service protocol |
| [checklists/requirements.md](./checklists/requirements.md) | Specification quality checklist |

## Reading order

1. `spec.md` — hiểu người dùng cần gì và đo thành công thế nào.
2. `plan.md` — hiểu cách triển khai và các gate.
3. `research.md` — hiểu lý do các quyết định.
4. `data-model.md` + `contracts/` — chi tiết interface/dữ liệu.
5. `tasks.md` — thứ tự thực hiện.
6. `quickstart.md` — cách validate end-to-end.

## Status notes

- Không còn `[NEEDS CLARIFICATION]`.
- Constitution Check pass; không có violation cần Complexity Tracking.
- Core Runtime + Service Manager đã được bổ sung vào research/plan/tasks (2026-11-06): shared runtime library, lifecycle adapter systemd/Compose, registry/probe/cache/restart operation.
- MVP = US1 + US2 (cài native + tạo project/API đầu tiên), sau Phase 2B.
- Implementation đã bắt đầu: Core Runtime + Service Manager Slice 2 (`packages/runtime`, `packages/service-lifecycle`, gateway/auth, `doctbase dev/status/restart`); xem [docs/runtime-service-manager.md](../../docs/runtime-service-manager.md).

## Source of truth

Khi mâu thuẫn: **Constitution → Spec → Plan → Tasks → Research**.
