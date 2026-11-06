const std = @import("std");
const uds = @import("uds.zig");
const middleware = @import("middleware.zig");

pub const BindAddress = union(enum) {
    uds: []const u8,
    tcp: struct {
        host: []const u8 = "127.0.0.1",
        port: u16,
    },
};

pub const ServerConfig = struct {
    bind: BindAddress,
    body_limit: usize = 1024 * 1024,
    request_timeout_ms: u32 = 30000,
};

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: ServerConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: ServerConfig) !HttpServer {
        if (config.bind == .uds) {
            try uds.ensureSocketAvailable(io, config.bind.uds);
        }
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }
};

test "server init validates uds path" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const s = try HttpServer.init(allocator, io, .{
        .bind = .{ .uds = "/tmp/doctbase-test-server.sock" },
    });
    try std.testing.expectEqual(@as(usize, 1024 * 1024), s.config.body_limit);
}
