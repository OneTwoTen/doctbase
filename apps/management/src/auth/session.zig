const std = @import("std");
const security = @import("security");

const ids = security.ids;
const secrets = security.secrets;

pub const SESSION_COOKIE = "doctbase_session";
pub const CSRF_COOKIE = "doctbase_csrf";
pub const DEFAULT_TTL_SECONDS: i64 = 24 * 60 * 60;

pub const Role = enum {
    owner,
    admin,
    viewer,

    pub fn canMutate(self: Role) bool {
        return self == .owner or self == .admin;
    }
};

/// How the current request proved its identity. Only ambient browser
/// credentials (the session cookie) require CSRF protection.
pub const SessionMethod = enum {
    none,
    cookie,
    bearer,
};

pub const Session = struct {
    id: []u8,
    user_id: []u8,
    role: Role,
    csrf_hash: [32]u8,
    created_at: i64,
    expires_at: i64,

    fn deinit(self: Session, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.user_id);
    }
};

pub const AuthContext = struct {
    method: SessionMethod = .none,
    is_authenticated: bool = false,
    user_id_buf: [128]u8 = undefined,
    user_id_len: usize = 0,
    session_id_buf: [128]u8 = undefined,
    session_id_len: usize = 0,
    role_value: ?Role = null,
    expires_at: i64 = 0,
    csrf_hash: ?[32]u8 = null,

    pub fn userId(self: AuthContext) []const u8 {
        return self.user_id_buf[0..self.user_id_len];
    }

    pub fn sessionId(self: AuthContext) []const u8 {
        return self.session_id_buf[0..self.session_id_len];
    }

    fn setUserId(self: *AuthContext, id: []const u8) void {
        const len = @min(id.len, self.user_id_buf.len);
        @memcpy(self.user_id_buf[0..len], id[0..len]);
        self.user_id_len = len;
    }

    fn setSessionId(self: *AuthContext, id: []const u8) void {
        const len = @min(id.len, self.session_id_buf.len);
        @memcpy(self.session_id_buf[0..len], id[0..len]);
        self.session_id_len = len;
    }

    pub fn role(self: AuthContext) ?Role {
        return self.role_value;
    }

    pub fn canMutate(self: AuthContext) bool {
        if (self.role_value) |current| return current.canMutate();
        return false;
    }

    pub fn requiresCsrf(self: AuthContext) bool {
        return self.method == .cookie;
    }
};

/// Raw credentials handed to the caller exactly once. The store keeps only
/// hashes, matching the `admin_sessions.token_hash`/`csrf_secret_hash` model.
pub const NewSession = struct {
    token: []u8,
    csrf_token: []u8,
    user_id: []u8,
    role: Role,
    expires_at: i64,

    pub fn deinit(self: NewSession, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.csrf_token);
        allocator.free(self.user_id);
    }
};

pub const Options = struct {
    ttl_seconds: i64 = DEFAULT_TTL_SECONDS,
    /// Production cookies are always `Secure`. Tests and local plain-HTTP
    /// development can opt out explicitly.
    cookie_secure: bool = true,
};

pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    internal_token: ?[]const u8 = null,
    ttl_seconds: i64 = DEFAULT_TTL_SECONDS,
    cookie_secure: bool = true,
    sessions: std.StringHashMap(Session),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, internal_token: ?[]const u8) SessionStore {
        return initWithOptions(allocator, io, internal_token, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        internal_token: ?[]const u8,
        options: Options,
    ) SessionStore {
        return .{
            .allocator = allocator,
            .io = io,
            .internal_token = internal_token,
            .ttl_seconds = options.ttl_seconds,
            .cookie_secure = options.cookie_secure,
            .sessions = std.StringHashMap(Session).init(allocator),
        };
    }

    pub fn deinit(self: *SessionStore) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.sessions.deinit();
    }

    /// Creates a session and returns the raw session/CSRF tokens. Only hashes
    /// are retained in the store.
    pub fn createSession(self: *SessionStore, user_id: []const u8, role: Role) !NewSession {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.purgeExpiredLocked();
        const now = nowSeconds(self.io);

        const token = try secrets.generateHexToken(self.allocator, self.io, 32);
        errdefer self.allocator.free(token);

        const csrf_token = try secrets.generateHexToken(self.allocator, self.io, 32);
        errdefer self.allocator.free(csrf_token);

        const token_hash = try self.hashTokenHex(token);
        errdefer self.allocator.free(token_hash);

        var csrf_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(csrf_token, &csrf_hash, .{});

        const ulid = ids.generateUlid(self.io, now * 1000);
        const session_id = try self.allocator.dupe(u8, ulid[0..]);
        errdefer self.allocator.free(session_id);

        const stored_user_id = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(stored_user_id);

        const return_user_id = try self.allocator.dupe(u8, user_id);
        errdefer self.allocator.free(return_user_id);

        const expires_at = now + self.ttl_seconds;
        try self.sessions.put(token_hash, .{
            .id = session_id,
            .user_id = stored_user_id,
            .role = role,
            .csrf_hash = csrf_hash,
            .created_at = now,
            .expires_at = expires_at,
        });

        return .{
            .token = token,
            .csrf_token = csrf_token,
            .user_id = return_user_id,
            .role = role,
            .expires_at = expires_at,
        };
    }

    pub fn authenticate(
        self: *SessionStore,
        cookie_header: ?[]const u8,
        auth_header: ?[]const u8,
    ) AuthContext {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Bearer credentials are for CLI/service callers only. Browsers never
        // receive this token, so CSRF does not apply.
        if (auth_header) |header| {
            if (std.mem.startsWith(u8, header, "Bearer ")) {
                if (self.internal_token) |expected| {
                    const token = std.mem.trim(u8, header["Bearer ".len..], " \t");
                    if (token.len == expected.len and secrets.constantTimeCompare(token, expected)) {
                        var context = AuthContext{
                            .method = .bearer,
                            .is_authenticated = true,
                            .role_value = .owner,
                            .expires_at = std.math.maxInt(i64),
                        };
                        context.setUserId("internal");
                        context.setSessionId("internal");
                        return context;
                    }
                }
            }
        }

        if (cookie_header) |cookies| {
            if (extractCookie(cookies, SESSION_COOKIE)) |token| {
                if (self.validateToken(token)) |session| {
                    var context = AuthContext{
                        .method = .cookie,
                        .is_authenticated = true,
                        .role_value = session.role,
                        .expires_at = session.expires_at,
                        .csrf_hash = session.csrf_hash,
                    };
                    context.setUserId(session.user_id);
                    context.setSessionId(session.id);
                    return context;
                }
            }
        }

        return .{};
    }

    pub fn purgeExpired(self: *SessionStore) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.purgeExpiredLocked();
    }

    fn purgeExpiredLocked(self: *SessionStore) void {
        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.allocator);

        const now = nowSeconds(self.io);
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.expires_at <= now) {
                expired.append(self.allocator, entry.key_ptr.*) catch return;
            }
        }

        for (expired.items) |key| {
            if (self.sessions.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                kv.value.deinit(self.allocator);
            }
        }
    }

    pub fn revokeByCookie(self: *SessionStore, cookie_header: ?[]const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const cookies = cookie_header orelse return false;
        const token = extractCookie(cookies, SESSION_COOKIE) orelse return false;
        const key = self.hashTokenHex(token) catch return false;

        if (self.sessions.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(key);
            kv.value.deinit(self.allocator);
            return true;
        }

        self.allocator.free(key);
        return false;
    }

    pub fn buildSessionCookie(
        self: *SessionStore,
        allocator: std.mem.Allocator,
        token: []const u8,
        max_age_seconds: i64,
    ) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}={s}; Path=/; HttpOnly;{s} SameSite=Lax; Max-Age={d}",
            .{ SESSION_COOKIE, token, self.securedSuffix(), max_age_seconds },
        );
    }

    /// The CSRF cookie is intentionally readable by JavaScript so the SPA can
    /// mirror it in the `X-CSRF-Token` header (double-submit + server-side hash).
    pub fn buildCsrfCookie(
        self: *SessionStore,
        allocator: std.mem.Allocator,
        token: []const u8,
        max_age_seconds: i64,
    ) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}={s}; Path=/;{s} SameSite=Lax; Max-Age={d}",
            .{ CSRF_COOKIE, token, self.securedSuffix(), max_age_seconds },
        );
    }

    pub fn clearSessionCookie(self: *SessionStore, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}=; Path=/; HttpOnly;{s} SameSite=Lax; Max-Age=0",
            .{ SESSION_COOKIE, self.securedSuffix() },
        );
    }

    pub fn clearCsrfCookie(self: *SessionStore, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}=; Path=/;{s} SameSite=Lax; Max-Age=0",
            .{ CSRF_COOKIE, self.securedSuffix() },
        );
    }

    fn validateToken(self: *SessionStore, token: []const u8) ?Session {
        const key = self.hashTokenHex(token) catch return null;
        defer self.allocator.free(key);

        const session = self.sessions.get(key) orelse return null;
        if (session.expires_at <= nowSeconds(self.io)) return null;
        return session;
    }

    fn hashTokenHex(self: *SessionStore, token: []const u8) ![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});

        const out = try self.allocator.alloc(u8, digest.len * 2);
        const hex = std.fmt.bytesToHex(digest, .lower);
        @memcpy(out, &hex);
        return out;
    }

    fn securedSuffix(self: *SessionStore) []const u8 {
        return if (self.cookie_secure) " Secure;" else "";
    }
};

