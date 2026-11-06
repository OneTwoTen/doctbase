const std = @import("std");

pub const DatabaseMode = enum {
    managed,
    external,
};

pub const PoolMode = enum {
    transaction,
};

pub const ProxyMode = enum {
    caddy,
    external,
    none,
};

pub const TlsMode = enum {
    auto,
    internal,
    off,
    custom,
};

pub const StorageBackend = enum {
    local,
    s3,
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

pub const LogFormat = enum {
    json,
    text,
};

pub const Instance = struct {
    name: []const u8 = "doctbase",
    domain: []const u8 = "",
    admin_email: []const u8 = "",
    timezone: []const u8 = "UTC",
};

pub const Database = struct {
    mode: DatabaseMode = .managed,
    max_connections: u32 = 200,
    url_file: ?[]const u8 = null,
};

pub const Pooler = struct {
    enabled: bool = true,
    pool_mode: PoolMode = .transaction,
    default_pool_size: u32 = 10,
    max_client_conn: u32 = 1000,
};

pub const Proxy = struct {
    mode: ProxyMode = .caddy,
    tls: TlsMode = .auto,
    custom_cert: ?[]const u8 = null,
    custom_key: ?[]const u8 = null,
};

pub const Services = struct {
    auth: bool = true,
    storage: bool = true,
    pg_meta: bool = true,
    rest: bool = false,
    realtime: bool = false,
    image_proxy: bool = false,
};

pub const Storage = struct {
    backend: StorageBackend = .local,
    max_upload: []const u8 = "50MB",
    s3_endpoint: ?[]const u8 = null,
    s3_bucket: ?[]const u8 = null,
};

pub const Backup = struct {
    enabled: bool = true,
    schedule: []const u8 = "03:00",
    retain_daily: u32 = 7,
    retain_weekly: u32 = 4,
    destination: []const u8 = "local",
    encrypt: bool = false,
};

pub const Logging = struct {
    level: LogLevel = .info,
    format: LogFormat = .json,
};

pub const Security = struct {
    admin_ip_allowlist: []const []const u8 = &.{},
    session_ttl: []const u8 = "24h",
    default_rate_limit: []const u8 = "600/min",
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    schema_version: u32 = 1,
    instance: Instance = .{},
    database: Database = .{},
    pooler: Pooler = .{},
    proxy: Proxy = .{},
    services: Services = .{},
    storage: Storage = .{},
    backup: Backup = .{},
    logging: Logging = .{},
    security: Security = .{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

test "schema defaults match contract specifications" {
    const config = Config{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer @constCast(&config).deinit();

    try std.testing.expectEqual(@as(u32, 1), config.schema_version);
    try std.testing.expectEqualStrings("doctbase", config.instance.name);
    try std.testing.expectEqualStrings("", config.instance.domain);
    try std.testing.expectEqual(DatabaseMode.managed, config.database.mode);
    try std.testing.expectEqual(@as(u32, 200), config.database.max_connections);
    try std.testing.expect(config.pooler.enabled);
    try std.testing.expectEqual(ProxyMode.caddy, config.proxy.mode);
    try std.testing.expectEqual(TlsMode.auto, config.proxy.tls);
    try std.testing.expect(config.services.auth);
    try std.testing.expect(config.services.storage);
    try std.testing.expect(config.services.pg_meta);
    try std.testing.expect(!config.services.rest);
    try std.testing.expect(!config.services.realtime);
    try std.testing.expect(!config.services.image_proxy);
    try std.testing.expectEqual(StorageBackend.local, config.storage.backend);
    try std.testing.expectEqualStrings("50MB", config.storage.max_upload);
    try std.testing.expectEqualStrings("03:00", config.backup.schedule);
    try std.testing.expectEqual(LogLevel.info, config.logging.level);
    try std.testing.expectEqualStrings("24h", config.security.session_ttl);
}
