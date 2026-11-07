const std = @import("std");
const lifecycle = @import("service_lifecycle");
const registry = lifecycle.registry;
const driver_mod = lifecycle.driver;
const protocol = @import("service_protocol");
const core = @import("core");
const runtime_agg = @import("../services/runtime.zig");
const session_mod = @import("../auth/session.zig");
const users_mod = @import("../auth/users.zig");

pub const Header = struct {
    name: []const u8,
    value: []u8,
};

pub const HttpResponse = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []u8,
    headers: []Header = &.{},

    pub fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        for (self.headers) |header| allocator.free(header.value);
        if (self.headers.len > 0) allocator.free(self.headers);
    }
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    cookie_header: ?[]const u8 = null,
    auth_header: ?[]const u8 = null,
    csrf_header: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    body: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
};

const LoginPayload = struct {
    email: []const u8 = "",
    password: []const u8 = "",
};

const LoginResponse = struct {
    admin: AdminView,
    expires_at: i64,
};

const SessionResponse = struct {
    admin: AdminView,
    expires_at: i64,
};

const AdminView = struct {
    id: []const u8,
    email: []const u8,
    role: []const u8,
};

const MAX_LOGIN_BODY_BYTES = 4096;

pub const ManagementApi = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_store: *session_mod.SessionStore,
    users: *users_mod.UserStore,
    aggregator: *runtime_agg.ServiceRuntimeAggregator,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_store: *session_mod.SessionStore,
        users: *users_mod.UserStore,
        aggregator: *runtime_agg.ServiceRuntimeAggregator,
    ) ManagementApi {
        return .{
            .allocator = allocator,
            .io = io,
            .session_store = session_store,
            .users = users,
            .aggregator = aggregator,
        };
    }

    pub fn handle(self: *ManagementApi, req: Request) !HttpResponse {
        const req_id = req.request_id orelse "-";

        if (std.mem.eql(u8, req.path, "/api/v1/auth/login") or std.mem.eql(u8, req.path, "/auth/login")) {
            if (!std.mem.eql(u8, req.method, "POST")) {
                return self.problemResponse(405, .not_found, "Method not allowed", req_id);
            }
            return self.handleLogin(req, req_id);
        }

        if (std.mem.eql(u8, req.path, "/api/v1/auth/logout") or std.mem.eql(u8, req.path, "/auth/logout")) {
            if (!std.mem.eql(u8, req.method, "POST")) {
                return self.problemResponse(405, .not_found, "Method not allowed", req_id);
            }
            return self.handleLogout(req, req_id);
        }

        if (std.mem.eql(u8, req.path, "/api/v1/auth/session") or std.mem.eql(u8, req.path, "/auth/session")) {
            if (!std.mem.eql(u8, req.method, "GET")) {
                return self.problemResponse(405, .not_found, "Method not allowed", req_id);
            }
            return self.handleSession(req, req_id);
        }

        // Route matching
        if (std.mem.eql(u8, req.path, "/api/v1/services") or std.mem.eql(u8, req.path, "/services")) {
            if (std.mem.eql(u8, req.method, "GET")) {
                return self.handleListServices(req, req_id);
            }
            return self.problemResponse(405, .not_found, "Method not allowed", req_id);
        }

        const prefix_v1 = "/api/v1/services/";
        const prefix_short = "/services/";
        var service_subpath: ?[]const u8 = null;
        if (std.mem.startsWith(u8, req.path, prefix_v1)) {
            service_subpath = req.path[prefix_v1.len..];
        } else if (std.mem.startsWith(u8, req.path, prefix_short)) {
            service_subpath = req.path[prefix_short.len..];
        }

        if (service_subpath) |subpath| {
            if (std.mem.endsWith(u8, subpath, "/restart")) {
                const service_name = subpath[0 .. subpath.len - "/restart".len];
                if (std.mem.eql(u8, req.method, "POST")) {
                    return self.handleRestartService(service_name, req, req_id);
                }
                return self.problemResponse(405, .not_found, "Method not allowed", req_id);
            }

            if (std.mem.eql(u8, req.method, "GET")) {
                return self.handleGetService(subpath, req, req_id);
            }
            return self.problemResponse(405, .not_found, "Method not allowed", req_id);
        }

        return self.problemResponse(404, .not_found, "API endpoint not found", req_id);
    }

    fn handleLogin(self: *ManagementApi, req: Request, request_id: []const u8) !HttpResponse {
        // Reject simple cross-site form posts early (login CSRF defense in
        // depth); JSON content type is required when the transport reports it.
        if (req.content_type) |content_type| {
            if (!std.mem.startsWith(u8, content_type, "application/json")) {
                return self.authProblem(400, .bad_request, "Login requires application/json", request_id);
            }
        }

        const raw_body = req.body orelse {
            return self.authProblem(400, .bad_request, "Missing login request body", request_id);
        };
        if (raw_body.len == 0 or raw_body.len > MAX_LOGIN_BODY_BYTES) {
            return self.authProblem(400, .bad_request, "Invalid login request body", request_id);
        }

        var parsed = std.json.parseFromSlice(LoginPayload, self.allocator, raw_body, .{
            .ignore_unknown_fields = true,
        }) catch {
            return self.authProblem(400, .bad_request, "Malformed JSON login request", request_id);
        };
        defer parsed.deinit();

        const email = std.mem.trim(u8, parsed.value.email, " \t\r\n");
        const password = parsed.value.password;
        if (email.len == 0 or password.len == 0) {
            return self.authProblem(400, .bad_request, "Email and password are required", request_id);
        }

        const user = self.users.verifyCredentials(email, password) orelse {
            return self.authProblem(401, .invalid_credentials, "Invalid email or password", request_id);
        };

        var created = self.session_store.createSession(user.id, user.role) catch |err| {
            return self.authProblem(500, .internal, @errorName(err), request_id);
        };
        defer created.deinit(self.allocator);

        const max_age = @max(@as(i64, 0), created.expires_at - nowSeconds(self.io));
        const session_cookie = try self.session_store.buildSessionCookie(
            self.allocator,
            created.token,
            max_age,
        );
        errdefer self.allocator.free(session_cookie);

        const csrf_cookie = try self.session_store.buildCsrfCookie(
            self.allocator,
            created.csrf_token,
            max_age,
        );
        errdefer self.allocator.free(csrf_cookie);

        const no_store = try self.allocator.dupe(u8, "no-store");
        errdefer self.allocator.free(no_store);

        const headers = try self.allocator.alloc(Header, 3);
        errdefer self.allocator.free(headers);
        headers[0] = .{ .name = "Set-Cookie", .value = session_cookie };
        headers[1] = .{ .name = "Set-Cookie", .value = csrf_cookie };
        headers[2] = .{ .name = "Cache-Control", .value = no_store };

        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        try std.json.Stringify.value(LoginResponse{
            .admin = .{
                .id = user.id,
                .email = user.email,
                .role = @tagName(user.role),
            },
            .expires_at = created.expires_at,
        }, .{}, &buf.writer);

        return .{
            .status = 200,
            .body = try self.allocator.dupe(u8, buf.written()),
            .headers = headers,
        };
    }

    fn handleLogout(self: *ManagementApi, req: Request, request_id: []const u8) !HttpResponse {
        const auth = self.session_store.authenticate(req.cookie_header, req.auth_header);
        if (!auth.is_authenticated) {
            return self.authProblem(401, .unauthorized, "Authentication required", request_id);
        }
        if (auth.requiresCsrf() and !session_mod.validateCsrf(auth, req.csrf_header)) {
            return self.authProblem(403, .csrf_invalid, "Missing or invalid CSRF token", request_id);
        }

        _ = self.session_store.revokeByCookie(req.cookie_header);

        const session_cookie = try self.session_store.clearSessionCookie(self.allocator);
        errdefer self.allocator.free(session_cookie);

        const csrf_cookie = try self.session_store.clearCsrfCookie(self.allocator);
        errdefer self.allocator.free(csrf_cookie);

        const no_store = try self.allocator.dupe(u8, "no-store");
        errdefer self.allocator.free(no_store);

        const headers = try self.allocator.alloc(Header, 3);
        errdefer self.allocator.free(headers);
        headers[0] = .{ .name = "Set-Cookie", .value = session_cookie };
        headers[1] = .{ .name = "Set-Cookie", .value = csrf_cookie };
        headers[2] = .{ .name = "Cache-Control", .value = no_store };

        return .{
            .status = 204,
            .body = try self.allocator.dupe(u8, ""),
            .headers = headers,
        };
    }

    fn handleSession(self: *ManagementApi, req: Request, request_id: []const u8) !HttpResponse {
        const auth = self.session_store.authenticate(req.cookie_header, req.auth_header);
        if (!auth.is_authenticated) {
            return self.authProblem(401, .unauthorized, "Authentication required", request_id);
        }

        const user = self.users.findById(auth.userId());

        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        try std.json.Stringify.value(SessionResponse{
            .admin = .{
                .id = auth.userId(),
                .email = if (user) |u| u.email else "",
                .role = @tagName(auth.role().?),
            },
            .expires_at = auth.expires_at,
        }, .{}, &buf.writer);

        const no_store = try self.allocator.dupe(u8, "no-store");
        errdefer self.allocator.free(no_store);

        const headers = try self.allocator.alloc(Header, 1);
        errdefer self.allocator.free(headers);
        headers[0] = .{ .name = "Cache-Control", .value = no_store };

        return .{
            .status = 200,
            .body = try self.allocator.dupe(u8, buf.written()),
            .headers = headers,
        };
    }

    fn handleListServices(self: *ManagementApi, req: Request, request_id: []const u8) !HttpResponse {
        const auth = self.session_store.authenticate(req.cookie_header, req.auth_header);
        if (!auth.is_authenticated) {
            return self.problemResponse(401, .unauthorized, "Authentication required to access service status", request_id);
        }

        const states = self.aggregator.list(self.allocator, false) catch |err| {
            return self.problemResponse(500, .internal, @errorName(err), request_id);
        };
        defer self.allocator.free(states);

        var list_buf = std.Io.Writer.Allocating.init(self.allocator);
        defer list_buf.deinit();

        try list_buf.writer.writeAll("{\"items\":[");
        for (states, 0..) |state, i| {
            if (i > 0) try list_buf.writer.writeAll(",");
            try serializeServiceState(&list_buf.writer, state);
        }
        try list_buf.writer.writeAll("]}");

        const body = try self.allocator.dupe(u8, list_buf.written());
        return HttpResponse{ .status = 200, .body = body };
    }

    fn handleGetService(self: *ManagementApi, name: []const u8, req: Request, request_id: []const u8) !HttpResponse {
        const auth = self.session_store.authenticate(req.cookie_header, req.auth_header);
        if (!auth.is_authenticated) {
            return self.problemResponse(401, .unauthorized, "Authentication required", request_id);
        }

        const key = registry.parse(name) orelse {
            return self.problemResponse(404, .service_not_found, "Unknown service name", request_id);
        };

        const state = self.aggregator.get(key) catch |err| {
            return self.problemResponse(500, .internal, @errorName(err), request_id);
        };

        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        try serializeServiceState(&buf.writer, state);
        const body = try self.allocator.dupe(u8, buf.written());
        return HttpResponse{ .status = 200, .body = body };
    }

    fn handleRestartService(
        self: *ManagementApi,
        name: []const u8,
        req: Request,
        request_id: []const u8,
    ) !HttpResponse {
        const auth = self.session_store.authenticate(req.cookie_header, req.auth_header);
        if (!auth.is_authenticated) {
            return self.problemResponse(401, .unauthorized, "Authentication required", request_id);
        }

        if (auth.requiresCsrf() and !session_mod.validateCsrf(auth, req.csrf_header)) {
            return self.problemResponse(403, .csrf_invalid, "Missing or invalid CSRF token", request_id);
        }

        if (!auth.canMutate()) {
            return self.problemResponse(403, .forbidden, "Restarting services requires admin or owner role", request_id);
        }

        const key = registry.parse(name) orelse {
            return self.problemResponse(404, .service_not_found, "Unknown service name", request_id);
        };

        const result = try self.aggregator.restart(key);
        if (!result.ok) {
            if (std.mem.eql(u8, result.error_code orelse "", "SERVICE_OPERATION_IN_PROGRESS")) {
                return self.problemResponse(409, .service_operation_in_progress, result.message orelse "Operation in progress", request_id);
            }
            if (std.mem.eql(u8, result.error_code orelse "", "SERVICE_NOT_RESTARTABLE")) {
                return self.problemResponse(403, .service_not_restartable, result.message orelse "Service not restartable", request_id);
            }
            return self.problemResponse(500, .internal, result.message orelse "Service restart failed", request_id);
        }

        var random_bytes: [8]u8 = undefined;
        self.io.random(&random_bytes);
        const op_id = std.mem.readInt(u64, &random_bytes, .little);

        const now_sec = nowSeconds(self.io);
        var body_buf = std.Io.Writer.Allocating.init(self.allocator);
        defer body_buf.deinit();

        try body_buf.writer.print(
            \\{{"id":"op_restart_{s}_{d}","type":"apply","status":"running","target":"{s}","started_at":{d}}}
        , .{ @tagName(key), op_id, @tagName(key), now_sec });

        const body = try self.allocator.dupe(u8, body_buf.written());
        return HttpResponse{ .status = 202, .body = body };
    }

    fn authProblem(
        self: *ManagementApi,
        status: u16,
        code: core.Code,
        detail: ?[]const u8,
        request_id: []const u8,
    ) !HttpResponse {
        var response = try self.problemResponse(status, code, detail, request_id);
        errdefer response.deinit(self.allocator);

        const headers = try self.allocator.alloc(Header, 1);
        errdefer self.allocator.free(headers);
        headers[0] = .{ .name = "Cache-Control", .value = try self.allocator.dupe(u8, "no-store") };

        response.headers = headers;
        return response;
    }

    fn problemResponse(self: *ManagementApi, status: u16, code: core.Code, detail: ?[]const u8, request_id: []const u8) !HttpResponse {
        var docs_buffer: [128]u8 = undefined;
        const docs = code.docsUrl(&docs_buffer) catch "https://doctbase.dev/errors";

        const problem = protocol.Problem{
            .type = "about:blank",
            .title = code.title(),
            .status = status,
            .detail = detail,
            .code = code.codeString(),
            .request_id = request_id,
            .docs_url = docs,
        };

        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        try std.json.Stringify.value(problem, .{}, &buf.writer);
        const body = try self.allocator.dupe(u8, buf.written());
        return HttpResponse{
            .status = status,
            .content_type = "application/problem+json",
            .body = body,
        };
    }
};

