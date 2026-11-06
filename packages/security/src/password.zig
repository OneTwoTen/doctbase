const std = @import("std");

pub fn hashPassword(allocator: std.mem.Allocator, io: std.Io, password: []const u8) ![]u8 {
    var out_buf: [128]u8 = undefined;
    const hash_str = try std.crypto.pwhash.argon2.strHash(
        password,
        .{
            .allocator = allocator,
            .params = .{ .t = 2, .m = 19456, .p = 1 },
            .mode = .argon2id,
        },
        &out_buf,
        io,
    );
    return try allocator.dupe(u8, hash_str);
}

pub fn verifyPassword(allocator: std.mem.Allocator, io: std.Io, password: []const u8, hash: []const u8) bool {
    std.crypto.pwhash.argon2.strVerify(
        hash,
        password,
        .{ .allocator = allocator },
        io,
    ) catch return false;
    return true;
}

test "hash and verify password with argon2id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const pw = "super-secret-admin-pass";
    const hashed = try hashPassword(allocator, io, pw);
    defer allocator.free(hashed);

    try std.testing.expect(verifyPassword(allocator, io, pw, hashed));
    try std.testing.expect(!verifyPassword(allocator, io, "wrong-password", hashed));
}
