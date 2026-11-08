//! `POST /setup` payload parsing and the admin-creation step.
//!
//! Keeping this separate from the router makes the security-sensitive ordering
//! explicit: validate input, consume the one-time token, create the owner with
//! an Argon2id hash, then persist it. No default password exists.

const std = @import("std");
const users_mod = @import("../auth/users.zig");
const session_mod = @import("../auth/session.zig");
const setup_mod = @import("../auth/setup.zig");

pub const min_password_length = users_mod.MIN_PASSWORD_LENGTH;
pub const max_body_bytes: usize = 4096;

pub const Request = struct {
    setup_token: []const u8,
    email: []const u8,
    password: []const u8,
};

pub const Payload = struct {
    setup_token: []const u8 = "",
    email: []const u8 = "",
    password: []const u8 = "",
};

pub const Error = error{
    MalformedRequest,
    InvalidEmail,
    PasswordTooShort,
} || setup_mod.Error || std.mem.Allocator.Error;

pub fn parse(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(Payload) {
    if (body.len == 0 or body.len > max_body_bytes) return error.MalformedRequest;
    return std.json.parseFromSlice(Payload, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch error.MalformedRequest;
}

pub fn validate(payload: Payload) !void {
    const email = std.mem.trim(u8, payload.email, " \t\r\n");
    if (!validEmail(email)) return error.InvalidEmail;
    if (payload.password.len < min_password_length) return error.PasswordTooShort;
    if (payload.setup_token.len == 0) return error.SetupTokenInvalid;
}

pub fn complete(
    state: *setup_mod.State,
    store: *users_mod.UserStore,
    payload: Payload,
    now: i64,
) !users_mod.AdminUser {
    try validate(payload);
    try state.consume(payload.setup_token, store.count(), now);

    const email = std.mem.trim(u8, payload.email, " \t\r\n");
    store.addUser(email, payload.password, session_mod.Role.owner) catch |err| {
        // Do not burn the one-time token if persisting the admin failed.
        state.consumed = false;
        return switch (err) {
            error.DuplicateEmail => setup_mod.Error.SetupCompleted,
            else => err,
        };
    };
    state.markCompleted();

    return store.findByEmail(email) orelse error.SetupCompleted;
}

fn validEmail(email: []const u8) bool {
    if (email.len < 3 or email.len > 254) return false;
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return false;
    if (at == 0 or at + 1 == email.len) return false;
    if (std.mem.indexOfScalarPos(u8, email, at + 1, '@') != null) return false;
    for (email) |byte| {
        if (byte <= 0x20 or byte == '<' or byte == '>') return false;
    }
    return true;
}

test "setup validation rejects weak passwords and malformed emails" {
    try std.testing.expectError(error.InvalidEmail, validate(.{ .setup_token = "t", .email = "no-at", .password = "long-enough-password" }));
    try std.testing.expectError(error.PasswordTooShort, validate(.{ .setup_token = "t", .email = "a@example.com", .password = "short" }));
    try validate(.{ .setup_token = "t", .email = "a@example.com", .password = "long-enough-password" });
}