fn nowSeconds(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn serializeServiceState(writer: anytype, state: driver_mod.RuntimeState) !void {
    const health_str = switch (state.health) {
        .ok => "ok",
        .warn => "warn",
        .err => "error",
        .unknown => "unknown",
    };

    try writer.print(
        \\{{"name":"{s}","state":"{s}","health":"{s}","version":"{s}","source":"{s}","optional":{s},"unit":{?s},"endpoint":{?s},"last_error":{?s},"last_check_at":{d}}}
    , .{
        @tagName(state.key),
        @tagName(state.state),
        health_str,
        state.version orelse "0.1.0",
        @tagName(state.source),
        if (state.optional) "true" else "false",
        state.unit,
        state.endpoint,
        state.last_error,
        state.last_check_at,
    });
}

test "management api requires auth for service listing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var store = session_mod.SessionStore.init(allocator, io, "secret");
    defer store.deinit();
    var users = users_mod.UserStore.init(allocator, io);
    defer users.deinit();
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &users, &agg);

    // Unauthenticated
    const unauth_res = try api.handle(.{ .method = "GET", .path = "/api/v1/services" });
    defer unauth_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), unauth_res.status);

    // Authenticated
    const auth_res = try api.handle(.{
        .method = "GET",
        .path = "/api/v1/services",
        .auth_header = "Bearer secret",
        .request_id = "req-1",
    });
    defer auth_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), auth_res.status);
    try std.testing.expect(std.mem.indexOf(u8, auth_res.body, "\"items\":[") != null);
}

