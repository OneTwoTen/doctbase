const std = @import("std");
const preflight = @import("preflight");

pub const pgdg_key_path = "/usr/share/keyrings/doctbase-pgdg.asc";
pub const caddy_key_path = "/usr/share/keyrings/doctbase-caddy.asc";
pub const pgdg_source_path = "/etc/apt/sources.list.d/doctbase-pgdg.list";
pub const caddy_source_path = "/etc/apt/sources.list.d/doctbase-caddy.list";

pub const Distro = enum {
    debian_13,
    ubuntu_24_04,
    ubuntu_26_04,
};

pub const Options = struct {
    install_libvips: bool = false,
};

pub const RepositoryFile = struct {
    path: []const u8,
    contents: []const u8,
    mode: u16 = 0o644,
};

pub const Action = union(enum) {
    command: []const []const u8,
    write_file: RepositoryFile,
};

/// The transaction layer executes this plan so it can track file receipts,
/// suppress package service starts, and roll back if a later install phase fails.
pub const Plan = struct {
    distro: Distro,
    install_libvips: bool,

    pub fn len(_: Plan) usize {
        return 10;
    }

    pub fn step(self: Plan, index: usize) ?Action {
        return switch (index) {
            0 => .{ .command = &.{ "/usr/bin/apt-get", "update" } },
            1 => .{ .command = &.{
                "/usr/bin/env",
                "DEBIAN_FRONTEND=noninteractive",
                "/usr/bin/apt-get",
                "install",
                "--assume-yes",
                "--no-install-recommends",
                "ca-certificates",
                "curl",
            } },
            2 => .{ .command = &.{
                "/usr/bin/curl",
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--retry",
                "3",
                "--retry-delay",
                "1",
                "--output",
                pgdg_key_path,
                "https://www.postgresql.org/media/keys/ACCC4CF8.asc",
            } },
            3 => .{ .command = &.{ "/usr/bin/chmod", "0644", pgdg_key_path } },
            4 => .{ .write_file = .{
                .path = pgdg_source_path,
                .contents = pgdgSource(self.distro),
            } },
            5 => .{ .command = &.{
                "/usr/bin/curl",
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--retry",
                "3",
                "--retry-delay",
                "1",
                "--output",
                caddy_key_path,
                "https://dl.cloudsmith.io/public/caddy/stable/gpg.key",
            } },
            6 => .{ .command = &.{ "/usr/bin/chmod", "0644", caddy_key_path } },
            7 => .{ .write_file = .{
                .path = caddy_source_path,
                .contents = caddySource(),
            } },
            8 => .{ .command = &.{ "/usr/bin/apt-get", "update" } },
            9 => .{ .command = if (self.install_libvips)
                &.{
                    "/usr/bin/env",
                    "DEBIAN_FRONTEND=noninteractive",
                    "/usr/bin/apt-get",
                    "install",
                    "--assume-yes",
                    "--no-install-recommends",
                    "postgresql-18",
                    "pgbouncer",
                    "caddy",
                    "libvips42t64",
                }
            else
                &.{
                    "/usr/bin/env",
                    "DEBIAN_FRONTEND=noninteractive",
                    "/usr/bin/apt-get",
                    "install",
                    "--assume-yes",
                    "--no-install-recommends",
                    "postgresql-18",
                    "pgbouncer",
                    "caddy",
                } },
            else => null,
        };
    }
};

pub const Executor = struct {
    context: ?*anyopaque = null,
    running_as_root: bool = false,
    package_service_starts_suppressed: bool = false,
    postgres_default_cluster_creation_disabled: bool = false,
    run_command: *const fn (context: ?*anyopaque, argv: []const []const u8) anyerror!void,
    /// Must keep an identical existing file, reject a differing file, and
    /// record whether it created the file so the install transaction can roll it back.
    write_file: *const fn (context: ?*anyopaque, file: RepositoryFile) anyerror!void,
};

pub const ExistingFileAction = enum {
    create,
    keep,
    conflict,
};

pub fn buildPlan(facts: preflight.Facts, options: Options) error{
    HostFactsUnavailable,
    UnsupportedHostPlatform,
    UnsupportedOperatingSystem,
    UnsupportedArchitecture,
    PreflightBlocked,
}!Plan {
    if (!facts.collection_supported) return error.UnsupportedHostPlatform;
    if (!facts.os_release_available) return error.HostFactsUnavailable;

    const distro = distroFor(facts.distro_id, facts.version_id) orelse return error.UnsupportedOperatingSystem;
    if (!supportedArchitecture(facts.architecture)) return error.UnsupportedArchitecture;
    if (preflight.evaluate(facts).isBlocked()) return error.PreflightBlocked;

    return .{ .distro = distro, .install_libvips = options.install_libvips };
}

/// Execute the fixed package plan through the caller's transaction adapter.
/// The adapter owns root checks, rollback receipts, and safe repo-file writes.
pub fn executePlan(plan: Plan, executor: Executor) anyerror!void {
    if (!executor.running_as_root) return error.RootPrivilegesRequired;
    if (!executor.package_service_starts_suppressed) return error.ServiceStartGuardRequired;
    if (!executor.postgres_default_cluster_creation_disabled) return error.DefaultClusterGuardRequired;

    for (0..plan.len()) |index| {
        const action = plan.step(index) orelse unreachable;
        switch (action) {
            .command => |argv| try executor.run_command(executor.context, argv),
            .write_file => |file| try executor.write_file(executor.context, file),
        }
    }
}

pub fn existingFileAction(existing: ?[]const u8, expected: []const u8) ExistingFileAction {
    const contents = existing orelse return .create;
    return if (std.mem.eql(u8, contents, expected)) .keep else .conflict;
}

fn distroFor(id: []const u8, version: []const u8) ?Distro {
    if (std.mem.eql(u8, id, "debian") and std.mem.eql(u8, version, "13")) return .debian_13;
    if (!std.mem.eql(u8, id, "ubuntu")) return null;
    if (std.mem.eql(u8, version, "24.04")) return .ubuntu_24_04;
    if (std.mem.eql(u8, version, "26.04")) return .ubuntu_26_04;
    return null;
}

fn supportedArchitecture(architecture: []const u8) bool {
    return std.mem.eql(u8, architecture, "x86_64") or
        std.mem.eql(u8, architecture, "amd64") or
        std.mem.eql(u8, architecture, "aarch64") or
        std.mem.eql(u8, architecture, "arm64");
}

fn pgdgSource(distro: Distro) []const u8 {
    return switch (distro) {
        .debian_13 => "deb [signed-by=" ++ pgdg_key_path ++ "] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main\n",
        .ubuntu_24_04 => "deb [signed-by=" ++ pgdg_key_path ++ "] https://apt.postgresql.org/pub/repos/apt noble-pgdg main\n",
        .ubuntu_26_04 => "deb [signed-by=" ++ pgdg_key_path ++ "] https://apt.postgresql.org/pub/repos/apt resolute-pgdg main\n",
    };
}

fn caddySource() []const u8 {
    return "deb [signed-by=" ++ caddy_key_path ++ "] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\n";
}

test "repository files are created only when absent or already identical" {
    try std.testing.expectEqual(ExistingFileAction.create, existingFileAction(null, "expected\n"));
    try std.testing.expectEqual(ExistingFileAction.keep, existingFileAction("expected\n", "expected\n"));
    try std.testing.expectEqual(ExistingFileAction.conflict, existingFileAction("user-managed\n", "expected\n"));
}
