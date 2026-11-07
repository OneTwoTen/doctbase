//! Host adapter for the native installer.
//!
//! `install.zig` owns ordering, progress and rollback policy; this module is the
//! only place that mutates a real host. It uses fixed argv (never a shell) for
//! every external command, writes managed files atomically, and records a
//! receipt only for resources it actually created so rollback cannot delete
//! operator-owned data.
//!
//! Native-only by design: the installer refuses unsupported hosts in preflight,
//! and the CLI is built for Linux targets only.

const std = @import("std");
const builtin = @import("builtin");
const install = @import("install_orchestrator");
const state = @import("install_state");
const preflight = @import("preflight");
const packages = @import("install_packages");
const users = @import("install_users");
const secrets = @import("install_secrets");
const postgres = @import("install_postgres");
const pgbouncer = @import("install_pgbouncer");
const caddy = @import("install_caddy");
const units = @import("install_units");
const config_file = @import("install_config");
const install_health = @import("install_health");
const lifecycle = @import("service_lifecycle");
const registry = lifecycle.registry;

const command_timeout_ns: i96 = 15 * 60 * std.time.ns_per_s;

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    assets_root: []const u8,
    root: bool,
    postgres_config_changed: bool = false,
    journal: ?*install.Journal = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, assets_root: []const u8) Host {
        return .{
            .allocator = allocator,
            .io = io,
            .assets_root = assets_root,
            .root = isRoot(),
        };
    }

    pub fn executor(self: *Host) install.Executor {
        return .{
            .context = self,
            .running_as_root = self.root,
            .preflight = preflightCallback,
            .packages = packagesCallback,
            .users = usersCallback,
            .secrets = secretsCallback,
            .postgresql = postgresqlCallback,
            .pgbouncer = pgbouncerCallback,
            .caddy = caddyCallback,
            .config = configCallback,
            .binaries = binariesCallback,
            .units = unitsCallback,
            .services = servicesCallback,
            .health = healthCallback,
            .components = componentsCallback,
            .rollback = rollbackCallback,
        };
    }

    fn hostOf(context: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(context.?));
    }

    fn record(self: *Host, receipt: state.Receipt) !void {
        if (self.journal) |journal| try journal.add(receipt);
    }

    // -- process helpers ---------------------------------------------------

    fn run(self: *Host, argv: []const []const u8) !void {
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(256 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = command_timeout_ns }, .clock = .awake } },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) return error.CommandFailed,
            else => return error.CommandFailed,
        }
    }

    /// Returns stdout on success, null for a non-zero exit, and propagates
    /// spawn errors. Used for read-only probes such as `getent` and `stat`.
    fn captureOptional(self: *Host, argv: []const []const u8) !?[]u8 {
        const result = std.process.run(self.allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(256 * 1024),
            .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = command_timeout_ns }, .clock = .awake } },
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer self.allocator.free(result.stderr);

        const succeeded = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!succeeded) {
            self.allocator.free(result.stdout);
            return null;
        }
        return result.stdout;
    }

    // -- file helpers ------------------------------------------------------

    fn exists(self: *Host, path: []const u8) !bool {
        _ = std.Io.Dir.cwd().statFile(self.io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    fn readOptional(self: *Host, path: []const u8) !?[]u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
    }

    fn writeAtomic(self: *Host, path: []const u8, contents: []const u8, mode: u16) !void {
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .permissions = std.Io.File.Permissions.fromMode(mode),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, contents);
        try atomic.replace(self.io);
    }

    fn setMode(self: *Host, path: []const u8, mode: u16) !void {
        var buffer: [8]u8 = undefined;
        const octal = try std.fmt.bufPrint(&buffer, "{o}", .{mode});
        try self.run(&.{ "/usr/bin/chmod", octal, path });
    }

    fn setOwner(self: *Host, path: []const u8, owner: []const u8, group: []const u8) !void {
        const spec = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ owner, group });
        defer self.allocator.free(spec);
        try self.run(&.{ "/usr/bin/chown", spec, path });
    }

    /// Write a generated artifact. Identical content is still re-permissioned so
    /// drift introduced by hand is repaired without changing the file.
    fn writeGenerated(
        self: *Host,
        path: []const u8,
        contents: []const u8,
        mode: u16,
        owner: []const u8,
        group: []const u8,
    ) !void {
        const existed = try self.exists(path);
        if (try self.readOptional(path)) |existing| {
            defer self.allocator.free(existing);
            if (std.mem.eql(u8, existing, contents)) {
                try self.setMode(path, mode);
                try self.setOwner(path, owner, group);
                return;
            }
        }
        try self.writeAtomic(path, contents, mode);
        try self.setOwner(path, owner, group);
        try self.setMode(path, mode);
        if (!existed) try self.record(.{ .file = try self.allocator.dupe(u8, path) });
    }

    fn writeNewFile(
        self: *Host,
        path: []const u8,
        contents: []const u8,
        mode: u16,
        owner: []const u8,
        group: []const u8,
    ) !void {
        if (try self.readOptional(path)) |existing| {
            defer self.allocator.free(existing);
            if (!std.mem.eql(u8, existing, contents)) return error.ManagedFileConflict;
            try self.setMode(path, mode);
            try self.setOwner(path, owner, group);
            return;
        }
        try self.writeAtomic(path, contents, mode);
        try self.setOwner(path, owner, group);
        try self.setMode(path, mode);
        try self.record(.{ .file = try self.allocator.dupe(u8, path) });
    }

    fn ensureDirectory(self: *Host, path: []const u8, mode: u16, owner: []const u8, group: []const u8) !void {
        if (try self.statDirectory(path)) |info| {
            defer self.allocator.free(info);
            const fields = try parseOwnerGroup(info);
            if (!std.mem.eql(u8, fields.owner, owner)) {
                return error.DirectoryOwnershipConflict;
            }
            // The installer's own state directory may be created before the
            // shared group exists. Repair group/mode only while the owner still
            // matches the plan; never chown a directory owned by somebody else.
            try self.setOwner(path, owner, group);
            try self.setMode(path, mode);
            return;
        }

        try std.Io.Dir.cwd().createDirPath(self.io, path);
        try self.setOwner(path, owner, group);
        try self.setMode(path, mode);
        try self.record(.{ .directory = try self.allocator.dupe(u8, path) });
    }

    /// Returns `"<mode> <owner> <group> directory"` for an existing directory,
    /// or null when the path does not exist.
    fn statDirectory(self: *Host, path: []const u8) !?[]u8 {
        const output = (try self.captureOptional(&.{ "/usr/bin/stat", "-c", "%a %U %G %F", path })) orelse return null;
        errdefer self.allocator.free(output);
        if (std.mem.indexOf(u8, output, "directory") == null) return error.NotADirectory;
        return output;
    }

    fn assetPath(self: *Host, relative: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.assets_root, relative });
    }
};

