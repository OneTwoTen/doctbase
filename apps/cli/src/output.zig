const std = @import("std");

pub const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    cli_misuse = 2,
    preflight_failed = 3,
    network_failed = 4,
    database_failed = 5,
    service_failed = 6,
    migration_failed = 7,
    permission_failed = 8,
    health_failed = 9,
    cancelled = 10,
};

pub const GlobalFlags = struct {
    config_path: ?[]const u8 = null,
    json: bool = false,
    yes: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
    no_color: bool = false,
    timeout_ms: ?u32 = null,
};

pub fn printJsonSuccess(allocator: std.mem.Allocator, data: anytype) !void {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    try buf.writer.writeAll("{\"ok\":true,\"data\":");
    try std.json.Stringify.value(data, .{}, &buf.writer);
    try buf.writer.writeAll("}\n");

    std.debug.print("{s}", .{buf.written()});
}

pub fn printJsonError(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
    fix: ?[]const u8,
    docs_url: ?[]const u8,
) !void {
    var buf = std.Io.Writer.Allocating.init(allocator);
    defer buf.deinit();

    try buf.writer.writeAll("{\"ok\":false,\"error\":{");
    try buf.writer.print("\"code\":\"{s}\",\"message\":\"{s}\"", .{ code, message });
    if (fix) |f| {
        try buf.writer.print(",\"fix\":\"{s}\"", .{f});
    }
    if (docs_url) |url| {
        try buf.writer.print(",\"docs_url\":\"{s}\"", .{url});
    }
    try buf.writer.writeAll("}}\n");

    std.debug.print("{s}", .{buf.written()});
}

test "exit code values match contract" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ExitCode.success));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ExitCode.general_error));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(ExitCode.cli_misuse));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(ExitCode.preflight_failed));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(ExitCode.service_failed));
    try std.testing.expectEqual(@as(u8, 9), @intFromEnum(ExitCode.health_failed));
}
