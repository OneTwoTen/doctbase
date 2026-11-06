const std = @import("std");

pub fn constantTimeCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

pub fn generateRandomBytes(io: std.Io, buf: []u8) void {
    io.random(buf);
}

pub fn generateHexToken(allocator: std.mem.Allocator, io: std.Io, byte_len: usize) ![]u8 {
    const raw = try allocator.alloc(u8, byte_len);
    defer allocator.free(raw);
    io.random(raw);

    const hex = try allocator.alloc(u8, byte_len * 2);
    for (raw, 0..) |b, i| {
        const hex_chars = "0123456789abcdef";
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return hex;
}

pub const ApiKey = struct {
    key: []u8,
    hash: [32]u8,
    prefix: []const u8,

    pub fn deinit(self: ApiKey, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
    }
};

pub fn generateApiKey(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) !ApiKey {
    const random_hex = try generateHexToken(allocator, io, 24);
    defer allocator.free(random_hex);

    const full_key = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, random_hex });

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(full_key, &hash, .{});

    return ApiKey{
        .key = full_key,
        .hash = hash,
        .prefix = prefix,
    };
}

test "constant time compare" {
    try std.testing.expect(constantTimeCompare("secret-token-123", "secret-token-123"));
    try std.testing.expect(!constantTimeCompare("secret-token-123", "secret-token-456"));
    try std.testing.expect(!constantTimeCompare("short", "longer"));
}

test "generate api key and verify hash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const key = try generateApiKey(allocator, io, "dtb_anon");
    defer key.deinit(allocator);

    try std.testing.expect(std.mem.startsWith(u8, key.key, "dtb_anon_"));
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key.key, &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &key.hash);
}