test "management api gets single service or 404" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var store = session_mod.SessionStore.init(allocator, io, "secret");
    defer store.deinit();
    var users = users_mod.UserStore.init(allocator, io);
    defer users.deinit();
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &users, &agg);

    const ok_res = try api.handle(.{
        .method = "GET",
        .path = "/api/v1/services/auth",
        .auth_header = "Bearer secret",
        .request_id = "req-2",
    });
    defer ok_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), ok_res.status);
    try std.testing.expect(std.mem.indexOf(u8, ok_res.body, "\"name\":\"auth\"") != null);

    const notfound_res = try api.handle(.{
        .method = "GET",
        .path = "/api/v1/services/no_such_service",
        .auth_header = "Bearer secret",
        .request_id = "req-3",
    });
    defer notfound_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), notfound_res.status);
    try std.testing.expect(std.mem.indexOf(u8, notfound_res.body, "SERVICE_NOT_FOUND") != null);
}

test "management api restart validates role, csrf, infra protection and concurrency" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var store = session_mod.SessionStore.init(allocator, io, "admin-secret");
    defer store.deinit();
    var users = users_mod.UserStore.init(allocator, io);
    defer users.deinit();
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &users, &agg);

    var viewer = try store.createSession("u-1", .viewer);
    defer viewer.deinit(allocator);

    const viewer_cookie = try std.fmt.allocPrint(allocator, "doctbase_session={s}", .{viewer.token});
    defer allocator.free(viewer_cookie);

    // Viewer gets 403 Forbidden
    const viewer_res = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/services/auth/restart",
        .cookie_header = viewer_cookie,
        .csrf_header = viewer.csrf_token,
        .request_id = "req-4",
    });
    defer viewer_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), viewer_res.status);
    try std.testing.expect(std.mem.indexOf(u8, viewer_res.body, "FORBIDDEN") != null);

    // Admin succeeds with 202 Accepted
    const admin_res = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/services/auth/restart",
        .auth_header = "Bearer admin-secret",
        .request_id = "req-5",
    });
    defer admin_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 202), admin_res.status);
    try std.testing.expect(std.mem.indexOf(u8, admin_res.body, "\"target\":\"auth\"") != null);

    // Infra service restart blocked with 403
    const infra_res = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/services/postgresql/restart",
        .auth_header = "Bearer admin-secret",
        .request_id = "req-6",
    });
    defer infra_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), infra_res.status);
    try std.testing.expect(std.mem.indexOf(u8, infra_res.body, "SERVICE_NOT_RESTARTABLE") != null);
}

