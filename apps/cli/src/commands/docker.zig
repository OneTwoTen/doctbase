//! Docker deployment bootstrap: `init --profile docker` and `up`.
//!
//! `init` only writes a self-contained deployment directory (compose file,
//! Caddyfile and `.env`). It never starts containers and never overwrites an
//! existing secret. `up` delegates process ownership to Docker Compose, keeping
//! the same rule as native mode: no new supervisor.
//!
//! The generated compose file is standalone: Caddy publishes 80/443. The
//! Coolify/platform-managed path keeps using `deploy/docker/compose.yml`, where
//! the platform proxy owns those ports.

const std = @import("std");
const caddy = @import("install_caddy");
const security = @import("security");

pub const Profile = enum {
    native,
    docker,
};

pub const Database = enum {
    external,
    bundled,
};

pub const InitOptions = struct {
    profile: Profile = .native,
    directory: []const u8 = "doctbase",
    domain: []const u8 = "",
    email: []const u8 = "",
    /// `null` keeps the existing `.env` choice (or external on a fresh host).
    database: ?Database = null,
    instance_name: []const u8 = "doctbase",
    image_prefix: []const u8 = "doctbase",
    version: []const u8 = "latest",
    /// Directory containing `deploy/docker/compose.yml.tmpl`.
    assets_root: []const u8 = "/usr/local/lib/doctbase/current/share",
    dry_run: bool = false,
};

pub const InitResult = struct {
    allocator: std.mem.Allocator,
    directory: []u8,
    compose_path: []u8,
    caddyfile_path: []u8,
    env_path: []u8,
    secrets_generated: usize,
    env_created: bool,

    pub fn deinit(self: *InitResult) void {
        self.allocator.free(self.directory);
        self.allocator.free(self.compose_path);
        self.allocator.free(self.caddyfile_path);
        self.allocator.free(self.env_path);
        self.* = undefined;
    }
};

pub const UpOptions = struct {
    profile: Profile = .native,
    directory: []const u8 = "doctbase",
    dry_run: bool = false,
};

pub const Runner = struct {
    context: ?*anyopaque = null,
    run: *const fn (context: ?*anyopaque, argv: []const []const u8) anyerror!bool,
};

pub const Error = error{
    NativeProfileUnsupported,
    InvalidDirectory,
    InvalidDomain,
    InvalidEmail,
    InvalidInstanceName,
    InvalidImagePrefix,
    InvalidVersion,
    TemplateNotFound,
    ComposeNotFound,
    CommandFailed,
};

pub fn init(io: std.Io, allocator: std.mem.Allocator, options: InitOptions) !InitResult {
    if (options.profile != .docker) return Error.NativeProfileUnsupported;
    try validateDirectory(options.directory);

    const template_path = try std.fs.path.join(allocator, &.{ options.assets_root, "deploy/docker/compose.yml.tmpl" });
    defer allocator.free(template_path);
    const template = std.Io.Dir.cwd().readFileAlloc(io, template_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return Error.TemplateNotFound,
        else => return err,
    };
    defer allocator.free(template);

    const env_path = try std.fs.path.join(allocator, &.{ options.directory, ".env" });
    errdefer allocator.free(env_path);
    const existing_env = std.Io.Dir.cwd().readFileAlloc(io, env_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing_env) |value| allocator.free(value);

    const resolved = try resolve(allocator, existing_env, options);
    if (resolved.domain.len != 0 and !caddy.validHost(resolved.domain)) return Error.InvalidDomain;
    if (resolved.email.len != 0 and !caddy.validEmail(resolved.email)) return Error.InvalidEmail;
    if (!validInstanceName(resolved.instance_name)) return Error.InvalidInstanceName;
    if (!validImagePrefix(resolved.image_prefix)) return Error.InvalidImagePrefix;
    if (!validVersion(resolved.version)) return Error.InvalidVersion;

    // Render every file before writing so a template or validation error cannot
    // leave a half-initialized directory.
    const compose = try renderCompose(allocator, template, resolved);
    defer allocator.free(compose);
    const caddyfile = try renderCaddyfile(allocator, resolved);
    defer allocator.free(caddyfile);

    var secrets_generated: usize = 0;
    const env = try renderEnv(allocator, io, existing_env, resolved, &secrets_generated);
    defer allocator.free(env);

    const compose_path = try std.fs.path.join(allocator, &.{ options.directory, "compose.yml" });
    errdefer allocator.free(compose_path);
    const caddyfile_path = try std.fs.path.join(allocator, &.{ options.directory, "Caddyfile" });
    errdefer allocator.free(caddyfile_path);

    var result = InitResult{
        .allocator = allocator,
        .directory = try allocator.dupe(u8, options.directory),
        .compose_path = compose_path,
        .caddyfile_path = caddyfile_path,
        .env_path = env_path,
        .secrets_generated = secrets_generated,
        .env_created = existing_env == null,
    };
    errdefer result.deinit();

    if (options.dry_run) return result;

    _ = std.Io.Dir.cwd().createDirPathStatus(io, options.directory, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => .existed,
        else => return err,
    };

    try writeFile(io, result.compose_path, compose, 0o644);
    try writeFile(io, result.caddyfile_path, caddyfile, 0o644);
    try writeFile(io, result.env_path, env, 0o600);

    return result;
}

