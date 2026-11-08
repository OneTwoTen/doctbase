//! Native uninstall policy.
//!
//! Uninstall is deliberately split from host mutation: the policy below decides
//! what may be removed, in which order and under which confirmation, while an
//! injected `Executor` performs the filesystem and systemd work. That keeps the
//! destructive paths testable without root and prevents a caller from inventing
//! ad-hoc removals.
//!
//! Two modes follow the CLI contract (`contracts/cli.md` §4.6):
//!
//! - `keep_data` (default): remove service units, binaries and generated
//!   artifacts, but keep `/etc/doctbase` (configuration + secrets) and
//!   `/var/lib/doctbase` (control/project data, auth keys, backups) so a
//!   reinstall adopts the existing instance.
//! - `purge`: additionally drop the dedicated PostgreSQL cluster, delete all
//!   Doctbase directories and remove the installer-created service accounts.
//!   `--purge` always requires the operator to type `purge`, even with `--yes`.
//!
//! System packages (PostgreSQL, PgBouncer, Caddy) are intentionally left
//! installed: they are shared system state and removing them belongs to the
//! operator, not to an application uninstaller.

const std = @import("std");
const lifecycle = @import("service_lifecycle");
const registry = lifecycle.registry;
const users = @import("install_users");

pub const Mode = enum {
    keep_data,
    purge,
};

pub const Options = struct {
    mode: Mode = .keep_data,
    assume_yes: bool = false,
    dry_run: bool = false,
    /// Answer supplied by the interactive prompt. The CLI never derives this
    /// from `--yes`: a purge must be typed explicitly.
    confirmation: ?[]const u8 = null,
};

pub const Confirmation = enum {
    simple,
    typed_purge,
};

pub const typed_purge_answer = "purge";

pub const Error = error{
    ConfirmationRequired,
    ConfirmationMismatch,
    RootPrivilegesRequired,
};

/// `--yes` skips the ordinary keep-data question but never the typed purge
/// confirmation required by the CLI contract.
pub fn confirmationFor(mode: Mode, assume_yes: bool) ?Confirmation {
    return switch (mode) {
        .purge => .typed_purge,
        .keep_data => if (assume_yes) null else .simple,
    };
}

pub fn confirmationAccepted(required: Confirmation, answer: []const u8) bool {
    const trimmed = std.mem.trim(u8, answer, " \t\r\n");
    return switch (required) {
        .simple => std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes"),
        .typed_purge => std.mem.eql(u8, trimmed, typed_purge_answer),
    };
}

pub const paths = struct {
    pub const systemd_directory = "/etc/systemd/system";
    pub const target_unit = "doctbase.target";
    pub const polkit_rule = "/etc/polkit-1/rules.d/50-doctbase.rules";
    pub const tmpfiles = "/etc/tmpfiles.d/doctbase.conf";
    pub const binaries = "/usr/local/lib/doctbase";
    pub const etc = "/etc/doctbase";
    pub const data = "/var/lib/doctbase";
    pub const logs = "/var/log/doctbase";
    pub const run = "/run/doctbase";
    pub const postgres_config = "/etc/postgresql/18/doctbase";
    pub const postgres_data = "/var/lib/postgresql/18/doctbase";
};

/// Host operations the policy is allowed to request. `run` returns whether the
/// command exited successfully; a missing unit or an already-dropped cluster is
/// therefore not an uninstall failure.
pub const Executor = struct {
    context: ?*anyopaque = null,
    running_as_root: bool = false,
    remove_path: *const fn (context: ?*anyopaque, path: []const u8) anyerror!void,
    run: *const fn (context: ?*anyopaque, argv: []const []const u8) anyerror!bool,
};

