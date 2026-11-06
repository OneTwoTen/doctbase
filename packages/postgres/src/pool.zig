const std = @import("std");

pub const ConnectionTarget = union(enum) {
    unix_socket: []const u8,
    tcp: struct {
        host: []const u8,
        port: u16 = 5432,
    },
};

pub const PoolConfig = struct {
    target: ConnectionTarget = .{ .unix_socket = "/var/run/postgresql/.s.PGSQL.5432" },
    database: []const u8 = "doctbase_control",
    user: []const u8 = "doctbase",
    password: ?[]const u8 = null,
    max_connections: u32 = 20,
    connect_timeout_ms: u32 = 5000,
};

pub const PgPool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PoolConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: PoolConfig) PgPool {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    pub fn deinit(self: *PgPool) void {
        _ = self;
    }
};

test "pool config sets reasonable defaults" {
    const config = PoolConfig{};
    try std.testing.expectEqualStrings("doctbase_control", config.database);
    try std.testing.expectEqualStrings("doctbase", config.user);
    try std.testing.expectEqual(@as(u32, 20), config.max_connections);
    try std.testing.expectEqualStrings("/var/run/postgresql/.s.PGSQL.5432", config.target.unix_socket);
}