pub fn up(io: std.Io, allocator: std.mem.Allocator, options: UpOptions, runner: Runner) !void {
    switch (options.profile) {
        .native => {
            const argv = [_][]const u8{ "systemctl", "start", "doctbase.target" };
            if (options.dry_run) {
                printArgv(&argv);
                return;
            }
            if (!try runner.run(runner.context, &argv)) return Error.CommandFailed;
        },
        .docker => {
            try validateDirectory(options.directory);
            const compose_path = try std.fs.path.join(allocator, &.{ options.directory, "compose.yml" });
            defer allocator.free(compose_path);
            const env_path = try std.fs.path.join(allocator, &.{ options.directory, ".env" });
            defer allocator.free(env_path);

            _ = std.Io.Dir.cwd().statFile(io, compose_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return Error.ComposeNotFound,
                else => return err,
            };

            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(allocator);
            try argv.appendSlice(allocator, &.{
                "docker",
                "compose",
                "-f",
                compose_path,
                "--project-directory",
                options.directory,
                "--env-file",
                env_path,
                "up",
                "-d",
                "--wait",
                "--wait-timeout",
                "180",
            });

            if (options.dry_run) {
                printArgv(argv.items);
                return;
            }
            if (!try runner.run(runner.context, argv.items)) return Error.CommandFailed;
        },
    }
}

/// Values actually written to the deployment files. Options that equal their
/// defaults keep the existing `.env` value so an upgrade such as
/// `init --version 2.0` cannot silently clear a configured domain or email.
pub const Resolved = struct {
    domain: []const u8,
    email: []const u8,
    database: Database,
    instance_name: []const u8,
    image_prefix: []const u8,
    version: []const u8,
};

fn resolve(allocator: std.mem.Allocator, existing: ?[]const u8, options: InitOptions) !Resolved {
    var values = std.StringHashMap([]const u8).init(allocator);
    defer values.deinit();

    if (existing) |contents| {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const separator = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..separator], " \t");
            const value = std.mem.trim(u8, trimmed[separator + 1 ..], " \t\r");
            if (key.len != 0) try values.put(key, value);
        }
    }

    const database = options.database orelse blk: {
        if (values.get("DOCTBASE_DATABASE_MODE")) |mode| {
            break :blk if (std.mem.eql(u8, mode, "managed")) Database.bundled else Database.external;
        }
        break :blk Database.external;
    };

    return .{
        .domain = if (options.domain.len != 0)
            options.domain
        else
            (values.get("DOCTBASE_DOMAIN") orelse ""),
        .email = if (options.email.len != 0)
            options.email
        else
            (values.get("DOCTBASE_ADMIN_EMAIL") orelse ""),
        .database = database,
        .instance_name = preferNonDefault(options.instance_name, "doctbase", values.get("DOCTBASE_INSTANCE_NAME")),
        .image_prefix = preferNonDefault(options.image_prefix, "doctbase", values.get("DOCTBASE_IMAGE_PREFIX")),
        .version = preferNonDefault(options.version, "latest", values.get("DOCTBASE_VERSION")),
    };
}

fn preferNonDefault(option: []const u8, default_value: []const u8, existing: ?[]const u8) []const u8 {
    if (existing != null and std.mem.eql(u8, option, default_value)) return existing.?;
    return option;
}

pub fn renderCompose(allocator: std.mem.Allocator, template: []const u8, options: Resolved) ![]u8 {
    const pairs = [_]Pair{
        .{ .name = "INSTANCE_NAME", .value = options.instance_name },
        .{ .name = "IMAGE_PREFIX", .value = options.image_prefix },
        .{ .name = "VERSION", .value = options.version },
    };
    return substitute(allocator, template, &pairs);
}

pub fn renderCaddyfile(allocator: std.mem.Allocator, options: Resolved) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    if (options.email.len != 0) {
        try output.writer.print("{{\n    email {s}\n}}\n\n", .{options.email});
    }
    if (options.domain.len != 0) {
        try output.writer.print("{s} {{\n", .{options.domain});
    } else {
        try output.writer.writeAll(":80 {\n");
    }
    try output.writer.writeAll("    reverse_proxy management:8081\n}\n");
    return allocator.dupe(u8, output.written());
}