pub fn run(allocator: std.mem.Allocator, options: Options, executor: Executor) !void {
    // A dry run is read-only, so it does not require confirmation or root.
    if (options.dry_run) {
        try printPlan(options.mode);
        return;
    }

    if (confirmationFor(options.mode, options.assume_yes)) |required| {
        const answer = options.confirmation orelse return error.ConfirmationRequired;
        if (!confirmationAccepted(required, answer)) return error.ConfirmationMismatch;
    }
    if (!executor.running_as_root) return error.RootPrivilegesRequired;

    try stopServices(executor);

    // Remove the tmpfiles drop-in while it still exists so systemd can clean up
    // /run/doctbase through the declared rule, then delete our own artifacts.
    _ = try executor.run(executor.context, &.{ "systemd-tmpfiles", "--remove", paths.tmpfiles });
    try remove(executor, paths.tmpfiles);
    try removeUnitFiles(allocator, executor);
    try remove(executor, paths.polkit_rule);
    try remove(executor, "/etc/doctbase/generated");
    try remove(executor, paths.binaries);

    if (options.mode == .purge) {
        try purge(executor);
    } else {
        try remove(executor, paths.run);
    }

    _ = try executor.run(executor.context, &.{ "systemctl", "daemon-reload" });
    std.debug.print("Doctbase {s}.\n", .{
        if (options.mode == .purge)
            "was removed and all data was purged"
        else
            "services were removed; configuration and data were kept",
    });
}

fn stopServices(executor: Executor) !void {
    _ = try executor.run(executor.context, &.{ "systemctl", "disable", "--now", paths.target_unit });
    for (registry.specs()) |spec| {
        const unit = spec.unit_name orelse continue;
        _ = try executor.run(executor.context, &.{ "systemctl", "stop", unit });
    }
}

fn removeUnitFiles(allocator: std.mem.Allocator, executor: Executor) !void {
    for (registry.specs()) |spec| {
        // The PostgreSQL cluster instance unit belongs to postgresql-common and
        // is removed together with the cluster, not here.
        if (spec.key == .postgresql) continue;
        const unit = spec.unit_name orelse continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.systemd_directory, unit });
        defer allocator.free(path);
        try remove(executor, path);
    }

    const target = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.systemd_directory, paths.target_unit });
    defer allocator.free(target);
    try remove(executor, target);
}

fn purge(executor: Executor) !void {
    _ = try executor.run(executor.context, &.{ "systemctl", "stop", registry.get(.postgresql).unit_name.? });
    _ = try executor.run(executor.context, &.{ "pg_dropcluster", "--stop", "18", "doctbase" });

    try remove(executor, paths.etc);
    try remove(executor, paths.data);
    try remove(executor, paths.logs);
    try remove(executor, paths.run);
    try remove(executor, paths.postgres_config);
    try remove(executor, paths.postgres_data);

    // Remove service accounts last so their files can still be inspected while
    // directory deletion reports permission problems.
    for (users.service_users) |name| {
        _ = try executor.run(executor.context, &.{ "userdel", name });
    }
    _ = try executor.run(executor.context, &.{ "groupdel", users.group_name });
}

fn remove(executor: Executor, path: []const u8) !void {
    std.debug.print("removing {s}\n", .{path});
    try executor.remove_path(executor.context, path);
}

pub fn printPlan(mode: Mode) !void {
    const purge_mode = mode == .purge;
    std.debug.print(
        \\Uninstall plan ({s}):
        \\  1. stop and disable doctbase.target
        \\  2. remove doctbase systemd units and polkit rule
        \\  3. remove generated configuration and service binaries
        \\
    , .{if (purge_mode) "purge" else "keep data"});

    if (purge_mode) {
        std.debug.print(
            \\  4. drop PostgreSQL cluster 18/doctbase
            \\  5. delete /etc/doctbase, /var/lib/doctbase and /var/log/doctbase
            \\  6. remove Doctbase service users and group
            \\  7. reload systemd
            \\
        , .{});
    } else {
        std.debug.print(
            \\  4. keep /etc/doctbase and /var/lib/doctbase for reinstall
            \\  5. reload systemd
            \\
        , .{});
    }
    std.debug.print("No changes were made.\n", .{});
}
