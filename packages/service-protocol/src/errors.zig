const std = @import("std");
const protocol = @import("protocol.zig");

pub const Problem = protocol.Problem;

pub fn formatProblemJson(
    allocator: std.mem.Allocator,
    problem: Problem,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    try std.json.Stringify.value(problem, .{}, &out.writer);
    return try allocator.dupe(u8, out.written());
}

test "formatProblemJson serializes RFC 9457 problem json" {
    const allocator = std.testing.allocator;
    const p = Problem{
        .type = "https://doctbase.dev/errors/DB_CONN_REFUSED",
        .title = "Database connection refused",
        .status = 503,
        .detail = "Cannot connect to PostgreSQL",
        .instance = "/internal/v1/info",
        .code = "DB_CONN_REFUSED",
        .request_id = "01JXYZ",
        .docs_url = "https://doctbase.dev/errors/DB_CONN_REFUSED",
    };

    const json = try formatProblemJson(allocator, p);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":\"DB_CONN_REFUSED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":503") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"request_id\":\"01JXYZ\"") != null);
}