/// Merge configuration keys into an existing `.env`. Non-secret keys are
/// generated artifacts and follow the current options; previously generated
/// secrets are never replaced. Returns a newly allocated file body.
pub fn renderEnv(
    allocator: std.mem.Allocator,
    io: std.Io,
    existing: ?[]const u8,
    options: Resolved,
    secrets_generated: *usize,
) ![]u8 {
    const required = [_]Required{
        .{ .key = "DOCTBASE_VERSION", .value = options.version },
        .{ .key = "DOCTBASE_IMAGE_PREFIX", .value = options.image_prefix },
        .{ .key = "DOCTBASE_INSTANCE_NAME", .value = options.instance_name },
        .{ .key = "DOCTBASE_DOMAIN", .value = options.domain },
        .{ .key = "DOCTBASE_ADMIN_EMAIL", .value = options.email },
        .{ .key = "DOCTBASE_PROXY_MODE", .value = "caddy" },
        .{ .key = "DOCTBASE_DATABASE_MODE", .value = if (options.database == .bundled) "managed" else "external" },
        .{ .key = "DOCTBASE_POOLER_ENABLED", .value = if (options.database == .bundled) "true" else "false" },
        .{ .key = "COMPOSE_PROFILES", .value = if (options.database == .bundled) "bundled" else "" },
        .{ .key = "POSTGRES_DB", .value = "doctbase" },
        .{ .key = "POSTGRES_USER", .value = "doctbase" },
    };

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();

    if (existing) |contents| {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            // splitScalar yields one empty item for a trailing newline.
            if (line.len == 0 and lines.index != null and lines.index.? == contents.len) continue;

            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0 and trimmed[0] != '#') {
                if (std.mem.indexOfScalar(u8, trimmed, '=')) |separator| {
                    const key = std.mem.trim(u8, trimmed[0..separator], " \t");
                    if (key.len != 0) try seen.put(key, {});
                    if (findRequired(&required, key)) |entry| {
                        try output.writer.print("{s}={s}\n", .{ entry.key, entry.value });
                        continue;
                    }
                }
            }

            try output.writer.writeAll(line);
            try output.writer.writeByte('\n');
        }
    } else {
        try output.writer.writeAll(
            \\# Generated by `doctbase init --profile docker`.
            \\# Contains secrets: keep mode 0600 and never commit this file.
            \\
        );
    }

    for (required) |entry| {
        if (seen.contains(entry.key)) continue;
        try output.writer.print("{s}={s}\n", .{ entry.key, entry.value });
    }

    if (!seen.contains("SERVICE_PASSWORD_64_INTERNALTOKEN")) {
        const token = try security.secrets.generateHexToken(allocator, io, 32);
        defer allocator.free(token);
        try output.writer.print("SERVICE_PASSWORD_64_INTERNALTOKEN={s}\n", .{token});
        secrets_generated.* += 1;
    }
    if (!seen.contains("SERVICE_PASSWORD_64_POSTGRES")) {
        const password = try security.secrets.generateHexToken(allocator, io, 32);
        defer allocator.free(password);
        try output.writer.print("SERVICE_PASSWORD_64_POSTGRES={s}\n", .{password});
        secrets_generated.* += 1;
    }

    return allocator.dupe(u8, output.written());
}

fn findRequired(entries: []const Required, key: []const u8) ?Required {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry;
    }
    return null;
}

const Pair = struct {
    name: []const u8,
    value: []const u8,
};

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
    return allocator.dupe(u8, output.written());
}

fn lookup(pairs: []const Pair, name: []const u8) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.name, name)) return pair.value;
    }
    return null;
}

fn writeFile(io: std.Io, path: []const u8, contents: []const u8, mode: u16) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = std.Io.File.Permissions.fromMode(mode),
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, contents);
    try atomic.replace(io);
}

fn printArgv(argv: []const []const u8) void {
    std.debug.print("would run:", .{});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n", .{});
}

fn validateDirectory(directory: []const u8) !void {
    if (directory.len == 0 or directory.len > std.Io.Dir.max_path_bytes) return Error.InvalidDirectory;
    if (std.mem.eql(u8, directory, "/") or std.mem.eql(u8, directory, ".") or std.mem.eql(u8, directory, "..")) {
        return Error.InvalidDirectory;
    }
    if (std.mem.indexOf(u8, directory, "..") != null) return Error.InvalidDirectory;
    for (directory) |byte| {
        if (byte < 0x20 or byte == 0x7f) return Error.InvalidDirectory;
    }
}

fn validInstanceName(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    for (name) |byte| {
        // Compose project names are lowercase; reject uppercase early instead
        // of letting `docker compose` fail after files were written.
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return false;
    }
    return true;
}

fn validImagePrefix(prefix: []const u8) bool {
    if (prefix.len == 0 or prefix.len > 120) return false;
    for (prefix) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and
            byte != '-' and byte != '_' and byte != '.' and byte != '/') return false;
    }
    return true;
}

/// Tags and digests (`1.2.3`, `sha256:...`, `main-abc`) are interpolated into
/// YAML, so reject whitespace and control characters instead of allowing a
/// value to break out of the scalar.
fn validVersion(version: []const u8) bool {
    if (version.len == 0 or version.len > 128) return false;
    for (version) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-' and byte != ':' and byte != '@') return false;
    }
    return true;
}

const Required = struct {
    key: []const u8,
    value: []const u8,
};
