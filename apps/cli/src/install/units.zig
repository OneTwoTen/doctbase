//! Systemd unit rendering for native application services.
//!
//! The service registry in `packages/service-lifecycle` is the single source of
//! truth for unit names, binaries, sockets and dependency ordering. This module
//! adds only the installer-specific policy (service account, writable paths,
//! hardening, credentials) and renders the shipped templates.
//!
//! Infra units (`postgresql@18-doctbase`, `doctbase-pgbouncer`,
//! `doctbase-caddy`) own their own templates; the target unit aggregates them.

const std = @import("std");
const registry = @import("service_lifecycle").registry;

pub const app_template_path = "deploy/native/units/doctbase-app.service.tmpl";
pub const target_template_path = "deploy/native/units/doctbase.target.tmpl";
pub const polkit_path = "deploy/native/polkit/50-doctbase.rules";
pub const polkit_install_path = "/etc/polkit-1/rules.d/50-doctbase.rules";

pub const unit_directory = "/etc/systemd/system";
pub const target_name = "doctbase.target";
pub const binary_directory = "/usr/local/lib/doctbase/current/bin";
pub const config_path = "/etc/doctbase/doctbase.toml";
pub const run_directory = "/run/doctbase";
pub const internal_token_path = "/etc/doctbase/secrets/internal_token";
pub const setup_token_path = "/etc/doctbase/secrets/admin_setup_token";

/// Service accounts are defined once in the identity policy. Keep this switch
/// exhaustive so a new registry entry cannot silently run as the wrong user.
pub fn userFor(key: registry.ServiceKey) []const u8 {
    return switch (key) {
        .gateway => "doctbase-gateway",
        .management => "doctbase-management",
        .auth => "doctbase-auth",
        .rest => "doctbase-rest",
        .realtime => "doctbase-realtime",
        .storage => "doctbase-storage",
        .image_proxy => "doctbase-image",
        .pg_meta => "doctbase-meta",
        .postgresql, .pgbouncer, .caddy => unreachable,
    };
}

/// Paths each service may write while `ProtectSystem=strict` is active.
pub fn readWritePaths(key: registry.ServiceKey) []const u8 {
    return switch (key) {
        .management => run_directory ++ " /var/lib/doctbase/projects /var/lib/doctbase/control /etc/doctbase/generated",
        .auth => run_directory ++ " /var/lib/doctbase/auth",
        .storage => run_directory ++ " /var/lib/doctbase/projects",
        .image_proxy => run_directory ++ " /var/lib/doctbase/cache",
        .gateway, .rest, .realtime, .pg_meta => run_directory,
        .postgresql, .pgbouncer, .caddy => unreachable,
    };
}

/// Only the management plane consumes the one-time admin setup token. Every
/// app service still receives the shared internal token.
fn extraCredentials(key: registry.ServiceKey) []const u8 {
    return switch (key) {
        .management => "LoadCredential=admin_setup_token:" ++ setup_token_path ++ "\n",
        else => "",
    };
}

/// `journalctl` access for the management plane is granted through the
/// standard `systemd-journal` group instead of a broad polkit rule.
fn supplementaryGroups(key: registry.ServiceKey) []const u8 {
    return switch (key) {
        .management => "SupplementaryGroups=systemd-journal\n",
        else => "",
    };
}

pub fn unitPath(buffer: []u8, unit: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ unit_directory, unit });
}

pub fn targetPath(buffer: []u8) ![]const u8 {
    return unitPath(buffer, target_name);
}