fn isRoot() bool {
    if (builtin.os.tag == .linux) return std.os.linux.geteuid() == 0;
    return false;
}

const OwnerGroup = struct {
    owner: []const u8,
    group: []const u8,
};

/// Parse `"<mode> <owner> <group> ..."` from `stat -c "%a %U %G"`.
fn parseOwnerGroup(contents: []const u8) !OwnerGroup {
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    var fields = std.mem.tokenizeScalar(u8, trimmed, ' ');
    _ = fields.next() orelse return error.InvalidStatOutput;
    const owner = fields.next() orelse return error.InvalidStatOutput;
    const group = fields.next() orelse return error.InvalidStatOutput;
    return .{ .owner = owner, .group = group };
}

// -- executor callbacks ----------------------------------------------------

fn preflightCallback(context: ?*anyopaque, options: *const install.Options) anyerror!preflight.Report {
    const self = Host.hostOf(context);
    var snapshot = try preflight.collect(self.allocator, self.io, .{
        .domain = if (options.domain.len > 0) options.domain else null,
    });
    defer snapshot.deinit();
    return preflight.evaluate(snapshot.facts);
}

fn packagesCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    var snapshot = try preflight.collect(self.allocator, self.io, .{
        .domain = if (options.domain.len > 0) options.domain else null,
    });
    defer snapshot.deinit();

    const plan = try packages.buildPlan(snapshot.facts, .{ .install_libvips = options.install_libvips });

    try suppressDefaultClusterCreation(self);
    var start_guard = try ServiceStartGuard.acquire(self);
    defer start_guard.release(self);

    try packages.executePlan(plan, .{
        .context = self,
        .running_as_root = self.root,
        .package_service_starts_suppressed = true,
        .postgres_default_cluster_creation_disabled = true,
        .run_command = packagesRunCommand,
        .write_file = packagesWriteFile,
    });
}

