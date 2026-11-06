const std = @import("std");
const toml = @import("toml.zig");

const Allocator = std.mem.Allocator;

pub const Level = enum {
    debug,
    info,
    warn,
    err,
};

pub const Format = enum {
    json,
    text,
};

pub const Instance = struct {
    name: []const u8 = "doctbase",
    domain: []const u8 = "",
    admin_email: []const u8 = "",
    timezone: []const u8 = "UTC",
};

pub const Logging = struct {
    level: Level = .info,
    format: Format = .json,
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    schema_version: u32 = 1,
    instance: Instance = .{},
    logging: Logging = .{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const LoadOptions = struct {
    allow_missing: bool = true,
    max_bytes: usize = 1024 * 1024,
};

pub const LoadError = error{
    ConfigNotFound,
    ConfigInvalid,
    OutOfMemory,
};

pub fn load(allocator: Allocator, io: std.Io, path: []const u8, options: LoadOptions) LoadError!Config {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(options.max_bytes)) catch |err| switch (err) {
        error.FileNotFound => if (options.allow_missing) return fromSource(allocator, "") else return error.ConfigNotFound,
        error.StreamTooLong, error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigInvalid,
    };
    defer allocator.free(source);
    return fromSource(allocator, source);
}

pub fn fromSource(allocator: Allocator, source: []const u8) LoadError!Config {
    var config = Config{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer config.deinit();
    const arena = config.arena.allocator();

    var document = toml.parse(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigInvalid,
    };
    defer document.deinit();

    if (document.get("schema_version")) |value| {
        config.schema_version = switch (value) {
            .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32))
                @intCast(number)
            else
                return error.ConfigInvalid,
            else => return error.ConfigInvalid,
        };
    }

    if (document.get("instance.name")) |value| {
        config.instance.name = try copyString(arena, value);
    }
    if (document.get("instance.domain")) |value| {
        config.instance.domain = try copyString(arena, value);
    }
    if (document.get("instance.admin_email")) |value| {
        config.instance.admin_email = try copyString(arena, value);
    }
    if (document.get("instance.timezone")) |value| {
        config.instance.timezone = try copyString(arena, value);
    }

    if (document.get("logging.level")) |value| {
        const raw = try copyString(arena, value);
        config.logging.level = parseLevel(raw) orelse return error.ConfigInvalid;
    }
    if (document.get("logging.format")) |value| {
        const raw = try copyString(arena, value);
        config.logging.format = std.meta.stringToEnum(Format, raw) orelse return error.ConfigInvalid;
    }

    return config;
}

fn copyString(arena: Allocator, value: toml.Value) LoadError![]const u8 {
    return switch (value) {
        .string => |text| arena.dupe(u8, text) catch return error.OutOfMemory,
        else => error.ConfigInvalid,
    };
}

fn parseLevel(raw: []const u8) ?Level {
    if (std.mem.eql(u8, raw, "debug")) return .debug;
    if (std.mem.eql(u8, raw, "info")) return .info;
    if (std.mem.eql(u8, raw, "warn")) return .warn;
    if (std.mem.eql(u8, raw, "error")) return .err;
    return null;
}

/// Stable hash of the resolved configuration. The canonical form is intentionally
/// simple so it can be reproduced by tests and compared across versions.
pub fn configHash(allocator: Allocator, config: *const Config) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try out.writer.print(
        \\schema_version={d}
        \\instance.name={s}
        \\instance.domain={s}
        \\instance.admin_email={s}
        \\instance.timezone={s}
        \\logging.level={s}
        \\logging.format={s}
        \\
    , .{
        config.schema_version,
        config.instance.name,
        config.instance.domain,
        config.instance.admin_email,
        config.instance.timezone,
        @tagName(config.logging.level),
        @tagName(config.logging.format),
    });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex});
}

test "defaults are complete and stable" {
    var config = try fromSource(std.testing.allocator, "");
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 1), config.schema_version);
    try std.testing.expectEqualStrings("doctbase", config.instance.name);
    try std.testing.expectEqual(Level.info, config.logging.level);
}

test "parse instance and logging values" {
    const source =
        \\schema_version = 1
        \\[instance]
        \\name = "acme"
        \\domain = "example.com"
        \\[logging]
        \\level = "debug"
        \\format = "text"
    ;

    var config = try fromSource(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqualStrings("acme", config.instance.name);
    try std.testing.expectEqualStrings("example.com", config.instance.domain);
    try std.testing.expectEqual(Level.debug, config.logging.level);
    try std.testing.expectEqual(Format.text, config.logging.format);
}

test "config hash changes with resolved values" {
    var first = try fromSource(std.testing.allocator, "");
    defer first.deinit();
    var second = try fromSource(std.testing.allocator,
        \\[instance]
        \\name = "other"
    );
    defer second.deinit();

    const first_hash = try configHash(std.testing.allocator, &first);
    defer std.testing.allocator.free(first_hash);
    const second_hash = try configHash(std.testing.allocator, &second);
    defer std.testing.allocator.free(second_hash);

    try std.testing.expect(!std.mem.eql(u8, first_hash, second_hash));
    try std.testing.expect(std.mem.startsWith(u8, first_hash, "sha256:"));
}

test "load reads a TOML file and rejects a missing required file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/doctbase-config-test-{d}.toml", .{std.mem.readInt(u64, &random_bytes, .little)});
    defer allocator.free(path);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data =
        \\[instance]
        \\name = "file-instance"
        ,
    });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var config = try load(allocator, io, path, .{ .allow_missing = false });
    defer config.deinit();
    try std.testing.expectEqualStrings("file-instance", config.instance.name);

    try std.testing.expectError(error.ConfigNotFound, load(allocator, io, ".zig-cache/definitely-missing.toml", .{ .allow_missing = false }));
}
