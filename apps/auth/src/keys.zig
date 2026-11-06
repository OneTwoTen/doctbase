const std = @import("std");

pub const KeyStatus = enum {
    active,
    rotated,
    retired,
};

pub const SigningKey = struct {
    id: []const u8,
    project_id: []const u8,
    algorithm: []const u8 = "EdDSA",
    public_key_hex: []const u8,
    status: KeyStatus = .active,
    created_at: i64,
};

pub const KeyManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) KeyManager {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn generateKey(self: KeyManager, project_id: []const u8, timestamp_s: i64) !SigningKey {
        var rand_bytes: [16]u8 = undefined;
        self.io.random(&rand_bytes);
        const id_hex = try std.fmt.allocPrint(self.allocator, "key_{s}", .{std.fmt.bytesToHex(rand_bytes, .lower)});

        // Generate Ed25519 keypair
        const pair = std.crypto.sign.Ed25519.KeyPair.generate(self.io);
        const pub_hex = try self.allocator.alloc(u8, 64);
        _ = std.fmt.bufPrint(pub_hex, "{s}", .{std.fmt.bytesToHex(pair.public_key.bytes, .lower)}) catch "";

        const proj_copy = try self.allocator.dupe(u8, project_id);

        return SigningKey{
            .id = id_hex,
            .project_id = proj_copy,
            .algorithm = "EdDSA",
            .public_key_hex = pub_hex,
            .status = .active,
            .created_at = timestamp_s,
        };
    }

    pub fn formatJwks(self: KeyManager, keys: []const SigningKey) ![]u8 {
        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        try buf.writer.writeAll("{\"keys\":[");
        for (keys, 0..) |k, i| {
            if (i > 0) try buf.writer.writeAll(",");
            try buf.writer.print(
                \\{{"kid":"{s}","kty":"OKP","crv":"Ed25519","alg":"{s}","use":"sig","x":"{s}","status":"{s}"}}
            , .{
                k.id,
                k.algorithm,
                k.public_key_hex,
                @tagName(k.status),
            });
        }
        try buf.writer.writeAll("]}");

        return try self.allocator.dupe(u8, buf.written());
    }
};

test "key manager generates Ed25519 key and formats JWKS" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const mgr = KeyManager.init(allocator, io);
    const key = try mgr.generateKey("proj_123", 1700000000);
    defer {
        allocator.free(key.id);
        allocator.free(key.project_id);
        allocator.free(key.public_key_hex);
    }

    try std.testing.expectEqualStrings("proj_123", key.project_id);
    try std.testing.expectEqualStrings("EdDSA", key.algorithm);
    try std.testing.expectEqual(@as(usize, 64), key.public_key_hex.len);

    const keys = [_]SigningKey{key};
    const jwks = try mgr.formatJwks(&keys);
    defer allocator.free(jwks);

    try std.testing.expect(std.mem.indexOf(u8, jwks, "\"keys\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, jwks, "\"kty\":\"OKP\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jwks, key.id) != null);
}