/// Prevent `postgresql-18` from creating a cluster on the default 5432 port.
/// Only affects clusters created after this line; existing clusters are kept.
fn suppressDefaultClusterCreation(self: *Host) !void {
    const path = "/etc/postgresql-common/createcluster.conf";
    const key = "create_main_cluster = false\n";

    if (try self.readOptional(path)) |existing| {
        defer self.allocator.free(existing);
        if (std.mem.indexOf(u8, existing, "create_main_cluster") != null) return;
        const combined = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ existing, key });
        defer self.allocator.free(combined);
        try self.writeAtomic(path, combined, 0o644);
        return;
    }
    try self.writeAtomic(path, "# Written by the Doctbase installer.\n" ++ key, 0o644);
}

/// Temporarily stop distribution packages from starting their own services.
/// The guard is removed before the Doctbase units are installed.
const ServiceStartGuard = struct {
    created: bool,

    fn acquire(self: *Host) !ServiceStartGuard {
        const path = "/usr/sbin/policy-rc.d";
        if (try self.exists(path)) return .{ .created = false };
        try self.writeAtomic(path, "#!/bin/sh\nexit 101\n", 0o755);
        return .{ .created = true };
    }

    fn release(self: *ServiceStartGuard, host: *Host) void {
        if (!self.created) return;
        std.Io.Dir.cwd().deleteFile(host.io, "/usr/sbin/policy-rc.d") catch {};
        self.created = false;
    }
};

fn packagesRunCommand(context: ?*anyopaque, argv: []const []const u8) anyerror!void {
    const self = Host.hostOf(context);
    try self.run(argv);
}

fn packagesWriteFile(context: ?*anyopaque, file: packages.RepositoryFile) anyerror!void {
    const self = Host.hostOf(context);
    try self.writeNewFile(file.path, file.contents, file.mode, "root", "root");
}

fn usersCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    _ = options;
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    try users.executePlan(users.plan, .{
        .context = self,
        .running_as_root = self.root,
        .ensure_group = usersEnsureGroup,
        .ensure_user = usersEnsureUser,
        .ensure_directory = usersEnsureDirectory,
        .apply_tmpfiles = usersApplyTmpfiles,
    });
}

fn usersEnsureGroup(context: ?*anyopaque, name: []const u8) anyerror!void {
    const self = Host.hostOf(context);
    if (try self.captureOptional(&.{ "getent", "group", name })) |entry| {
        self.allocator.free(entry);
        return;
    }
    try self.run(&.{ "groupadd", "--system", name });
    try self.record(.{ .group = try self.allocator.dupe(u8, name) });
}

fn usersEnsureUser(context: ?*anyopaque, spec: users.UserSpec) anyerror!void {
    const self = Host.hostOf(context);
    if (try self.captureOptional(&.{ "getent", "passwd", spec.name })) |entry| {
        defer self.allocator.free(entry);
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        var fields = std.mem.splitScalar(u8, trimmed, ':');
        _ = fields.next() orelse return error.InvalidPasswdEntry;
        _ = fields.next() orelse return error.InvalidPasswdEntry;
        _ = fields.next() orelse return error.InvalidPasswdEntry;
        _ = fields.next() orelse return error.InvalidPasswdEntry;
        _ = fields.next() orelse return error.InvalidPasswdEntry;
        const home = fields.next() orelse return error.InvalidPasswdEntry;
        const shell = fields.next() orelse return error.InvalidPasswdEntry;
        if (!std.mem.eql(u8, home, spec.home) or !std.mem.eql(u8, shell, spec.shell)) {
            return error.UserConflict;
        }
        return;
    }

    try self.run(&.{
        "useradd",
        "--system",
        "--gid",
        spec.group,
        "--home",
        spec.home,
        "--shell",
        spec.shell,
        "--no-create-home",
        spec.name,
    });
    try self.record(.{ .user = try self.allocator.dupe(u8, spec.name) });
}

