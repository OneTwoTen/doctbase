const std = @import("std");
const toml = @import("toml.zig");
pub const schema = @import("schema.zig");
pub const validate = @import("validate.zig");

pub const Config = schema.Config;
pub const Instance = schema.Instance;
pub const Database = schema.Database;
pub const DatabaseMode = schema.DatabaseMode;
pub const Pooler = schema.Pooler;
pub const PoolMode = schema.PoolMode;
pub const Proxy = schema.Proxy;
pub const ProxyMode = schema.ProxyMode;
pub const TlsMode = schema.TlsMode;
pub const Services = schema.Services;
pub const Storage = schema.Storage;
pub const StorageBackend = schema.StorageBackend;
pub const Backup = schema.Backup;
pub const Logging = schema.Logging;
pub const LogLevel = schema.LogLevel;
pub const LogFormat = schema.LogFormat;
pub const Security = schema.Security;

const Allocator = std.mem.Allocator;

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

    // schema_version
    if (document.get("schema_version")) |value| {
        config.schema_version = try parseInt(u32, value);
    }

    // [instance]
    if (document.get("instance.name")) |val| config.instance.name = try copyString(arena, val);
    if (document.get("instance.domain")) |val| config.instance.domain = try copyString(arena, val);
    if (document.get("instance.admin_email")) |val| config.instance.admin_email = try copyString(arena, val);
    if (document.get("instance.timezone")) |val| config.instance.timezone = try copyString(arena, val);

    // [database]
    if (document.get("database.mode")) |val| {
        const raw = try copyString(arena, val);
        config.database.mode = std.meta.stringToEnum(DatabaseMode, raw) orelse return error.ConfigInvalid;
    }
    if (document.get("database.max_connections")) |val| {
        config.database.max_connections = try parseInt(u32, val);
    }
    if (document.get("database.url_file")) |val| config.database.url_file = try copyString(arena, val);

    // [pooler]
    if (document.get("pooler.enabled")) |val| config.pooler.enabled = try parseBool(val);
    if (document.get("pooler.pool_mode")) |val| {
        const raw = try copyString(arena, val);
        config.pooler.pool_mode = std.meta.stringToEnum(PoolMode, raw) orelse return error.ConfigInvalid;
    }
    if (document.get("pooler.default_pool_size")) |val| config.pooler.default_pool_size = try parseInt(u32, val);
    if (document.get("pooler.max_client_conn")) |val| config.pooler.max_client_conn = try parseInt(u32, val);

    // [proxy]
    if (document.get("proxy.mode")) |val| {
        const raw = try copyString(arena, val);
        config.proxy.mode = std.meta.stringToEnum(ProxyMode, raw) orelse return error.ConfigInvalid;
    }
    if (document.get("proxy.tls")) |val| {
        const raw = try copyString(arena, val);
        config.proxy.tls = std.meta.stringToEnum(TlsMode, raw) orelse return error.ConfigInvalid;
    }
    if (document.get("proxy.custom_cert")) |val| config.proxy.custom_cert = try copyString(arena, val);
    if (document.get("proxy.custom_key")) |val| config.proxy.custom_key = try copyString(arena, val);

    // [services]
    if (document.get("services.auth")) |val| config.services.auth = try parseBool(val);
    if (document.get("services.storage")) |val| config.services.storage = try parseBool(val);
    if (document.get("services.pg_meta")) |val| config.services.pg_meta = try parseBool(val);
    if (document.get("services.rest")) |val| config.services.rest = try parseBool(val);
    if (document.get("services.realtime")) |val| config.services.realtime = try parseBool(val);
    if (document.get("services.image_proxy")) |val| config.services.image_proxy = try parseBool(val);

    // [storage]
    if (document.get("storage.backend")) |val| {
        const raw = try copyString(arena, val);
        config.storage.backend = std.meta.stringToEnum(StorageBackend, raw) orelse return error.ConfigInvalid;
    }
    if (document.get("storage.max_upload")) |val| config.storage.max_upload = try copyString(arena, val);
    if (document.get("storage.s3_endpoint")) |val| config.storage.s3_endpoint = try copyString(arena, val);
    if (document.get("storage.s3_bucket")) |val| config.storage.s3_bucket = try copyString(arena, val);

    // [backup]
    if (document.get("backup.enabled")) |val| config.backup.enabled = try parseBool(val);
    if (document.get("backup.schedule")) |val| config.backup.schedule = try copyString(arena, val);
    if (document.get("backup.retain_daily")) |val| config.backup.retain_daily = try parseInt(u32, val);
    if (document.get("backup.retain_weekly")) |val| config.backup.retain_weekly = try parseInt(u32, val);
    if (document.get("backup.destination")) |val| config.backup.destination = try copyString(arena, val);
    if (document.get("backup.encrypt")) |val| config.backup.encrypt = try parseBool(val);

    // [logging]
    if (document.get("logging.level")) |val| {
        const raw = try copyString(arena, val);
        config.logging.level = parseLevel(raw) orelse return error.ConfigInvalid;
    }
    if (document.get("logging.format")) |val| {
        const raw = try copyString(arena, val);
        config.logging.format = std.meta.stringToEnum(LogFormat, raw) orelse return error.ConfigInvalid;
    }

    // [security]
    if (document.get("security.session_ttl")) |val| config.security.session_ttl = try copyString(arena, val);
    if (document.get("security.default_rate_limit")) |val| config.security.default_rate_limit = try copyString(arena, val);

    return config;
}

