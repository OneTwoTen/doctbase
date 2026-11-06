const std = @import("std");
const lifecycle = @import("service_lifecycle");
const registry = lifecycle.registry;
const driver_mod = lifecycle.driver;
const protocol = @import("service_protocol");
const core = @import("core");
const runtime_agg = @import("../services/runtime.zig");
const session_mod = @import("../auth/session.zig");

pub const HttpResponse = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []u8,

    pub fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const ManagementApi = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session_store: *session_mod.SessionStore,
    aggregator: *runtime_agg.ServiceRuntimeAggregator,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_store: *session_mod.SessionStore,
        aggregator: *runtime_agg.ServiceRuntimeAggregator,
    ) ManagementApi {
        return .{
            .allocator = allocator,
            .io = io,
            .session_store = session_store,
            .aggregator = aggregator,
        };
    }

    pub fn handle(
        self: *ManagementApi,
        method: []const u8,
        path: []const u8,
        cookie_header: ?[]const u8,
        auth_header: ?[]const u8,
        request_id: ?[]const u8,
    ) !HttpResponse {
        const req_id = request_id orelse "-";

        // Route matching
        if (std.mem.eql(u8, path, "/api/v1/services") or std.mem.eql(u8, path, "/services")) {
            if (std.mem.eql(u8, method, "GET")) {
                return self.handleListServices(cookie_header, auth_header, req_id);
            }
            return self.problemResponse(405, .not_found, "Method not allowed", req_id);
        }

        const prefix_v1 = "/api/v1/services/";
        const prefix_short = "/services/";
        var service_subpath: ?[]const u8 = null;
        if (std.mem.startsWith(u8, path, prefix_v1)) {
            service_subpath = path[prefix_v1.len..];
        } else if (std.mem.startsWith(u8, path, prefix_short)) {
            service_subpath = path[prefix_short.len..];
        }

        if (service_subpath) |subpath| {
            if (std.mem.endsWith(u8, subpath, "/restart")) {
                const service_name = subpath[0 .. subpath.len - "/restart".len];
                if (std.mem.eql(u8, method, "POST")) {
                    return self.handleRestartService(service_name, cookie_header, auth_header, req_id);
                }
                return self.problemResponse(405, .not_found, "Method not allowed", req_id);
            }

            if (std.mem.eql(u8, method, "GET")) {
                return self.handleGetService(subpath, cookie_header, auth_header, req_id);
            }
            return self.problemResponse(405, .not_found, "Method not allowed", req_id);
        }

        return self.problemResponse(404, .not_found, "API endpoint not found", req_id);
    }

    fn handleListServices(
        self: *ManagementApi,
        cookie_header: ?[]const u8,
        auth_header: ?[]const u8,
        request_id: []const u8,
    ) !HttpResponse {
        const auth = self.session_store.authenticate(cookie_header, auth_header);
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
            try serializeServiceState(list_buf.writer, state);
        }
        try list_buf.writer.writeAll("]}");

        const body = try self.allocator.dupe(u8, list_buf.written());
        return HttpResponse{ .status = 200, .body = body };
    }

    fn handleGetService(
        self: *ManagementApi,
        name: []const u8,
        cookie_header: ?[]const u8,
        auth_header: ?[]const u8,
        request_id: []const u8,
    ) !HttpResponse {
        const auth = self.session_store.authenticate(cookie_header, auth_header);
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

        try serializeServiceState(buf.writer, state);
        const body = try self.allocator.dupe(u8, buf.written());
        return HttpResponse{ .status = 200, .body = body };
    }

    fn handleRestartService(
        self: *ManagementApi,
        name: []const u8,
        cookie_header: ?[]const u8,
        auth_header: ?[]const u8,
        request_id: []const u8,
    ) !HttpResponse {
        const auth = self.session_store.authenticate(cookie_header, auth_header);
        if (!auth.is_authenticated) {
            return self.problemResponse(401, .unauthorized, "Authentication required", request_id);
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

        const now_sec = std.Io.Timestamp.now(self.io, .real).toSeconds();
        var body_buf = std.Io.Writer.Allocating.init(self.allocator);
        defer body_buf.deinit();

        try body_buf.writer.print(
            \\{{"id":"op_restart_{s}_{d}","type":"apply","status":"running","target":"{s}","started_at":{d}}}
        , .{ @tagName(key), op_id, @tagName(key), now_sec });

        const body = try self.allocator.dupe(u8, body_buf.written());
        return HttpResponse{ .status = 202, .body = body };
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
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &agg);

    // Unauthenticated
    const unauth_res = try api.handle("GET", "/api/v1/services", null, null, null);
    defer unauth_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), unauth_res.status);

    // Authenticated
    const auth_res = try api.handle("GET", "/api/v1/services", null, "Bearer secret", "req-1");
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
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &agg);

    const ok_res = try api.handle("GET", "/api/v1/services/auth", null, "Bearer secret", "req-2");
    defer ok_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), ok_res.status);
    try std.testing.expect(std.mem.indexOf(u8, ok_res.body, "\"name\":\"auth\"") != null);

    const notfound_res = try api.handle("GET", "/api/v1/services/no_such_service", null, "Bearer secret", "req-3");
    defer notfound_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), notfound_res.status);
    try std.testing.expect(std.mem.indexOf(u8, notfound_res.body, "SERVICE_NOT_FOUND") != null);
}

test "management api restart service validates role, infra protection and concurrency" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var fake = lifecycle.fake.FakeDriver.init();
    var store = session_mod.SessionStore.init(allocator, io, "admin-secret");
    defer store.deinit();
    var agg = runtime_agg.ServiceRuntimeAggregator.init(allocator, io, fake.driver(), .{});
    defer agg.deinit();

    var api = ManagementApi.init(allocator, io, &store, &agg);

    // Add viewer session
    try store.addSession("viewer-token", .{
        .id = "s-1",
        .user_id = "u-1",
        .role = .viewer,
        .expires_at = std.math.maxInt(i64),
    });

    // Viewer gets 403 Forbidden
    const viewer_res = try api.handle("POST", "/api/v1/services/auth/restart", null, "Bearer viewer-token", "req-4");
    defer viewer_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), viewer_res.status);
    try std.testing.expect(std.mem.indexOf(u8, viewer_res.body, "FORBIDDEN") != null);

    // Admin succeeds with 202 Accepted
    const admin_res = try api.handle("POST", "/api/v1/services/auth/restart", null, "Bearer admin-secret", "req-5");
    defer admin_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 202), admin_res.status);
    try std.testing.expect(std.mem.indexOf(u8, admin_res.body, "\"target\":\"auth\"") != null);

    // Infra service restart blocked with 403
    const infra_res = try api.handle("POST", "/api/v1/services/postgresql/restart", null, "Bearer admin-secret", "req-6");
    defer infra_res.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), infra_res.status);
    try std.testing.expect(std.mem.indexOf(u8, infra_res.body, "SERVICE_NOT_RESTARTABLE") != null);
}
