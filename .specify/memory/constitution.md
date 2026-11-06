# Doctbase Constitution

## Core Principles

### I. Zig-First, PostgreSQL-Native

Business services, management services, and shared libraries MUST be implemented in Zig. PostgreSQL MUST remain the primary database, used natively through SQL, roles, schemas, extensions, and Row-Level Security (RLS) where appropriate. Doctbase MUST NOT introduce a database abstraction that hides PostgreSQL semantics or replaces it with an embedded database in the default deployment.

**Rationale**: PostgreSQL is the product's data contract. Preserving native SQL, RLS, extensions, and operational tooling keeps Doctbase understandable, portable, and valuable to teams that already operate PostgreSQL.

### II. Service Independence, Shared Contracts

Every microservice MUST have its own executable, configuration surface, health endpoints, and lifecycle. Services MUST communicate through versioned contracts defined in `packages/service-protocol`; they MUST NOT depend on another service's internal source code or private database tables. Shared HTTP, PostgreSQL, config, security, telemetry, and lifecycle behavior MUST live in shared packages rather than being copied between services.

**Rationale**: Independent services can be enabled, upgraded, debugged, and replaced without destabilizing the whole platform. Shared contracts keep that independence from turning into duplicated behavior.

### III. Single-VPS First, Native-First

The default production deployment MUST fit on one VPS with 2 vCPU and 2 GB RAM using native binaries and systemd. Docker MUST remain an optional deployment path, never a prerequisite. The platform MUST NOT require Kubernetes, a service mesh, an external message bus, Redis, or a managed control plane for V1. Optional services MUST be disabled by default when they are not required for the core experience.

**Rationale**: The target user operates one small server. Every mandatory component, port, and daemon makes installation harder and increases the failure surface.

### IV. Installability and Configurability Are Product Requirements

Installation and configuration ease is a first-class feature, not documentation polish.

- The golden path MUST be: one install command, one user-edited configuration file, one command per routine task, and one command to create a project.
- A fresh supported VPS MUST reach a healthy installation in **5 minutes or less** (p95), and the first successful API request MUST be possible within **60 seconds** after installation completes.
- The default configuration MUST work without mandatory manual edits. Domain and TLS email are optional; secrets MUST be generated automatically; no default password is permitted.
- Users MUST edit exactly one configuration file: `/etc/doctbase/doctbase.toml`. Caddyfiles, PgBouncer configuration, systemd units, project snapshots, and key metadata are generated artifacts and MUST NOT require manual editing.
- Every new feature MUST pass the **installability budget**: no new mandatory configuration key without a default, no new public port outside Caddy's 80/443, no new mandatory service, and no new secret that lacks generation and rotation.
- Installation and configuration operations MUST be idempotent, support `--dry-run`, fail before partial writes, and provide actionable error codes with a cause, a fix, and a documentation link.
- Re-running installation or apply MUST NOT lose data or silently change unrelated state.

**Rationale**: A powerful platform that is difficult to install is not usable by its target audience. Measuring ease prevents it from eroding as features are added.

### V. Security by Default

Doctbase MUST generate strong secrets, store them outside configuration files, and expose them only to the services that need them. PostgreSQL and PgBouncer MUST NOT listen on public TCP interfaces in the native deployment; internal service communication MUST use Unix domain sockets or private networks. The management plane MUST be separated from the data plane and protected by authentication, rate limiting, and an optional IP allowlist. RLS MUST default to deny for application tables. Every project MUST have isolated database roles and signing keys. Destructive operations MUST require explicit confirmation and a backup.

**Rationale**: Self-hosted platforms are attacked at their weakest exposed surface. Secure defaults are cheaper and more reliable than a hardening checklist users may skip.

### VI. Observability, Backup, and Recoverability

Every service MUST expose liveness, readiness, version, and metrics endpoints. Logs MUST be structured, correlated by request ID, and MUST redact secrets and credentials. Every installation MUST provide `status`, `logs`, `doctor`, and `support bundle` commands. Backup MUST cover the control database, project databases, storage, signing keys, configuration, and a manifest; restore MUST be tested. Upgrade MUST back up first, run migrations under a lock, verify health, and roll back on failure.