fn usersEnsureDirectory(context: ?*anyopaque, spec: users.DirectorySpec) anyerror!void {
    const self = Host.hostOf(context);
    try self.ensureDirectory(spec.path, spec.mode, spec.owner, spec.group);
}

fn usersApplyTmpfiles(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self = Host.hostOf(context);
    const source = try self.assetPath("deploy/native/tmpfiles/doctbase.conf");
    defer self.allocator.free(source);

    const contents = try std.Io.Dir.cwd().readFileAlloc(self.io, source, self.allocator, .limited(64 * 1024));
    defer self.allocator.free(contents);

    try self.writeGenerated(path, contents, 0o644, "root", "root");
    try self.run(&.{ "systemd-tmpfiles", "--create", path });
}

fn secretsCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    _ = options;
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    try secrets.ensureSecrets(self.io, self.allocator, .{
        .context = self,
        .running_as_root = self.root,
        .stat_secret = secretsStat,
        .create_secret = secretsCreate,
        .repair_permissions = secretsRepair,
    });
}

fn secretsStat(context: ?*anyopaque, path: []const u8) anyerror!?secrets.ExistingSecret {
    const self = Host.hostOf(context);
    const output = (try self.captureOptional(&.{ "/usr/bin/stat", "-c", "%a %u %g %F", path })) orelse return null;
    defer self.allocator.free(output);

    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
    const mode_text = fields.next() orelse return error.InvalidStatOutput;
    const uid_text = fields.next() orelse return error.InvalidStatOutput;
    const gid_text = fields.next() orelse return error.InvalidStatOutput;
    const rest = fields.rest();

    const gid = try groupGid(self, secrets.group);
    return .{
        .mode = std.fmt.parseInt(u16, mode_text, 8) catch return error.InvalidStatOutput,
        .owner_ok = (std.fmt.parseInt(u32, uid_text, 10) catch return error.InvalidStatOutput) == 0,
        .group_ok = (std.fmt.parseInt(u32, gid_text, 10) catch return error.InvalidStatOutput) == gid,
        .regular_file = std.mem.startsWith(u8, rest, "regular"),
    };
}

