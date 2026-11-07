//! Installer secret generation and file policy for native deployments.
//!
//! Secrets are generated with the CSPRNG exposed by `std.Io` and stored as
//! lowercase hex without a trailing newline, so consumers can read the exact
//! value. They never enter `doctbase.toml`, environment variables or logs.
//!
//! This module owns the policy (which secrets exist, where they live and how
//! drift is resolved) and delegates filesystem mutation to `Executor`. The
//! orchestrator (T049) supplies the adapter, transaction receipts and rollback.
//! Mapping source: `docs/nghien-cuu-cai-dat-cau-hinh.md` (Bước 5).

const std = @import("std");
const security = @import("security");

pub const directory = "/etc/doctbase/secrets";
pub const owner = "root";
pub const group = "doctbase";
pub const file_mode: u16 = 0o600;
pub const minimum_secret_bytes: usize = 32;

pub const Spec = struct {
    name: []const u8,
    bytes: usize = minimum_secret_bytes,
};

/// One secret per credential named in the installation research. JWT private
/// keys are deliberately absent: the auth service owns them under
/// `/var/lib/doctbase/auth/keys` and management only receives public keys.
pub const specs = [_]Spec{
    .{ .name = "postgres_admin" },
    .{ .name = "pgbouncer_auth" },
    .{ .name = "internal_token" },
    .{ .name = "admin_setup_token" },
};

pub const Drift = enum {
    create,
    keep,
    repair,
    conflict,
};

pub const Decisions = [specs.len]Drift;

pub const ExistingSecret = struct {
    mode: u16,
    owner_ok: bool,
    group_ok: bool,
    /// Adapters must refuse to follow symlinks and set this only for a regular
    /// file, so a planted symlink cannot redirect a permissions repair.
    regular_file: bool,
};

/// An existing secret is never rewritten. Wrong ownership or a non-regular
/// file is a conflict for the operator; only a loose mode on a platform-owned
/// regular file is repaired.
pub fn drift(existing: ?ExistingSecret) Drift {
    const secret = existing orelse return .create;
    if (!secret.regular_file) return .conflict;
    if (!secret.owner_ok or !secret.group_ok) return .conflict;
    if (secret.mode != file_mode) return .repair;
    return .keep;
}

pub fn secretPath(buffer: []u8, spec: Spec) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ directory, spec.name });
}

pub fn generateSecret(allocator: std.mem.Allocator, io: std.Io, spec: Spec) ![]u8 {
    return security.secrets.generateHexToken(allocator, io, spec.bytes);
}

/// The adapter runs with root and MUST:
/// - resolve each secret without following symlinks and report `regular_file`
///   only for a regular file owned by `root:doctbase` with the exact mode;
/// - create a missing secret atomically (`O_EXCL`/atomic link) with mode `0600`
///   and the exact contents, failing with `error.PathAlreadyExists` instead of
///   overwriting an existing file;
/// - tighten permissions without touching contents or following symlinks;
/// - never log or persist the secret value;
/// - record created/refilled files so the orchestrator can roll them back.
/// Callbacks receive path slices that are only valid for the current call.
pub const Executor = struct {
    context: ?*anyopaque = null,
    running_as_root: bool = false,
    stat_secret: *const fn (context: ?*anyopaque, path: []const u8) anyerror!?ExistingSecret,
    create_secret: *const fn (context: ?*anyopaque, path: []const u8, contents: []const u8) anyerror!void,
    repair_permissions: *const fn (context: ?*anyopaque, path: []const u8) anyerror!void,
};

/// Read-only pass used by `--dry-run` and by `ensureSecrets` to fail before any
/// partial write. It never mutates the host.
pub fn evaluate(executor: Executor, decisions: *Decisions) !void {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (specs, 0..) |spec, index| {
        const path = try secretPath(&path_buffer, spec);
        decisions[index] = drift(try executor.stat_secret(executor.context, path));
    }
}

pub fn ensureSecrets(io: std.Io, allocator: std.mem.Allocator, executor: Executor) !void {
    if (!executor.running_as_root) return error.RootPrivilegesRequired;

    var decisions: Decisions = undefined;
    try evaluate(executor, &decisions);
    for (decisions) |decision| {
        if (decision == .conflict) return error.SecretOwnershipConflict;
    }

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (specs, 0..) |spec, index| {
        const path = try secretPath(&path_buffer, spec);
        switch (decisions[index]) {
            .create => {
                const secret = try generateSecret(allocator, io, spec);
                defer allocator.free(secret);
                try executor.create_secret(executor.context, path, secret);
            },
            .repair => try executor.repair_permissions(executor.context, path),
            .keep => {},
            .conflict => unreachable,
        }
    }
}

comptime {
    for (specs, 0..) |spec, index| {
        if (spec.name.len == 0) @compileError("secret name must not be empty");
        if (std.mem.indexOfAny(u8, spec.name, "/\\") != null) @compileError("secret name must not contain a path separator");
        if (std.mem.eql(u8, spec.name, ".") or std.mem.eql(u8, spec.name, "..")) @compileError("secret name must not be a dot entry");
        if (spec.bytes < minimum_secret_bytes) @compileError("secret must be at least 256 bits");
        for (specs[index + 1 ..]) |other| {
            if (std.mem.eql(u8, spec.name, other.name)) @compileError("duplicate secret name: " ++ spec.name);
        }
    }
    if ((file_mode & 0o077) != 0) @compileError("secret files must not be accessible by group or others");
}