pub fn validateCsrf(auth: AuthContext, provided: ?[]const u8) bool {
    if (auth.method == .bearer) return true;
    if (auth.method != .cookie) return false;

    const token = provided orelse return false;
    const expected = auth.csrf_hash orelse return false;

    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &actual, .{});
    return secrets.constantTimeCompare(&actual, &expected);
}

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

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

test "session creation stores hashes and issues secure httponly cookies" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var store = SessionStore.initWithOptions(allocator, io, null, .{});
    defer store.deinit();

    var created = try store.createSession("user-1", .admin);
    defer created.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 64), created.token.len);
    try std.testing.expectEqual(@as(usize, 64), created.csrf_token.len);
    try std.testing.expectEqual(Role.admin, created.role);

    const session_cookie = try store.buildSessionCookie(allocator, created.token, 3600);
    defer allocator.free(session_cookie);
    try std.testing.expect(std.mem.indexOf(u8, session_cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_cookie, "Secure") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_cookie, "SameSite=Lax") != null);

    const csrf_cookie = try store.buildCsrfCookie(allocator, created.csrf_token, 3600);
    defer allocator.free(csrf_cookie);
    try std.testing.expect(std.mem.indexOf(u8, csrf_cookie, "HttpOnly") == null);
    try std.testing.expect(std.mem.indexOf(u8, csrf_cookie, "Secure") != null);

    const cookie_header = try std.fmt.allocPrint(
        allocator,
        "{s}={s}",
        .{ SESSION_COOKIE, created.token },
    );
    defer allocator.free(cookie_header);

    const auth = store.authenticate(cookie_header, null);
    try std.testing.expect(auth.is_authenticated);
    try std.testing.expectEqual(SessionMethod.cookie, auth.method);
    try std.testing.expectEqual(Role.admin, auth.role().?);
    try std.testing.expect(auth.requiresCsrf());
    try std.testing.expect(validateCsrf(auth, created.csrf_token));
    try std.testing.expect(!validateCsrf(auth, "wrong-csrf-token"));
    try std.testing.expect(!validateCsrf(auth, null));
}

test "session rejects tampered, expired and revoked tokens" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var store = SessionStore.initWithOptions(allocator, io, null, .{ .ttl_seconds = -1 });
    defer store.deinit();

    var expired = try store.createSession("user-2", .viewer);
    defer expired.deinit(allocator);

    const expired_header = try std.fmt.allocPrint(
        allocator,
        "{s}={s}",
        .{ SESSION_COOKIE, expired.token },
    );
    defer allocator.free(expired_header);
    try std.testing.expect(!store.authenticate(expired_header, null).is_authenticated);

    var active_store = SessionStore.initWithOptions(allocator, io, null, .{});
    defer active_store.deinit();

    var active = try active_store.createSession("user-3", .owner);
    defer active.deinit(allocator);

    const active_header = try std.fmt.allocPrint(
        allocator,
        "{s}={s}",
        .{ SESSION_COOKIE, active.token },
    );
    defer allocator.free(active_header);

    try std.testing.expect(active_store.authenticate(active_header, null).is_authenticated);
    try std.testing.expect(active_store.revokeByCookie(active_header));
    try std.testing.expect(!active_store.authenticate(active_header, null).is_authenticated);

    const tampered = active_store.authenticate("doctbase_session=not-a-real-token", null);
    try std.testing.expect(!tampered.is_authenticated);
}

test "internal bearer token is owner and exempt from csrf" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var store = SessionStore.init(allocator, io, "admin-secret-token");
    defer store.deinit();

    const auth = store.authenticate(null, "Bearer admin-secret-token");
    try std.testing.expect(auth.is_authenticated);
    try std.testing.expectEqual(SessionMethod.bearer, auth.method);
    try std.testing.expectEqual(Role.owner, auth.role().?);
    try std.testing.expect(auth.canMutate());
    try std.testing.expect(validateCsrf(auth, null));

    const bad_auth = store.authenticate(null, "Bearer wrong-token");
    try std.testing.expect(!bad_auth.is_authenticated);
    try std.testing.expectEqual(@as(?Role, null), bad_auth.role());
}