fn secretsCreate(context: ?*anyopaque, path: []const u8, contents: []const u8) anyerror!void {
    const self = Host.hostOf(context);
    const file = std.Io.Dir.cwd().createFile(self.io, path, .{
        .truncate = true,
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(secrets.file_mode),
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.SecretAlreadyExists,
        else => return err,
    };
    defer file.close(self.io);
    try file.writeStreamingAll(self.io, contents);
    try self.setOwner(path, secrets.owner, secrets.group);
    try self.setMode(path, secrets.file_mode);
    try self.record(.{ .file = try self.allocator.dupe(u8, path) });
}

fn secretsRepair(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self = Host.hostOf(context);
    try self.setMode(path, secrets.file_mode);
}

fn groupGid(self: *Host, name: []const u8) !u32 {
    const output = (try self.captureOptional(&.{ "getent", "group", name })) orelse return error.GroupMissing;
    defer self.allocator.free(output);
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    var fields = std.mem.splitScalar(u8, trimmed, ':');
    _ = fields.next() orelse return error.InvalidGroupEntry;
    _ = fields.next() orelse return error.InvalidGroupEntry;
    const gid = fields.next() orelse return error.InvalidGroupEntry;
    return std.fmt.parseInt(u32, gid, 10) catch error.InvalidGroupEntry;
}

fn postgresqlCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    _ = options;
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;
    self.postgres_config_changed = false;

    const tuning_template_path = try self.assetPath("infrastructure/postgres/tuning.conf");
    defer self.allocator.free(tuning_template_path);
    const bootstrap_template_path = try self.assetPath("infrastructure/postgres/template.sql");
    defer self.allocator.free(bootstrap_template_path);

    const tuning = try std.Io.Dir.cwd().readFileAlloc(self.io, tuning_template_path, self.allocator, .limited(256 * 1024));
    defer self.allocator.free(tuning);
    const bootstrap = try std.Io.Dir.cwd().readFileAlloc(self.io, bootstrap_template_path, self.allocator, .limited(1024 * 1024));
    defer self.allocator.free(bootstrap);

    const admin_password = try readSecret(self, "/etc/doctbase/secrets/postgres_admin");
    defer {
        std.crypto.secureZero(u8, admin_password);
        self.allocator.free(admin_password);
    }
    const pgbouncer_password = try readSecret(self, "/etc/doctbase/secrets/pgbouncer_auth");
    defer {
        std.crypto.secureZero(u8, pgbouncer_password);
        self.allocator.free(pgbouncer_password);
    }

    try postgres.ensure(self.allocator, .{
        .context = self,
        .running_as_root = self.root,
        .cluster_exists = postgresClusterExists,
        .create_cluster = postgresCreateCluster,
        .write_file = postgresWriteFile,
        .start_cluster = postgresStartCluster,
        .run_sql = postgresRunSql,
    }, .{
        .ram_bytes = 2 * 1024 * 1024 * 1024,
        .max_connections = 200,
        .tuning_template = tuning,
        .bootstrap_template = bootstrap,
        .admin_password = admin_password,
        .pgbouncer_password = pgbouncer_password,
    });
}

fn readSecret(self: *Host, path: []const u8) ![]u8 {
    const contents = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(4096));
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len != contents.len) {
        const copy = try self.allocator.dupe(u8, trimmed);
        std.crypto.secureZero(u8, contents);
        self.allocator.free(contents);
        return copy;
    }
    return contents;
}

fn postgresClusterExists(context: ?*anyopaque, spec: postgres.ClusterSpec) anyerror!bool {
    const self = Host.hostOf(context);
    const info = self.statDirectory(spec.data_directory) catch |err| switch (err) {
        error.NotADirectory => return false,
        else => return err,
    };
    if (info) |value| {
        self.allocator.free(value);
        return true;
    }
    return false;
}

fn postgresCreateCluster(context: ?*anyopaque, spec: postgres.ClusterSpec) anyerror!void {
    const self = Host.hostOf(context);
    try self.run(&.{
        "pg_createcluster",
        spec.version,
        spec.name,
        "--port",
        "5433",
        "--start-conf=manual",
    });
    try self.record(.{ .cluster = try self.allocator.dupe(u8, spec.name) });
}

fn postgresWriteFile(context: ?*anyopaque, file: postgres.FileSpec) anyerror!void {
    const self = Host.hostOf(context);
    if (try self.readOptional(file.path)) |existing| {
        defer self.allocator.free(existing);
        if (!std.mem.eql(u8, existing, file.contents)) self.postgres_config_changed = true;
    } else {
        self.postgres_config_changed = true;
    }
    try self.writeGenerated(file.path, file.contents, file.mode, file.owner, file.group);
}

fn postgresStartCluster(context: ?*anyopaque, spec: postgres.ClusterSpec) anyerror!void {
    const self = Host.hostOf(context);
    const unit = try std.fmt.allocPrint(self.allocator, "postgresql@{s}-{s}.service", .{ spec.version, spec.name });
    defer self.allocator.free(unit);
    try self.run(&.{ "systemctl", "start", unit });
    if (self.postgres_config_changed) {
        try self.run(&.{ "systemctl", "restart", unit });
    }
}

