const std = @import("std");

pub const RequestIdMiddleware = struct {
    pub const HEADER = "X-Request-Id";

    pub fn resolveOrGenerate(io: std.Io, existing: ?[]const u8, buf: *[32]u8) []const u8 {
        if (existing) |id| {
            if (id.len > 0 and id.len <= 64) return id;
        }

        var random_bytes: [16]u8 = undefined;
        io.random(&random_bytes);
        const hex = std.fmt.bytesToHex(random_bytes, .lower);
        @memcpy(buf[0..32], &hex);
        return buf[0..32];
    }
};

pub const BodyLimitMiddleware = struct {
    max_bytes: usize = 1024 * 1024, // 1MB default

    pub fn check(self: BodyLimitMiddleware, content_length: ?usize) bool {
        if (content_length) |len| {
            return len <= self.max_bytes;
        }
        return true;
    }
};

test "requestId middleware retains existing or generates 32 char hex" {
    const io = std.testing.io;
    var buf: [32]u8 = undefined;

    const kept = RequestIdMiddleware.resolveOrGenerate(io, "custom-req-id", &buf);
    try std.testing.expectEqualStrings("custom-req-id", kept);

    const generated = RequestIdMiddleware.resolveOrGenerate(io, null, &buf);
    try std.testing.expectEqual(@as(usize, 32), generated.len);
}

test "bodyLimit middleware checks sizes" {
    const limit = BodyLimitMiddleware{ .max_bytes = 100 };
    try std.testing.expect(limit.check(50));
    try std.testing.expect(!limit.check(150));
}
