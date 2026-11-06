const std = @import("std");
const redact = @import("redact.zig");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn label(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const LogFormat = enum {
    json,
    text,
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    service_name: []const u8,
    level: LogLevel = .info,
    format: LogFormat = .json,

    pub fn init(allocator: std.mem.Allocator, service_name: []const u8, level: LogLevel, format: LogFormat) Logger {
        return .{
            .allocator = allocator,
            .service_name = service_name,
            .level = level,
            .format = format,
        };
    }

    pub fn formatLog(
        self: Logger,
        level: LogLevel,
        msg: []const u8,
        request_id: ?[]const u8,
        timestamp_ms: i64,
    ) ![]u8 {
        if (@backingInt(level) < @backingInt(self.level)) {
            return &.{};
        }

        const redacted_msg = try redact.redact(self.allocator, msg);
        defer self.allocator.free(redacted_msg);

        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        switch (self.format) {
            .json => {
                try buf.writer.print(
                    \\{{"timestamp":{d},"level":"{s}","service":"{s}","message":"{s}"
                , .{
                    timestamp_ms,
                    level.label(),
                    self.service_name,
                    redacted_msg,
                });
                if (request_id) |rid| {
                    try buf.writer.print(
                        \\,"request_id":"{s}"
                    , .{rid});
                }
                try buf.writer.writeAll("}\n");
            },
            .text => {
                try buf.writer.print("[{s}] [{s}] {s}", .{
                    level.label(),
                    self.service_name,
                    redacted_msg,
                });
                if (request_id) |rid| {
                    try buf.writer.print(" (request_id={s})", .{rid});
                }
                try buf.writer.writeAll("\n");
            },
        }

        return try self.allocator.dupe(u8, buf.written());
    }
};

test "logger formats json with redaction" {
    const allocator = std.testing.allocator;
    const logger = Logger.init(allocator, "gateway", .info, .json);

    const log_line = try logger.formatLog(.info, "User login with password=123456", "req-01", 1700000000000);
    defer allocator.free(log_line);

    try std.testing.expect(std.mem.indexOf(u8, log_line, "123456") == null);
    try std.testing.expect(std.mem.indexOf(u8, log_line, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_line, "\"level\":\"INFO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_line, "\"service\":\"gateway\"") != null);
}