fn postgresRunSql(context: ?*anyopaque, sql: []const u8) anyerror!void {
    const self = Host.hostOf(context);
    var random_bytes: [8]u8 = undefined;
    self.io.random(&random_bytes);
    const path = try std.fmt.allocPrint(self.allocator, "/tmp/doctbase-bootstrap-{d}.sql", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer self.allocator.free(path);

    try self.writeAtomic(path, sql, 0o600);
    defer std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
    try self.setOwner(path, "postgres", "postgres");

    try self.run(&.{
        "runuser",
        "-u",
        "postgres",
        "--",
        "psql",
        "--port",
        "5433",
        "--set",
        "ON_ERROR_STOP=1",
        "--no-psqlrc",
        "--file",
        path,
    });
}

fn pgbouncerCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    _ = options;
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    const databases = [_]pgbouncer.Database{.{
        .name = postgres.control_database,
        .db_name = postgres.control_database,
    }};
    const contents = try pgbouncer.render(self.allocator, .{ .databases = &databases });
    defer self.allocator.free(contents);

    try self.writeGenerated(pgbouncer.generated_path, contents, pgbouncer.file_mode, "root", "doctbase");

    const auth_password = try readSecret(self, "/etc/doctbase/secrets/pgbouncer_auth");
    defer {
        std.crypto.secureZero(u8, auth_password);
        self.allocator.free(auth_password);
    }
    const auth_contents = try pgbouncer.renderAuthFile(self.allocator, pgbouncer.auth_user, auth_password);
    defer self.allocator.free(auth_contents);
    try self.writeGenerated(pgbouncer.auth_file, auth_contents, 0o600, "doctbase-pgbouncer", "doctbase");
}

fn caddyCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    const contents = try caddy.render(self.allocator, .{
        .domain = options.domain,
        .acme_email = options.email,
    });
    defer self.allocator.free(contents);

    try self.writeGenerated(caddy.generated_path, contents, caddy.file_mode, "root", "doctbase");
}

fn configCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    if (try self.exists(config_file.path)) return;

    const contents = try config_file.render(self.allocator, .{
        .domain = options.domain,
        .email = options.email,
    });
    defer self.allocator.free(contents);
    try self.writeNewFile(config_file.path, contents, config_file.file_mode, config_file.owner, config_file.group);
}

fn binariesCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    var exe_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const bin_dir = if (options.bin_dir.len != 0)
        options.bin_dir
    else
        try executableDirectory(self, &exe_buffer);

    try self.ensureDirectory(units.binary_directory, 0o755, "root", "root");

    for (registry.specs()) |spec| {
        if (spec.kind != .app) continue;
        const binary = spec.binary_name orelse return error.MissingBinaryName;
        const source = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ bin_dir, binary });
        defer self.allocator.free(source);
        const destination = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ units.binary_directory, binary });
        defer self.allocator.free(destination);

        if (!try self.exists(source)) return error.MissingBinary;
        if (!try self.exists(destination)) {
            try self.record(.{ .file = try self.allocator.dupe(u8, destination) });
        }
        try self.run(&.{ "/usr/bin/install", "-m", "0755", "-o", "root", "-g", "root", source, destination });
    }
}

fn executableDirectory(self: *Host, buffer: []u8) ![]const u8 {
    const count = try std.Io.Dir.readLinkAbsolute(self.io, "/proc/self/exe", buffer);
    return std.fs.path.dirname(buffer[0..count]) orelse error.MissingBinaryDirectory;
}