/// Render one application unit from the shipped template. Only application
/// registry entries are accepted; infra units have their own templates.
pub fn renderApp(
    allocator: std.mem.Allocator,
    template: []const u8,
    spec: *const registry.ServiceSpec,
) ![]u8 {
    if (spec.kind != .app) return error.NotApplicationService;
    const unit = spec.unit_name orelse return error.MissingUnitName;
    const binary = spec.binary_name orelse return error.MissingBinaryName;
    const socket = spec.socket_path orelse return error.MissingSocketPath;

    var after = std.Io.Writer.Allocating.init(allocator);
    defer after.deinit();
    try after.writer.writeAll("network-online.target doctbase-pgbouncer.service");
    for (spec.depends_on) |dependency| {
        const dependency_spec = registry.get(dependency);
        const dependency_unit = dependency_spec.unit_name orelse return error.MissingUnitName;
        try after.writer.print(" {s}", .{dependency_unit});
    }

    const pairs = [_]Pair{
        .{ .name = "UNIT", .value = unit },
        .{ .name = "DESCRIPTION", .value = spec.display_name },
        .{ .name = "USER", .value = userFor(spec.key) },
        .{ .name = "BINARY", .value = binary },
        .{ .name = "SOCKET_PATH", .value = socket },
        .{ .name = "AFTER_UNITS", .value = after.written() },
        .{ .name = "READ_WRITE_PATHS", .value = readWritePaths(spec.key) },
        .{ .name = "EXTRA_GROUPS", .value = supplementaryGroups(spec.key) },
        .{ .name = "CONFIG", .value = config_path },
        .{ .name = "RUN_DIR", .value = run_directory },
        .{ .name = "BIN_DIR", .value = binary_directory },
        .{ .name = "INTERNAL_TOKEN", .value = internal_token_path },
        .{ .name = "EXTRA_CREDENTIALS", .value = extraCredentials(spec.key) },
        .{ .name = "TARGET", .value = target_name },
    };
    return substitute(allocator, template, &pairs);
}

/// Render `doctbase.target` from the registry so enabling or disabling core
/// services cannot leave the target stale.
pub fn renderTarget(allocator: std.mem.Allocator, template: []const u8) ![]u8 {
    var core: std.Io.Writer.Allocating = .init(allocator);
    defer core.deinit();
    var infra: std.Io.Writer.Allocating = .init(allocator);
    defer infra.deinit();
    var optional: std.Io.Writer.Allocating = .init(allocator);
    defer optional.deinit();

    var core_count: usize = 0;
    var infra_count: usize = 0;
    var optional_count: usize = 0;
    for (registry.specs()) |spec| {
        const unit = spec.unit_name orelse continue;
        switch (spec.kind) {
            .app => {
                if (spec.optional) {
                    if (optional_count != 0) try optional.writer.writeByte(' ');
                    try optional.writer.writeAll(unit);
                    optional_count += 1;
                } else {
                    if (core_count != 0) try core.writer.writeByte(' ');
                    try core.writer.writeAll(unit);
                    core_count += 1;
                }
            },
            .infra => {
                if (infra_count != 0) try infra.writer.writeByte(' ');
                try infra.writer.writeAll(unit);
                infra_count += 1;
            },
        }
    }

    const pairs = [_]Pair{
        .{ .name = "CORE_UNITS", .value = core.written() },
        .{ .name = "INFRA_UNITS", .value = infra.written() },
        .{ .name = "OPTIONAL_UNITS", .value = optional.written() },
    };
    return substitute(allocator, template, &pairs);
}

const Pair = struct { name: []const u8, value: []const u8 };

fn substitute(allocator: std.mem.Allocator, template: []const u8, pairs: []const Pair) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    var index: usize = 0;
    while (index < template.len) {
        if (template[index] != '@') {
            try output.writer.writeByte(template[index]);
            index += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, template, index + 1, '@') orelse {
            try output.writer.writeByte('@');
            index += 1;
            continue;
        };
        const name = template[index + 1 .. end];
        const value = lookup(pairs, name) orelse return error.UnknownPlaceholder;
        try output.writer.writeAll(value);
        index = end + 1;
    }

    return try allocator.dupe(u8, output.written());
}

fn lookup(pairs: []const Pair, name: []const u8) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.name, name)) return pair.value;
    }
    return null;
}

comptime {
    // Every application registry entry must be covered by the renderer.
    for (registry.specs()) |spec| {
        if (spec.kind != .app) continue;
        _ = userFor(spec.key);
        _ = readWritePaths(spec.key);
    }
}
