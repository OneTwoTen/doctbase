//! One-time admin setup token state.
//!
//! The installer generates `admin_setup_token` and a non-secret
//! `/var/lib/doctbase/control/setup.json` deadline. Management loads the token
//! from its systemd credential (native) or a `_FILE`/env value (development),
//! stores only a SHA-256 hash in memory and consumes it once. Persistence of the
//! created admin is handled by `UserStore`; after an admin exists setup is
//! permanently closed even if the token file is still present.

const std = @import("std");
const security = @import("security");

pub const ttl_seconds: i64 = 30 * 60;
pub const max_token_bytes: usize = 512;
pub const metadata_path = "/var/lib/doctbase/control/setup.json";

pub const Error = error{
    SetupUnavailable,
    SetupCompleted,
    SetupTokenInvalid,
    SetupTokenExpired,
    InvalidToken,
};

pub const Status = struct {
    required: bool,
    expired: bool,
    available: bool,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    token_hash: [32]u8 = undefined,
    available: bool = false,
    consumed: bool = false,
    expires_at: i64 = 0,

    pub fn disabled(allocator: std.mem.Allocator, io: std.Io) State {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn initFromToken(allocator: std.mem.Allocator, io: std.Io, token: []const u8, expires_at: i64) !State {
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_token_bytes) return Error.InvalidToken;

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(trimmed, &hash, .{});
        return .{
            .allocator = allocator,
            .io = io,
            .token_hash = hash,
            .available = true,
            .expires_at = expires_at,
        };
    }

    pub fn initFromHash(allocator: std.mem.Allocator, io: std.Io, hash_hex: []const u8, expires_at: i64) !State {
        const trimmed = std.mem.trim(u8, hash_hex, " \t\r\n");
        if (trimmed.len != 64) return Error.InvalidToken;

        var hash: [32]u8 = undefined;
        const decoded = std.fmt.hexToBytes(&hash, trimmed) catch return Error.InvalidToken;
        if (decoded.len != 32) return Error.InvalidToken;

        return .{
            .allocator = allocator,
            .io = io,
            .token_hash = hash,
            .available = true,
            .expires_at = expires_at,
        };
    }

    pub fn status(self: *const State, user_count: usize, now: i64) Status {
        const has_admin = user_count != 0;
        return .{
            .required = self.available and !self.consumed and !has_admin,
            .expired = self.available and now >= self.expires_at,
            .available = self.available,
        };
    }

    pub fn consume(self: *State, candidate: []const u8, user_count: usize, now: i64) !void {
        if (!self.available) return Error.SetupUnavailable;
        if (self.consumed or user_count != 0) return Error.SetupCompleted;

        const trimmed = std.mem.trim(u8, candidate, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_token_bytes) return Error.SetupTokenInvalid;

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(trimmed, &hash, .{});
        if (!security.secrets.constantTimeCompare(&hash, &self.token_hash)) return Error.SetupTokenInvalid;
        if (now >= self.expires_at) return Error.SetupTokenExpired;

        self.consumed = true;
    }

    /// Close setup after the admin record has been persisted.
    pub fn markCompleted(self: *State) void {
        self.consumed = true;
    }
};

/// Build setup state from systemd credentials / environment / files. Missing
/// token means setup is unavailable rather than silently open.
pub fn fromEnvironment(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !State {
    const info = try loadMetadata(allocator, io, environ);
    defer if (info.token_hash) |hash| allocator.free(hash);

    if (info.token_hash) |hash| {
        return State.initFromHash(allocator, io, hash, info.expires_at);
    }

    const token = try loadToken(allocator, io, environ) orelse return State.disabled(allocator, io);
    defer allocator.free(token);
    return State.initFromToken(allocator, io, token, info.expires_at);
}

fn loadToken(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !?[]u8 {
    if (environ.get("CREDENTIALS_DIRECTORY")) |dir| {
        const path = try std.fmt.allocPrint(allocator, "{s}/admin_setup_token", .{dir});
        defer allocator.free(path);
        if (try readOptional(io, allocator, path)) |value| return value;
    }
    if (environ.get("DOCTBASE_SETUP_TOKEN")) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len != 0) return try allocator.dupe(u8, value);
    }
    const path = environ.get("DOCTBASE_SETUP_TOKEN_FILE") orelse "/etc/doctbase/secrets/admin_setup_token";
    return readOptional(io, allocator, path);
}

const MetadataInfo = struct {
    expires_at: i64,
    token_hash: ?[]u8 = null,
};

fn loadMetadata(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !MetadataInfo {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    var expires_at: i64 = now + ttl_seconds;
    if (environ.get("DOCTBASE_SETUP_EXPIRES_AT")) |value| {
        if (std.fmt.parseInt(i64, std.mem.trim(u8, value, " \t\r\n"), 10)) |parsed| {
            expires_at = parsed;
        } else |_| {}
    }

    const path = environ.get("DOCTBASE_SETUP_METADATA") orelse metadata_path;
    const contents = try readOptional(io, allocator, path) orelse return .{ .expires_at = expires_at };
    defer allocator.free(contents);

    const Metadata = struct {
        expires_at: i64 = 0,
        token_hash: []const u8 = "",
    };
    var parsed = std.json.parseFromSlice(Metadata, allocator, contents, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .expires_at = expires_at };
    defer parsed.deinit();

    if (parsed.value.expires_at > 0) expires_at = parsed.value.expires_at;
    const token_hash = if (std.mem.trim(u8, parsed.value.token_hash, " \t\r\n").len == 64)
        try allocator.dupe(u8, std.mem.trim(u8, parsed.value.token_hash, " \t\r\n"))
    else
        null;
    return .{ .expires_at = expires_at, .token_hash = token_hash };
}

fn readOptional(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.NotDir => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (trimmed.len == contents.len) return contents;
    const copy = try allocator.dupe(u8, trimmed);
    allocator.free(contents);
    return copy;
}

test "setup token is one-time and expires" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var state = try State.initFromToken(allocator, io, "one-time-token", 1_000);
    try std.testing.expect(state.status(0, 999).required);
    try std.testing.expect(!state.status(1, 999).required);
    try std.testing.expect(state.status(0, 1_000).expired);

    try std.testing.expectError(Error.SetupTokenExpired, state.consume("one-time-token", 0, 1_000));
    try std.testing.expectError(Error.SetupTokenInvalid, state.consume("wrong-token", 0, 999));
    try state.consume("one-time-token", 0, 999);
    try std.testing.expectError(Error.SetupCompleted, state.consume("one-time-token", 0, 999));
    try std.testing.expect(!state.status(0, 999).required);
}

test "setup unavailable without token and closed after admin exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var disabled = State.disabled(allocator, io);
    try std.testing.expect(!disabled.status(0, 0).required);
    try std.testing.expectError(Error.SetupUnavailable, disabled.consume("x", 0, 0));

    var state = try State.initFromToken(allocator, io, "token", 100);
    try std.testing.expectError(Error.SetupCompleted, state.consume("token", 1, 0));
}
