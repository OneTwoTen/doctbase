//! Release manifest schema, artifact selection, checksum and signature checks.
//!
//! The manifest is signed as a whole with Ed25519; each artifact carries its
//! SHA-256. The bootstrap installer verifies the signature first, then selects
//! the target artifact and verifies its checksum before extraction.

const std = @import("std");

pub const schema_version: u32 = 1;
pub const max_manifest_bytes: usize = 1024 * 1024;

pub const Artifact = struct {
    name: []const u8,
    target: []const u8,
    sha256: []const u8,
    signature: []const u8 = "",
    size: u64 = 0,
};

pub const Manifest = struct {
    schema_version: u32 = schema_version,
    version: []const u8,
    generated_at: []const u8 = "",
    artifacts: []const Artifact,
};

pub const Error = error{
    ManifestTooLarge,
    InvalidManifest,
    NoArtifactForTarget,
    InvalidChecksum,
    ChecksumMismatch,
    InvalidSignature,
};

pub fn parse(allocator: std.mem.Allocator, contents: []const u8) !std.json.Parsed(Manifest) {
    if (contents.len == 0 or contents.len > max_manifest_bytes) return Error.ManifestTooLarge;
    return std.json.parseFromSlice(Manifest, allocator, contents, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch Error.InvalidManifest;
}

pub fn targetName(arch: []const u8) ![]const u8 {
    if (std.mem.eql(u8, arch, "x86_64") or std.mem.eql(u8, arch, "amd64")) return "linux-x86_64";
    if (std.mem.eql(u8, arch, "aarch64") or std.mem.eql(u8, arch, "arm64")) return "linux-aarch64";
    return Error.NoArtifactForTarget;
}

pub fn select(manifest: Manifest, arch: []const u8) !Artifact {
    const target = try targetName(arch);
    for (manifest.artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.target, target)) return artifact;
    }
    return Error.NoArtifactForTarget;
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn verifyChecksum(data: []const u8, expected_hex: []const u8) !void {
    const trimmed = std.mem.trim(u8, expected_hex, " \t\r\n");
    if (trimmed.len != 64) return Error.InvalidChecksum;
    const actual = sha256Hex(data);
    if (!std.ascii.eqlIgnoreCase(&actual, trimmed)) return Error.ChecksumMismatch;
}

pub fn verifySignature(
    public_key: [32]u8,
    signature: [64]u8,
    message: []const u8,
) !void {
    const key = std.crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch return Error.InvalidSignature;
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature);
    sig.verify(message, key) catch return Error.InvalidSignature;
}

test "manifest selects the target artifact and validates checksums" {
    const allocator = std.testing.allocator;
    const json =
        \\{"schema_version":1,"version":"1.2.3","artifacts":[
        \\ {"name":"doctbase-1.2.3-linux-x86_64.tar.gz","target":"linux-x86_64","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        \\ {"name":"doctbase-1.2.3-linux-aarch64.tar.gz","target":"linux-aarch64","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
        \\]}
    ;
    var parsed = try parse(allocator, json);
    defer parsed.deinit();

    const x86 = try select(parsed.value, "x86_64");
    try std.testing.expectEqualStrings("doctbase-1.2.3-linux-x86_64.tar.gz", x86.name);
    const arm = try select(parsed.value, "aarch64");
    try std.testing.expectEqualStrings("doctbase-1.2.3-linux-aarch64.tar.gz", arm.name);
    try std.testing.expectError(Error.NoArtifactForTarget, select(parsed.value, "riscv64"));

    const payload = "artifact bytes";
    const digest = sha256Hex(payload);
    try verifyChecksum(payload, &digest);
    try std.testing.expectError(Error.ChecksumMismatch, verifyChecksum("other bytes", &digest));
}

test "ed25519 manifest signature verification" {
    const io = std.testing.io;
    const key_pair = std.crypto.sign.Ed25519.KeyPair.generate(io);
    const message = "{\"version\":\"1.0.0\"}";
    const signature = try key_pair.sign(message, null);

    try verifySignature(key_pair.public_key.toBytes(), signature.toBytes(), message);
    try std.testing.expectError(
        Error.InvalidSignature,
        verifySignature(key_pair.public_key.toBytes(), signature.toBytes(), "tampered"),
    );
}