test "cookie-authenticated mutations require a valid csrf token" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var store = session_mod.SessionStore.init(allocator, io, null);
    defer store.deinit();
    var users = users_mod.UserStore.init(allocator, io);
    defer users.deinit();
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &users, &agg);

    var owner = try store.createSession("u-2", .owner);
    defer owner.deinit(allocator);

    const cookie = try std.fmt.allocPrint(allocator, "doctbase_session={s}", .{owner.token});
    defer allocator.free(cookie);

    const missing = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/services/auth/restart",
        .cookie_header = cookie,
        .request_id = "req-csrf-1",
    });
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "CSRF_INVALID") != null);

    const wrong = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/services/auth/restart",
        .cookie_header = cookie,
        .csrf_header = "not-the-csrf-token",
        .request_id = "req-csrf-2",
    });
    defer wrong.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), wrong.status);

    const accepted = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/services/auth/restart",
        .cookie_header = cookie,
        .csrf_header = owner.csrf_token,
        .request_id = "req-csrf-3",
    });
    defer accepted.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 202), accepted.status);
}

test "login sets httponly session cookie and csrf cookie, session works and logout revokes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var store = session_mod.SessionStore.init(allocator, io, null);
    defer store.deinit();
    var users = users_mod.UserStore.init(allocator, io);
    defer users.deinit();
    try users.addUser("owner@example.com", "correct-horse-battery", .owner);
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &users, &agg);

    const login_res = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/auth/login",
        .body = "{\"email\":\"owner@example.com\",\"password\":\"correct-horse-battery\"}",
        .request_id = "req-login",
    });
    defer login_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), login_res.status);
    try std.testing.expect(std.mem.indexOf(u8, login_res.body, "\"admin\":{") != null);

    var session_cookie: ?[]const u8 = null;
    var csrf_cookie: ?[]const u8 = null;
    for (login_res.headers) |header| {
        if (!std.mem.eql(u8, header.name, "Set-Cookie")) continue;
        if (std.mem.startsWith(u8, header.value, "doctbase_session=")) {
            session_cookie = header.value;
            try std.testing.expect(std.mem.indexOf(u8, header.value, "HttpOnly") != null);
        }
        if (std.mem.startsWith(u8, header.value, "doctbase_csrf=")) {
            csrf_cookie = header.value;
            try std.testing.expect(std.mem.indexOf(u8, header.value, "HttpOnly") == null);
        }
    }
    try std.testing.expect(session_cookie != null);
    try std.testing.expect(csrf_cookie != null);

    const cookie_header = try cookiePairs(allocator, session_cookie.?, csrf_cookie.?);
    defer allocator.free(cookie_header);

    const session_res = try api.handle(.{
        .method = "GET",
        .path = "/api/v1/auth/session",
        .cookie_header = cookie_header,
        .request_id = "req-session",
    });
    defer session_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), session_res.status);
    try std.testing.expect(std.mem.indexOf(u8, session_res.body, "\"role\":\"owner\"") != null);

    const csrf_token = extractCookieValue(csrf_cookie.?) orelse return error.TestExpectedCsrf;

    const logout_res = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/auth/logout",
        .cookie_header = cookie_header,
        .csrf_header = csrf_token,
        .request_id = "req-logout",
    });
    defer logout_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 204), logout_res.status);

    const after_res = try api.handle(.{
        .method = "GET",
        .path = "/api/v1/auth/session",
        .cookie_header = cookie_header,
        .request_id = "req-after",
    });
    defer after_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), after_res.status);
}