fn unitsCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    _ = options;
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    const app_template_path = try self.assetPath(units.app_template_path);
    defer self.allocator.free(app_template_path);
    const app_template = try std.Io.Dir.cwd().readFileAlloc(self.io, app_template_path, self.allocator, .limited(256 * 1024));
    defer self.allocator.free(app_template);

    for (registry.specs()) |*spec| {
        if (spec.kind != .app) continue;
        const contents = try units.renderApp(self.allocator, app_template, spec);
        defer self.allocator.free(contents);

        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try units.unitPath(&path_buffer, spec.unit_name.?);
        try self.writeGenerated(path, contents, 0o644, "root", "root");
    }

    const target_template_path = try self.assetPath(units.target_template_path);
    defer self.allocator.free(target_template_path);
    const target_template = try std.Io.Dir.cwd().readFileAlloc(self.io, target_template_path, self.allocator, .limited(256 * 1024));
    defer self.allocator.free(target_template);
    const target_contents = try units.renderTarget(self.allocator, target_template);
    defer self.allocator.free(target_contents);

    var target_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target_path = try units.targetPath(&target_buffer);
    try self.writeGenerated(target_path, target_contents, 0o644, "root", "root");

    try installTemplate(self, pgbouncer.unit_template, pgbouncer.unit_name);
    try installTemplate(self, caddy.unit_template, caddy.unit_name);

    const polkit_source = try self.assetPath(units.polkit_path);
    defer self.allocator.free(polkit_source);
    const polkit = try std.Io.Dir.cwd().readFileAlloc(self.io, polkit_source, self.allocator, .limited(256 * 1024));
    defer self.allocator.free(polkit);
    try self.writeGenerated(units.polkit_install_path, polkit, 0o644, "root", "root");

    try self.run(&.{ "systemctl", "daemon-reload" });
}

fn installTemplate(self: *Host, relative_path: []const u8, unit_name: []const u8) !void {
    const source = try self.assetPath(relative_path);
    defer self.allocator.free(source);
    const contents = try std.Io.Dir.cwd().readFileAlloc(self.io, source, self.allocator, .limited(256 * 1024));
    defer self.allocator.free(contents);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try units.unitPath(&path_buffer, unit_name);
    try self.writeGenerated(path, contents, 0o644, "root", "root");
}

fn servicesCallback(context: ?*anyopaque, options: *const install.Options, journal: *install.Journal) anyerror!void {
    _ = options;
    const self = Host.hostOf(context);
    const previous = self.journal;
    self.journal = journal;
    defer self.journal = previous;

    var enabled = false;
    if (try self.captureOptional(&.{ "systemctl", "is-enabled", units.target_name })) |output| {
        self.allocator.free(output);
        enabled = true;
    }
    if (!enabled) {
        try self.run(&.{ "systemctl", "enable", units.target_name });
        try self.record(.{ .unit = try self.allocator.dupe(u8, units.target_name) });
    }
    try self.run(&.{ "systemctl", "start", units.target_name });
}

fn healthCallback(context: ?*anyopaque, options: *const install.Options) anyerror!install.Health {
    const self = Host.hostOf(context);
    const wait_options = install_health.registryOptions(options.health_timeout_ms) orelse return error.MissingSocketPath;
    const result = install_health.wait(self.io, wait_options);

    return .{
        .gateway_ready = result.gateway_ready,
        .management_ready = result.management_ready,
    };
}

fn componentsCallback(context: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]const state.Component {
    const self = Host.hostOf(context);
    const names = [_][]const u8{ "postgresql-18", "pgbouncer", "caddy" };
    var components: std.ArrayList(state.Component) = .empty;
    errdefer {
        for (components.items) |component| {
            allocator.free(component.name);
            allocator.free(component.version);
        }
        components.deinit(allocator);
    }

    for (names) |name| {
        const output = (try self.captureOptional(&.{
            "dpkg-query",
            "-W",
            "-f=${Version}",
            name,
        })) orelse continue;
        defer self.allocator.free(output);
        const version = std.mem.trim(u8, output, " \t\r\n");
        if (version.len == 0) continue;
        try components.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
        });
    }

    return components.toOwnedSlice(allocator);
}

fn rollbackCallback(context: ?*anyopaque, receipt: state.Receipt) anyerror!void {
    const self = Host.hostOf(context);
    switch (receipt) {
        .file => |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {},
        .directory => |path| std.Io.Dir.cwd().deleteDir(self.io, path) catch {},
        .user => |name| self.run(&.{ "userdel", name }) catch {},
        .group => |name| self.run(&.{ "groupdel", name }) catch {},
        .cluster => |name| self.run(&.{ "pg_dropcluster", postgres.version, name, "--stop" }) catch {},
        .unit => |name| {
            self.run(&.{ "systemctl", "stop", name }) catch {};
            self.run(&.{ "systemctl", "disable", name }) catch {};
        },
    }
}