fn copyString(arena: Allocator, value: toml.Value) LoadError![]const u8 {
    return switch (value) {
        .string => |text| arena.dupe(u8, text) catch return error.OutOfMemory,
        else => error.ConfigInvalid,
    };
}

fn parseInt(comptime T: type, value: toml.Value) LoadError!T {
    return switch (value) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(T))
            @intCast(number)
        else
            return error.ConfigInvalid,
        else => error.ConfigInvalid,
    };
}

fn parseBool(value: toml.Value) LoadError!bool {
    return switch (value) {
        .boolean => |b| b,
        else => error.ConfigInvalid,
    };
}

fn parseLevel(raw: []const u8) ?LogLevel {
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
        \\database.mode={s}
        \\database.max_connections={d}
        \\database.url_file={?s}
        \\pooler.enabled={s}
        \\pooler.pool_mode={s}
        \\pooler.default_pool_size={d}
        \\pooler.max_client_conn={d}
        \\proxy.mode={s}
        \\proxy.tls={s}
        \\proxy.custom_cert={?s}
        \\proxy.custom_key={?s}
        \\services.auth={s}
        \\services.storage={s}
        \\services.pg_meta={s}
        \\services.rest={s}
        \\services.realtime={s}
        \\services.image_proxy={s}
        \\storage.backend={s}
        \\storage.max_upload={s}
        \\storage.s3_endpoint={?s}
        \\storage.s3_bucket={?s}
        \\backup.enabled={s}
        \\backup.schedule={s}
        \\backup.retain_daily={d}
        \\backup.retain_weekly={d}
        \\backup.destination={s}
        \\backup.encrypt={s}
        \\logging.level={s}
        \\logging.format={s}
        \\security.session_ttl={s}
        \\security.default_rate_limit={s}
        \\
    , .{
        config.schema_version,
        config.instance.name,
        config.instance.domain,
        config.instance.admin_email,
        config.instance.timezone,
        @tagName(config.database.mode),
        config.database.max_connections,
        config.database.url_file,
        if (config.pooler.enabled) "true" else "false",
        @tagName(config.pooler.pool_mode),
        config.pooler.default_pool_size,
        config.pooler.max_client_conn,
        @tagName(config.proxy.mode),
        @tagName(config.proxy.tls),
        config.proxy.custom_cert,
        config.proxy.custom_key,
        if (config.services.auth) "true" else "false",
        if (config.services.storage) "true" else "false",
        if (config.services.pg_meta) "true" else "false",
        if (config.services.rest) "true" else "false",
        if (config.services.realtime) "true" else "false",
        if (config.services.image_proxy) "true" else "false",
        @tagName(config.storage.backend),
        config.storage.max_upload,
        config.storage.s3_endpoint,
        config.storage.s3_bucket,
        if (config.backup.enabled) "true" else "false",
        config.backup.schedule,
        config.backup.retain_daily,
        config.backup.retain_weekly,
        config.backup.destination,
        if (config.backup.encrypt) "true" else "false",
        @tagName(config.logging.level),
        @tagName(config.logging.format),
        config.security.session_ttl,
        config.security.default_rate_limit,
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
    try std.testing.expectEqual(LogLevel.info, config.logging.level);
    try std.testing.expectEqual(DatabaseMode.managed, config.database.mode);
}

test "parse full configuration from TOML" {
    const source =
        \\schema_version = 1
        \\[instance]
        \\name = "acme"
        \\domain = "example.com"
        \\[database]
        \\mode = "managed"
        \\max_connections = 150
        \\[services]
        \\rest = true
        \\pg_meta = true
        \\[storage]
        \\max_upload = "100MB"
        \\[backup]
        \\schedule = "04:30"
        \\[logging]
        \\level = "debug"
        \\format = "text"
    ;

    var config = try fromSource(std.testing.allocator, source);
    defer config.deinit();

    try std.testing.expectEqualStrings("acme", config.instance.name);
    try std.testing.expectEqualStrings("example.com", config.instance.domain);
    try std.testing.expectEqual(@as(u32, 150), config.database.max_connections);
    try std.testing.expect(config.services.rest);
    try std.testing.expectEqualStrings("100MB", config.storage.max_upload);
    try std.testing.expectEqualStrings("04:30", config.backup.schedule);
    try std.testing.expectEqual(LogLevel.debug, config.logging.level);
    try std.testing.expectEqual(LogFormat.text, config.logging.format);

    var res = try validate.validate(std.testing.allocator, &config);
    defer res.deinit();
    try std.testing.expect(res.isValid());
}