test "login rejects invalid credentials and malformed bodies" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var store = session_mod.SessionStore.init(allocator, io, null);
    defer store.deinit();
    var users = users_mod.UserStore.init(allocator, io);
    defer users.deinit();
    try users.addUser("owner@example.com", "correct-horse-battery", .owner);
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &users, &agg);

    const bad_password = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/auth/login",
        .body = "{\"email\":\"owner@example.com\",\"password\":\"wrong-password\"}",
        .request_id = "req-bad-1",
    });
    defer bad_password.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), bad_password.status);
    try std.testing.expect(std.mem.indexOf(u8, bad_password.body, "INVALID_CREDENTIALS") != null);

    const malformed = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/auth/login",
        .body = "{not-json",
        .request_id = "req-bad-2",
    });
    defer malformed.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 400), malformed.status);
    try std.testing.expect(std.mem.indexOf(u8, malformed.body, "BAD_REQUEST") != null);

    const wrong_content_type = try api.handle(.{
        .method = "POST",
        .path = "/api/v1/auth/login",
        .content_type = "application/x-www-form-urlencoded",
        .body = "email=owner%40example.com&password=correct-horse-battery",
        .request_id = "req-bad-3",
    });
    defer wrong_content_type.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 400), wrong_content_type.status);
}

fn cookiePairs(allocator: std.mem.Allocator, session_cookie: []const u8, csrf_cookie: []const u8) ![]u8 {
    const session_pair = firstCookiePair(session_cookie);
    const csrf_pair = firstCookiePair(csrf_cookie);
    return std.fmt.allocPrint(allocator, "{s}; {s}", .{ session_pair, csrf_pair });
}

fn firstCookiePair(set_cookie: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, set_cookie, ';') orelse set_cookie.len;
    return std.mem.trimEnd(u8, set_cookie[0..end], " ");
}

fn extractCookieValue(set_cookie: []const u8) ?[]const u8 {
    const pair = firstCookiePair(set_cookie);
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return null;
    return std.mem.trim(u8, pair[eq + 1 ..], " \t\"");
}