**Rationale**: Ease of installation is meaningless if operators cannot diagnose, back up, restore, and upgrade the system safely.

### VII. Test-First and Contract Discipline (NON-NEGOTIABLE)

Tests MUST be written before or alongside implementation for every functional requirement and contract. The test suite MUST include unit tests, integration tests with real PostgreSQL/PgBouncer/Caddy, end-to-end installation tests on supported VMs, fault-injection tests, and security tests for cross-project isolation. Contract changes MUST update the OpenAPI specification, the service protocol version, and compatibility tests. A feature is not complete until its acceptance criteria and installability gates pass.

**Rationale**: Microservices and installers fail at their boundaries. Contract and installation tests are the only reliable way to keep those boundaries safe.

## Technical Constraints

- **Backend language**: Zig, pinned to an exact stable version in `.zigversion` and `build.zig.zon`. Development builds of Zig MUST NOT be used for releases.
- **Database**: PostgreSQL 18.x, with PgBouncer in transaction pooling mode. PostgreSQL extensions MUST be declared and tested.
- **Edge proxy**: Caddy 2.x, with automatic HTTPS. Doctbase MUST NOT implement ACME or TLS termination itself.
- **Native platforms**: Debian 13 and Ubuntu 24.04/26.04 LTS on x86_64 and arm64. Other platforms require an explicit support decision.
- **Docker**: optional; Docker Compose v2; only Caddy publishes 80/443.
- **Configuration**: TOML 1.0 for the instance configuration; project state lives in the control database; secrets live in files or systemd credentials.
- **Internal protocol**: HTTP/1.1 and JSON over Unix domain sockets in native mode, private TCP in Docker mode; WebSocket for realtime.
- **Process lifecycle**: systemd for native deployments and Docker Compose for Docker deployments. A custom production supervisor MUST NOT be introduced without a constitution amendment.
- **No billing or plans**: Doctbase V1 MUST NOT include billing, subscription, or plan-management functionality.

## Development Workflow & Quality Gates

1. **Spec first**: Every feature starts as a spec under `specs/`, with prioritized user stories, measurable success criteria, and independent acceptance tests.
2. **Plan second**: The implementation plan MUST include a Constitution Check, technical context, project structure, and complexity justification for any violation.
3. **Tasks third**: Work MUST be broken into dependency-ordered, independently completable tasks with exact file paths and test expectations.
4. **Tests are the gate**: Unit, integration, end-to-end installation, security, and restore tests MUST pass before a feature is considered complete.
5. **Installability review**: Every feature review MUST answer the installability-budget questions in Principle IV.
6. **Documentation**: User-facing behavior changes MUST update the quickstart, configuration reference, and troubleshooting or upgrade documentation.
7. **Security review**: Changes touching authentication, authorization, secrets, networking, file uploads, or the management plane require an explicit security review.
8. **Reversibility**: Changes to configuration, database schema, or deployment topology MUST have a documented rollback or restore path.

## Governance

This constitution supersedes conflicting team practices, templates, and implementation shortcuts.

- **Amendments**: A change MUST be proposed as a written amendment, include the reason and migration impact, and be recorded with a semantic version bump.
- **Versioning**: MAJOR for incompatible governance or principle removal/redefinition; MINOR for a new principle or materially expanded guidance; PATCH for clarification or wording fixes.
- **Compliance**: Every plan and pull request MUST include a Constitution Check. Any violation MUST be listed in the plan's Complexity Tracking table with a justified simpler alternative.
- **Review**: At least one reviewer MUST verify compliance with Principles I, IV, V, and VII. Security-sensitive changes require a second reviewer with security responsibility.
- **Runtime guidance**: `docs/` contains the architecture research, quickstart, configuration reference, upgrade, backup, and troubleshooting guidance. When guidance conflicts with this constitution, the constitution wins.

**Version**: 1.0.0 | **Ratified**: 2026-11-06 | **Last Amended**: 2026-11-06
