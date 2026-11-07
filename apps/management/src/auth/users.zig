const std = @import("std");
const security = @import("security");
const session_mod = @import("session.zig");

pub const MIN_PASSWORD_LENGTH = 12;

pub const UserStatus = enum {
    pending,
    active,
    disabled,
};

pub const AdminUser = struct {
    id: []u8,
    email: []u8,
    password_hash: []u8,
    role: session_mod.Role,
    status: UserStatus = .active,

    fn deinit(self: AdminUser, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.email);
        allocator.free(self.password_hash);
    }
};

/// In-memory admin user store for the management plane. The control database
/// (T026/T027) will replace this behind the same lookup/verify contract.
pub const UserStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    users: std.StringHashMap(AdminUser),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) UserStore {
        return .{
            .allocator = allocator,
            .io = io,
            .users = std.StringHashMap(AdminUser).init(allocator),
        };
    }

    pub fn deinit(self: *UserStore) void {
        var it = self.users.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.users.deinit();
    }

    pub fn addUser(
        self: *UserStore,
        email: []const u8,
        password: []const u8,
        role: session_mod.Role,
    ) !void {
        if (password.len < MIN_PASSWORD_LENGTH) return error.PasswordTooShort;

        const hash = try security.password.hashPassword(self.allocator, self.io, password);
        defer self.allocator.free(hash);
        try self.addUserWithHash(email, hash, role, .active);
    }

    pub fn addUserWithHash(
        self: *UserStore,
        email: []const u8,
        password_hash: []const u8,
        role: session_mod.Role,
        status: UserStatus,
    ) !void {
        const normalized = try normalizeEmail(self.allocator, email);
        errdefer self.allocator.free(normalized);

        if (self.users.contains(normalized)) return error.DuplicateEmail;

        const email_copy = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(email_copy);

        const hash_copy = try self.allocator.dupe(u8, password_hash);
        errdefer self.allocator.free(hash_copy);

        const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        const ulid = security.ids.generateUlid(self.io, now);
        const id = try self.allocator.dupe(u8, ulid[0..]);
        errdefer self.allocator.free(id);

        try self.users.put(normalized, .{
            .id = id,
            .email = email_copy,
            .password_hash = hash_copy,
            .role = role,
            .status = status,
        });
    }

    /// Returns an active user only when the password verifies. Unknown,
    /// disabled and wrong-password cases all return `null` so callers can emit
    /// one generic error.
    pub fn verifyCredentials(self: *UserStore, email: []const u8, password: []const u8) ?AdminUser {
        const normalized = normalizeEmail(self.allocator, email) catch return null;
        defer self.allocator.free(normalized);

        const user = self.users.get(normalized) orelse return null;
        if (user.status != .active) return null;
        if (!security.password.verifyPassword(self.allocator, self.io, password, user.password_hash)) {
            return null;
        }
        return user;
    }

    pub fn findByEmail(self: *UserStore, email: []const u8) ?AdminUser {
        const normalized = normalizeEmail(self.allocator, email) catch return null;
        defer self.allocator.free(normalized);
        return self.users.get(normalized);
    }

    pub fn findById(self: *UserStore, id: []const u8) ?AdminUser {
        var it = self.users.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.id, id)) return entry.value_ptr.*;
        }
        return null;
    }
};

fn normalizeEmail(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, email, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidEmail;

    const out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

test "user store adds users, rejects weak passwords and verifies argon2id hashes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var store = UserStore.init(allocator, io);
    defer store.deinit();

    try std.testing.expectError(
        error.PasswordTooShort,
        store.addUser("Admin@Example.com", "short", .owner),
    );

    try store.addUser("Admin@Example.com", "correct-horse-battery", .owner);

    const by_email = store.findByEmail("admin@example.com") orelse return error.TestExpectedUser;
    try std.testing.expectEqualStrings("admin@example.com", by_email.email);
    try std.testing.expectEqual(session_mod.Role.owner, by_email.role);
    try std.testing.expect(store.findById(by_email.id) != null);

    const verified = store.verifyCredentials("ADMIN@example.com", "correct-horse-battery") orelse return error.TestExpectedUser;
    try std.testing.expectEqualStrings(by_email.id, verified.id);
    try std.testing.expect(store.verifyCredentials("admin@example.com", "wrong-password") == null);
    try std.testing.expect(store.verifyCredentials("missing@example.com", "correct-horse-battery") == null);

    try std.testing.expectError(
        error.DuplicateEmail,
        store.addUserWithHash("ADMIN@example.com", "unused-hash", .viewer, .active),
    );
}

test "disabled user cannot authenticate" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var store = UserStore.init(allocator, io);
    defer store.deinit();

    const hash = try security.password.hashPassword(allocator, io, "correct-horse-battery");
    defer allocator.free(hash);

    try store.addUserWithHash("disabled@example.com", hash, .viewer, .disabled);
    try std.testing.expect(store.verifyCredentials("disabled@example.com", "correct-horse-battery") == null);
}
