//! Admin bootstrap metadata for the one-time setup token.
//!
//! The token value lives only in `/etc/doctbase/secrets/admin_setup_token`.
//! Management receives it as a systemd credential and needs one non-secret fact:
//! when the 30-minute window ends. Writing the deadline next to the admin store
//! keeps it stable across service restarts (the credential copy's mtime is the
//! service start, not the token creation). Repair never refreshes an existing
//! deadline.

const std = @import("std");

pub const control_directory = "/var/lib/doctbase/control";
pub const metadata_path = control_directory ++ "/setup.json";
pub const ttl_seconds: i64 = 30 * 60;
pub const metadata_mode: u16 = 0o640;
pub const metadata_owner = "root";
pub const metadata_group = "doctbase";

pub const Metadata = struct {
    created_at: i64,
    expires_at: i64,
    /// SHA-256 of the setup token. The hash is safe for management to read;
    /// the raw token stays in `/etc/doctbase/secrets/admin_setup_token`.
    token_hash: []const u8,
};

pub fn expiresAt(now: i64) i64 {
    return now + ttl_seconds;
}

pub fn tokenHashHex(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

pub fn render(
    allocator: std.mem.Allocator,
    created_at: i64,
    expires_at: i64,
    token_hash: []const u8,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, Metadata{
        .created_at = created_at,
        .expires_at = expires_at,
        .token_hash = token_hash,
    }, .{ .whitespace = .indent_2 });
}

/// Setup URL shown to the operator. The token stays out of logs and process
/// arguments; the dashboard reads it from the URL fragment in a later slice.
pub fn setupUrl(allocator: std.mem.Allocator, domain: []const u8) ![]u8 {
    if (domain.len != 0) return std.fmt.allocPrint(allocator, "https://admin.{s}/setup", .{domain});
    return allocator.dupe(u8, "https://127.0.0.1/setup (SSH tunnel to management.sock)");
}

test "bootstrap metadata has a stable 30 minute deadline" {
    const allocator = std.testing.allocator;
    const now = 1_700_000_000;
    const expires = expiresAt(now);
    try std.testing.expectEqual(@as(i64, 1_800), expires - now);

    const hash = try tokenHashHex(allocator, "setup-token");
    defer allocator.free(hash);
    try std.testing.expectEqual(@as(usize, 64), hash.len);

    const json = try render(allocator, now, expires, hash);
    defer allocator.free(json);
    var parsed = try std.json.parseFromSlice(Metadata, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(expires, parsed.value.expires_at);
    try std.testing.expectEqualStrings(hash, parsed.value.token_hash);
}

test "setup url avoids printing the token" {
    const allocator = std.testing.allocator;
    const url = try setupUrl(allocator, "example.com");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://admin.example.com/setup", url);
}
