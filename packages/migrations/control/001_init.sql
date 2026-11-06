-- Doctbase Control Database Schema Migration 001
-- Defines instance control plane entities, projects, credentials, domains, backups, audit and operations.

CREATE TABLE IF NOT EXISTS instances (
    id VARCHAR(26) PRIMARY KEY,
    name VARCHAR(64) NOT NULL DEFAULT 'doctbase',
    version VARCHAR(32) NOT NULL,
    mode VARCHAR(16) NOT NULL CHECK (mode IN ('native', 'docker')),
    status VARCHAR(16) NOT NULL CHECK (status IN ('installing', 'healthy', 'degraded', 'upgrading', 'failed')),
    admin_domain VARCHAR(255) UNIQUE,
    data_dir VARCHAR(255) NOT NULL DEFAULT '/var/lib/doctbase',
    config_hash VARCHAR(128) NOT NULL,
    installed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS admin_users (
    id VARCHAR(26) PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(16) NOT NULL DEFAULT 'owner' CHECK (role IN ('owner', 'admin', 'viewer')),
    status VARCHAR(16) NOT NULL DEFAULT 'active' CHECK (status IN ('pending', 'active', 'disabled')),
    setup_token_hash VARCHAR(255),
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS admin_sessions (
    id VARCHAR(26) PRIMARY KEY,
    admin_user_id VARCHAR(26) NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL UNIQUE,
    csrf_secret_hash VARCHAR(255) NOT NULL,
    ip INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_admin_sessions_token_hash ON admin_sessions(token_hash);
CREATE INDEX IF NOT EXISTS idx_admin_sessions_expires ON admin_sessions(expires_at);

CREATE TABLE IF NOT EXISTS projects (
    id VARCHAR(26) PRIMARY KEY,
    slug VARCHAR(32) NOT NULL UNIQUE,
    name VARCHAR(100) NOT NULL,
    db_name VARCHAR(63) NOT NULL UNIQUE,
    status VARCHAR(16) NOT NULL DEFAULT 'provisioning' CHECK (status IN ('provisioning', 'active', 'disabled', 'deleting', 'deleted', 'failed')),
    domain VARCHAR(255) UNIQUE,
    allowed_origins TEXT[] DEFAULT '{}',
    storage_quota_bytes BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_projects_slug ON projects(slug);
CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);

CREATE TABLE IF NOT EXISTS project_services (
    project_id VARCHAR(26) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    service_key VARCHAR(32) NOT NULL CHECK (service_key IN ('auth', 'storage', 'pg_meta', 'rest', 'realtime', 'image_proxy')),
    enabled BOOLEAN NOT NULL DEFAULT true,
    config JSONB DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (project_id, service_key)
);

CREATE TABLE IF NOT EXISTS domains (
    id VARCHAR(26) PRIMARY KEY,
    host VARCHAR(255) NOT NULL UNIQUE,
    scope VARCHAR(16) NOT NULL CHECK (scope IN ('instance', 'project')),
    project_id VARCHAR(26) REFERENCES projects(id) ON DELETE CASCADE,
    status VARCHAR(16) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'verified', 'active', 'error', 'expired')),
    verification_token VARCHAR(255),
    last_checked_at TIMESTAMPTZ,
    cert_expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_domains_host ON domains(host);

CREATE TABLE IF NOT EXISTS api_keys (
    id VARCHAR(26) PRIMARY KEY,
    project_id VARCHAR(26) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    type VARCHAR(16) NOT NULL CHECK (type IN ('publishable', 'secret')),
    prefix VARCHAR(12) NOT NULL,
    key_hash VARCHAR(255) NOT NULL UNIQUE,
    scopes TEXT[] DEFAULT '{}',
    status VARCHAR(16) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'retiring', 'revoked', 'expired')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash);
CREATE INDEX IF NOT EXISTS idx_api_keys_project ON api_keys(project_id, status);

CREATE TABLE IF NOT EXISTS signing_keys (
    id VARCHAR(26) PRIMARY KEY,
    project_id VARCHAR(26) NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    algorithm VARCHAR(16) NOT NULL DEFAULT 'Ed25519' CHECK (algorithm IN ('Ed25519')),
    public_key TEXT NOT NULL,
    private_key_ref VARCHAR(255) NOT NULL,
    status VARCHAR(16) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'retiring', 'retired')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    activated_at TIMESTAMPTZ,
    retired_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_signing_keys_project ON signing_keys(project_id, status);

CREATE TABLE IF NOT EXISTS secret_metadata (
    id VARCHAR(26) PRIMARY KEY,
    scope VARCHAR(16) NOT NULL CHECK (scope IN ('instance', 'project')),
    project_id VARCHAR(26) REFERENCES projects(id) ON DELETE CASCADE,
    name VARCHAR(64) NOT NULL,
    path VARCHAR(255) NOT NULL,
    owner VARCHAR(64) NOT NULL DEFAULT 'doctbase',
    mode VARCHAR(8) NOT NULL DEFAULT '0600',
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    rotated_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS backups (
    id VARCHAR(26) PRIMARY KEY,
    scope VARCHAR(16) NOT NULL CHECK (scope IN ('instance', 'project')),
    project_id VARCHAR(26) REFERENCES projects(id) ON DELETE CASCADE,
    version VARCHAR(32) NOT NULL,
    status VARCHAR(16) NOT NULL CHECK (status IN ('creating', 'complete', 'verified', 'failed')),
    path VARCHAR(255) NOT NULL,
    checksum VARCHAR(128) NOT NULL,
    size_bytes BIGINT NOT NULL,
    manifest JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    error_code VARCHAR(64)
);
CREATE INDEX IF NOT EXISTS idx_backups_status ON backups(status);

CREATE TABLE IF NOT EXISTS audit_events (
    id VARCHAR(26) PRIMARY KEY,
    actor_type VARCHAR(16) NOT NULL CHECK (actor_type IN ('admin', 'system', 'cli')),
    actor_id VARCHAR(64),
    action VARCHAR(64) NOT NULL,
    target_type VARCHAR(32),
    target_id VARCHAR(64),
    request_id VARCHAR(64),
    ip INET,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_audit_events_created ON audit_events(created_at);

CREATE TABLE IF NOT EXISTS operations (
    id VARCHAR(26) PRIMARY KEY,
    type VARCHAR(32) NOT NULL CHECK (type IN ('install', 'apply', 'upgrade', 'restore', 'backup', 'project_create', 'project_delete', 'service_restart')),
    status VARCHAR(16) NOT NULL CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'rolled_back', 'cancelled')),
    target VARCHAR(255),
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMPTZ,
    error_code VARCHAR(64),
    log_ref VARCHAR(255),
    rollback_ref VARCHAR(255)
);
CREATE INDEX IF NOT EXISTS idx_operations_status ON operations(status);
