const std = @import("std");

pub const internal_protocol = "internal/v1";

pub const ReadinessStatus = enum {
    ready,
    degraded,
    not_ready,
};

pub const CheckStatus = enum {
    ok,
    warn,
    err,

    pub fn jsonStringify(self: CheckStatus, jw: anytype) !void {
        const text = switch (self) {
            .ok => "ok",
            .warn => "warn",
            .err => "error",
        };
        try jw.write(text);
    }
};

pub const ReadinessCheck = struct {
    name: []const u8,
    status: CheckStatus,
    detail: ?[]const u8 = null,
};

pub const ReadyResponse = struct {
    status: ReadinessStatus,
    checks: []const ReadinessCheck,
    version: []const u8,
    config_hash: []const u8,
    uptime_seconds: i64,
};

pub const InfoResponse = struct {
    service: []const u8,
    version: []const u8,
    commit: []const u8,
    mode: []const u8,
    uptime_seconds: i64,
    config_hash: []const u8,
    started_at: []const u8,
};

pub const Problem = struct {
    type: []const u8 = "about:blank",
    title: []const u8,
    status: u16,
    detail: ?[]const u8 = null,
    instance: ?[]const u8 = null,
    code: []const u8,
    request_id: []const u8,
    docs_url: []const u8,
};

test "ready response serializes enum tags" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const checks = [_]ReadinessCheck{
        .{ .name = "process", .status = .ok },
        .{ .name = "postgres", .status = .warn, .detail = "slow" },
    };
    const response = ReadyResponse{
        .status = .degraded,
        .checks = @constCast(&checks),
        .version = "0.1.0",
        .config_hash = "sha256:abc",
        .uptime_seconds = 12,
    };

    try std.json.Stringify.value(response, .{}, &out.writer);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"degraded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"warn\"") != null);
}
