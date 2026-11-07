//! Installer identity and directory policy for native (systemd) deployments.
//!
//! This module is deliberately declarative: it describes the groups, service
//! accounts and directories Doctbase owns, while `Executor` applies them via an
//! adapter that owns command execution, idempotency and transaction rollback.
//! Nothing here shells out, so the policy stays unit-testable on any host.
//!
//! Layout source: `docs/nghien-cuu-cai-dat-cau-hinh.md` (Bước 4). Every
//! directory is readable only by its owner and the shared `doctbase` group;
//! no entry grants world permissions. `/run/doctbase` is recreated on boot by
//! the tmpfiles drop-in because it lives on a tmpfs.

const std = @import("std");

pub const group_name = "doctbase";
pub const nonexistent_home = "/nonexistent";
pub const nologin_shell = "/usr/sbin/nologin";
pub const tmpfiles_path = "/etc/tmpfiles.d/doctbase.conf";

/// One system account per service. The shared group lets services exchange
/// Unix domain sockets (`0660 service:doctbase`) without running as the same
/// user. `doctbase-image` serves the `doctbase-image-proxy` executable.
pub const service_users = [_][]const u8{
    "doctbase-gateway",
    "doctbase-management",
    "doctbase-auth",
    "doctbase-rest",
    "doctbase-realtime",
    "doctbase-storage",
    "doctbase-image",
    "doctbase-meta",
    "doctbase-caddy",
    "doctbase-pgbouncer",
    "doctbase-backup",
};

pub const UserSpec = struct {
    name: []const u8,
    group: []const u8 = group_name,
    home: []const u8 = nonexistent_home,
    shell: []const u8 = nologin_shell,
    system_account: bool = true,
    create_home: bool = false,
};

pub const DirectorySpec = struct {
    path: []const u8,
    mode: u16,
    owner: []const u8,
    group: []const u8 = group_name,
};

/// Directories in parent-before-child order. Owners are narrowed per function:
/// auth owns signing keys, management owns generated config and project trees,
/// image owns the cache, Caddy owns certificates and backups own archives.
pub const directories = [_]DirectorySpec{
    .{ .path = "/etc/doctbase", .mode = 0o750, .owner = "root" },
    .{ .path = "/etc/doctbase/secrets", .mode = 0o700, .owner = "root" },
    .{ .path = "/etc/doctbase/generated", .mode = 0o750, .owner = "doctbase-management" },
    .{ .path = "/var/lib/doctbase", .mode = 0o750, .owner = "root" },
    .{ .path = "/var/lib/doctbase/projects", .mode = 0o770, .owner = "doctbase-management" },
    .{ .path = "/var/lib/doctbase/auth", .mode = 0o700, .owner = "doctbase-auth" },
    .{ .path = "/var/lib/doctbase/pgbouncer", .mode = 0o700, .owner = "doctbase-pgbouncer" },
    .{ .path = "/var/lib/doctbase/cache", .mode = 0o770, .owner = "doctbase-image" },
    .{ .path = "/var/lib/doctbase/caddy", .mode = 0o700, .owner = "doctbase-caddy" },
    .{ .path = "/var/lib/doctbase/backups", .mode = 0o770, .owner = "doctbase-backup" },
    .{ .path = "/var/log/doctbase", .mode = 0o750, .owner = "root" },
};

pub const Drift = enum {
    create,
    keep,
    repair,
    conflict,
};

pub const ExistingUser = struct {
    system_account: bool,
    group: []const u8,
    home: []const u8,
    shell: []const u8,
};

/// Never adopt or rewrite an existing account that does not match the plan.
/// A conflicting account is owned by the operator and must be resolved by hand.
pub fn userDrift(existing: ?ExistingUser, spec: UserSpec) Drift {
    const user = existing orelse return .create;
    if (!user.system_account) return .conflict;
    if (!std.mem.eql(u8, user.group, spec.group)) return .conflict;
    if (!std.mem.eql(u8, user.home, spec.home)) return .conflict;
    if (!std.mem.eql(u8, user.shell, spec.shell)) return .conflict;
    return .keep;
}

pub const ExistingDirectory = struct {
    mode: u16,
    owner: []const u8,
    group: []const u8,
};

