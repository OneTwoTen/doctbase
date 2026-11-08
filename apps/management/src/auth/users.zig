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

const PersistedUser = struct {
    id: []const u8,
    email: []const u8,
    password_hash: []const u8,
    role: []const u8,
    status: []const u8,
};

const PersistedStore = struct {
    users: []const PersistedUser,
};

/// Admin user store for the management plane. The control database
/// (T026/T027) will replace the optional JSON persistence behind the same
/// lookup/verify contract; the in-memory mode remains for tests.
pub const UserStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    users: std.StringHashMap(AdminUser),
    /// Optional JSON persistence path. `null` keeps the store in-memory for
    /// tests; production management uses a 0600 file until the control database
    /// repository replaces it behind the same contract.
    path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) UserStore {
        return .{
            .allocator = allocator,
            .io = io,
            .users = std.StringHashMap(AdminUser).init(allocator),
        };
    }

    pub fn initPersistent(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !UserStore {
        var store = UserStore.init(allocator, io);
        errdefer store.deinit();
        store.path = try allocator.dupe(u8, path);

        const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer allocator.free(contents);

        var parsed = std.json.parseFromSlice(PersistedStore, allocator, contents, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.InvalidAdminStore;
        defer parsed.deinit();

        for (parsed.value.users) |user| {
            const role = std.meta.stringToEnum(session_mod.Role, user.role) orelse return error.InvalidAdminStore;
            const status = std.meta.stringToEnum(UserStatus, user.status) orelse return error.InvalidAdminStore;
            try store.putUser(user.id, user.email, user.password_hash, role, status);
        }
        return store;
    }

    pub fn deinit(self: *UserStore) void {
        var it = self.users.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.users.deinit();
        if (self.path) |path| self.allocator.free(path);
    }

    pub fn count(self: *const UserStore) usize {
        return self.users.count();
    }

    pub fn hasUsers(self: *const UserStore) bool {
        return self.users.count() != 0;
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
        try self.putUser(null, email, password_hash, role, status);
        try self.persist();
    }

    fn putUser(
        self: *UserStore,
        id: ?[]const u8,
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

        const id_copy = if (id) |value|
            try self.allocator.dupe(u8, value)
        else blk: {
            const now = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
            const ulid = security.ids.generateUlid(self.io, now);
            break :blk try self.allocator.dupe(u8, ulid[0..]);
        };
        errdefer self.allocator.free(id_copy);

        try self.users.put(normalized, .{
            .id = id_copy,
            .email = email_copy,
            .password_hash = hash_copy,
            .role = role,
            .status = status,
        });
    }

    fn persist(self: *UserStore) !void {
        const path = self.path orelse return;

        var list: std.ArrayList(PersistedUser) = .empty;
        defer list.deinit(self.allocator);
        var it = self.users.iterator();
        while (it.next()) |entry| {
            try list.append(self.allocator, .{
                .id = entry.value_ptr.id,
                .email = entry.value_ptr.email,
                .password_hash = entry.value_ptr.password_hash,
                .role = @tagName(entry.value_ptr.role),
                .status = @tagName(entry.value_ptr.status),
            });
        }

        const json = try std.json.Stringify.valueAlloc(self.allocator, PersistedStore{ .users = list.items }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);

        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, json);
        try atomic.file.writeStreamingAll(self.io, "\n");
        try atomic.replace(self.io);
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

test "persistent user store survives a reload" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(allocator, "{s}/admin.json", .{path_buffer[0..length]});
    defer allocator.free(path);

    var store = try UserStore.initPersistent(allocator, io, path);
    defer store.deinit();
    try store.addUser("Owner@Example.com", "correct-horse-battery", .owner);

    var reloaded = try UserStore.initPersistent(allocator, io, path);
    defer reloaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), reloaded.count());
    const user = reloaded.verifyCredentials("owner@example.com", "correct-horse-battery") orelse return error.TestExpectedUser;
    try std.testing.expectEqual(session_mod.Role.owner, user.role);
    try std.testing.expect(reloaded.verifyCredentials("owner@example.com", "wrong-password") == null);
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
