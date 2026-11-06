const std = @import("std");

pub const Role = enum {
    owner,
    admin,
    viewer,

    pub fn canMutate(self: Role) bool {
        return self == .owner or self == .admin;
    }
};

pub const Session = struct {
    id: []const u8,
    user_id: []const u8,
    role: Role,
    expires_at: i64,
};

pub const AuthContext = struct {
    session: ?Session = null,
    is_authenticated: bool = false,

    pub fn role(self: AuthContext) ?Role {
        if (self.session) |s| return s.role;
        return null;
    }

    pub fn canMutate(self: AuthContext) bool {
        if (self.session) |s| return s.role.canMutate();
        return false;
    }
};

pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    internal_token: ?[]const u8 = null,
    sessions: std.StringHashMap(Session),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, internal_token: ?[]const u8) SessionStore {
        return .{
            .allocator = allocator,
            .io = io,
            .internal_token = internal_token,
            .sessions = std.StringHashMap(Session).init(allocator),
        };
    }

    pub fn deinit(self: *SessionStore) void {
        self.sessions.deinit();
    }

    pub fn addSession(self: *SessionStore, token: []const u8, session: Session) !void {
        try self.sessions.put(token, session);
    }

    pub fn authenticate(self: *SessionStore, cookie_header: ?[]const u8, auth_header: ?[]const u8) AuthContext {
        // 1. Check Bearer token in Authorization header
        if (auth_header) |header| {
            if (std.mem.startsWith(u8, header, "Bearer ")) {
                const token = std.mem.trim(u8, header[7..], " \t");
                if (self.validateToken(token)) |session| {
                    return .{ .session = session, .is_authenticated = true };
                }
            }
        }

        // 2. Check doctbase_session cookie
        if (cookie_header) |cookies| {
            if (extractCookie(cookies, "doctbase_session")) |token| {
                if (self.validateToken(token)) |session| {
                    return .{ .session = session, .is_authenticated = true };
                }
            }
        }

        return .{ .is_authenticated = false };
    }

    fn validateToken(self: *SessionStore, token: []const u8) ?Session {
        if (self.internal_token) |expected| {
            if (constantTimeEql(token, expected)) {
                return .{
                    .id = "internal-session",
                    .user_id = "admin",
                    .role = .owner,
                    .expires_at = std.math.maxInt(i64),
                };
            }
        }

        if (self.sessions.get(token)) |session| {
            const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
            if (session.expires_at > now) {
                return session;
            }
        }

        return null;
    }
};

pub fn extractCookie(cookies: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, cookies, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const cookie_name = trimmed[0..eq];
        if (std.mem.eql(u8, cookie_name, name)) {
            return std.mem.trim(u8, trimmed[eq + 1 ..], " \t\"");
        }
    }
    return null;
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |left, right| diff |= left ^ right;
    return diff == 0;
}

test "session store authenticates internal bearer token as owner" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var store = SessionStore.init(allocator, io, "admin-secret-token");
    defer store.deinit();

    const auth = store.authenticate(null, "Bearer admin-secret-token");
    try std.testing.expect(auth.is_authenticated);
    try std.testing.expectEqual(Role.owner, auth.role().?);
    try std.testing.expect(auth.canMutate());

    const bad_auth = store.authenticate(null, "Bearer wrong-token");
    try std.testing.expect(!bad_auth.is_authenticated);
    try std.testing.expectEqual(@as(?Role, null), bad_auth.role());
}

test "session store authenticates cookie session and respects role and expiration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var store = SessionStore.init(allocator, io, null);
    defer store.deinit();

    const future = std.Io.Timestamp.now(io, .real).toSeconds() + 3600;
    try store.addSession("viewer-token-123", .{
        .id = "s-1",
        .user_id = "user-1",
        .role = .viewer,
        .expires_at = future,
    });

    const cookie_str = "other=123; doctbase_session=viewer-token-123; lang=vi";
    const auth = store.authenticate(cookie_str, null);
    try std.testing.expect(auth.is_authenticated);
    try std.testing.expectEqual(Role.viewer, auth.role().?);
    try std.testing.expect(!auth.canMutate());

    const past = std.Io.Timestamp.now(io, .real).toSeconds() - 100;
    try store.addSession("expired-token", .{
        .id = "s-2",
        .user_id = "user-2",
        .role = .admin,
        .expires_at = past,
    });

    const expired_auth = store.authenticate("doctbase_session=expired-token", null);
    try std.testing.expect(!expired_auth.is_authenticated);
}