/// Mode drift is repaired only while owner and group still match the plan.
/// A directory owned by somebody else is reported instead of chowned.
pub fn directoryDrift(existing: ?ExistingDirectory, spec: DirectorySpec) Drift {
    const directory_spec = existing orelse return .create;
    if (!std.mem.eql(u8, directory_spec.owner, spec.owner)) return .conflict;
    if (!std.mem.eql(u8, directory_spec.group, spec.group)) return .conflict;
    if (directory_spec.mode != spec.mode) return .repair;
    return .keep;
}

pub fn groupDrift(exists: bool) Drift {
    return if (exists) .keep else .create;
}

pub const Action = union(enum) {
    ensure_group: []const u8,
    ensure_user: UserSpec,
    ensure_directory: DirectorySpec,
    apply_tmpfiles: []const u8,
};

pub const plan: Plan = .{};

pub const Plan = struct {
    pub fn len(_: Plan) usize {
        return 1 + service_users.len + directories.len + 1;
    }

    pub fn step(_: Plan, index: usize) ?Action {
        if (index == 0) return .{ .ensure_group = group_name };

        const first_user = 1;
        if (index < first_user + service_users.len) {
            return .{ .ensure_user = .{ .name = service_users[index - first_user] } };
        }

        const first_directory = first_user + service_users.len;
        if (index < first_directory + directories.len) {
            return .{ .ensure_directory = directories[index - first_directory] };
        }

        if (index == first_directory + directories.len) return .{ .apply_tmpfiles = tmpfiles_path };
        return null;
    }
};

/// The adapter runs with root, uses argv (never a shell), and MUST:
/// - create a missing group, account or directory with the exact spec;
/// - keep an identical resource untouched so re-runs are idempotent;
/// - repair mode drift only on directories still owned by the planned owner;
/// - return `error.Conflict` instead of adopting foreign users or directories;
/// - install the tmpfiles drop-in and run `systemd-tmpfiles --create` on it.
pub const Executor = struct {
    context: ?*anyopaque = null,
    running_as_root: bool = false,
    ensure_group: *const fn (context: ?*anyopaque, name: []const u8) anyerror!void,
    ensure_user: *const fn (context: ?*anyopaque, spec: UserSpec) anyerror!void,
    ensure_directory: *const fn (context: ?*anyopaque, spec: DirectorySpec) anyerror!void,
    apply_tmpfiles: *const fn (context: ?*anyopaque, path: []const u8) anyerror!void,
};

pub fn executePlan(plan_value: Plan, executor: Executor) anyerror!void {
    if (!executor.running_as_root) return error.RootPrivilegesRequired;

    for (0..plan_value.len()) |index| {
        const action = plan_value.step(index) orelse unreachable;
        switch (action) {
            .ensure_group => |name| try executor.ensure_group(executor.context, name),
            .ensure_user => |spec| try executor.ensure_user(executor.context, spec),
            .ensure_directory => |spec| try executor.ensure_directory(executor.context, spec),
            .apply_tmpfiles => |path| try executor.apply_tmpfiles(executor.context, path),
        }
    }
}

fn knownOwner(owner: []const u8) bool {
    if (std.mem.eql(u8, owner, "root")) return true;
    for (service_users) |name| {
        if (std.mem.eql(u8, name, owner)) return true;
    }
    return false;
}

comptime {
    for (service_users, 0..) |name, index| {
        for (service_users[index + 1 ..]) |other| {
            if (std.mem.eql(u8, name, other)) @compileError("duplicate service user: " ++ name);
        }
    }

    for (directories, 0..) |directory, index| {
        if ((directory.mode & 0o007) != 0) @compileError("world-accessible directory: " ++ directory.path);
        if (!std.mem.eql(u8, directory.group, group_name)) @compileError("directory outside shared group: " ++ directory.path);
        if (!knownOwner(directory.owner)) @compileError("unknown directory owner: " ++ directory.path);
        for (directories[index + 1 ..]) |other| {
            if (std.mem.eql(u8, directory.path, other.path)) @compileError("duplicate directory: " ++ directory.path);
        }
    }
}
